//! The egress proxy of the sandbox (`docs/dev/vm.md`, step 1). It
//! listens on 127.0.0.1 and reads one HTTP request on each connection.
//! A `CONNECT host:port` request to a host of the allow list gets a
//! TCP connection to that host, and the proxy copies the bytes in both
//! directions until one side closes. A host outside the allow list gets
//! `403 Forbidden`. Each other request gets `405 Method Not Allowed`,
//! because a program in the sandbox uses `HTTPS_PROXY` and CONNECT.
//!
//! An allow list entry is a host name (`api.example.com`) or a suffix
//! with a star (`*.example.com`, which also matches `example.com`), with
//! an optional port (`api.example.com:8443`). An entry with no port
//! allows the ports 443 and 80 only. The names compare with no case.
//!
//! The limits: at most `max_conns` connections at a time (a connection
//! over the limit closes at once), `head_timeout_ms` for the request
//! head, and `idle_timeout_ms` with no bytes in either direction.
//!
//! Each connection and each refused request is an event, kept in order
//! until a call of `events`: the start time in ms, the host, the port,
//! the result (`allowed`, `blocked`, `failed`, or `refused`), the bytes
//! from the client and to the client, and the duration in ms. The
//! monitor of issue 15 reads these events.
//!
//! One thread accepts the connections, and each connection has its own
//! thread with blocking sockets and `poll`. A lock guards the allow list
//! and the events. The sockets are the ones of `ztcl.sys`, the same on
//! Linux, macOS, and Windows: the accept thread waits in `poll` with a
//! timeout, so `stop` ends it on each system. Tcl commands:
//! `dockyard::proxy start ?port?`, `allow ?list?`, `attach channel` (a
//! connection of the guest, from the relay of `sandbox.tcl`), `events`,
//! and `stop`.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const sys = ztcl.sys;
const Fd = sys.Fd;

pub const Result = enum { allowed, blocked, failed, refused };

pub const Event = struct {
    start_ms: i64,
    host: []const u8,
    port: u16,
    result: Result,
    up: u64 = 0,
    down: u64 = 0,
    ms: i64 = 0,
};

/// The most events that wait for `events`. Older events go first.
const max_events = 10_000;

/// The most connections at a time, for each proxy (the guest has one).
pub const max_conns = 64;
/// The time for the request head, from the accept.
pub var head_timeout_ms: i64 = 10_000;
/// The time with no bytes in either direction, after which the
/// connection closes.
pub var idle_timeout_ms: i64 = 300_000;

/// A lock for a short time: the allow list and the events.
const Lock = struct {
    m: std.atomic.Mutex = .unlocked,
    fn lock(l: *Lock) void {
        while (!l.m.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(l: *Lock) void {
        l.m.unlock();
    }
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    fd: Fd,
    port: u16,
    lock: Lock = .{},
    allow_list: std.ArrayList([]const u8) = .empty,
    events: std.ArrayList(Event) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The connections that a thread serves now.
    active: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    /// Listens on 127.0.0.1:`port` (0 for a free port) and starts the
    /// thread that accepts the connections.
    pub fn start(gpa: std.mem.Allocator, port: u16) !*Proxy {
        const fd = switch (sys.listenAt(loopback(port), true)) {
            .fd => |fd| fd,
            .err => return error.AddressInUse,
        };
        errdefer sys.close(fd);
        const at = sys.sockName(fd) orelse return error.SystemResources;
        const p = try gpa.create(Proxy);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .fd = fd, .port = at.port };
        p.thread = try std.Thread.spawn(.{}, acceptLoop, .{p});
        return p;
    }

    /// Stops the accept thread, waits for the end of each connection
    /// (each one ends in at most `accept_wait_ms` once `stopping` is
    /// set), and frees the proxy.
    pub fn stop(p: *Proxy) void {
        p.stopping.store(true, .release);
        if (p.thread) |t| t.join();
        while (p.active.load(.acquire) > 0) std.Thread.yield() catch {};
        sys.close(p.fd);
        p.setAllow(&.{}) catch {};
        p.allow_list.deinit(p.gpa);
        for (p.events.items) |e| p.gpa.free(e.host);
        p.events.deinit(p.gpa);
        p.gpa.destroy(p);
    }

    /// Replaces the allow list.
    pub fn setAllow(p: *Proxy, hosts: []const []const u8) !void {
        p.lock.lock();
        defer p.lock.unlock();
        for (p.allow_list.items) |h| p.gpa.free(h);
        p.allow_list.clearRetainingCapacity();
        for (hosts) |h| try p.allow_list.append(p.gpa, try std.ascii.allocLowerString(p.gpa, h));
    }

    fn allowed(p: *Proxy, host: []const u8, port: u16) bool {
        p.lock.lock();
        defer p.lock.unlock();
        for (p.allow_list.items) |pat| if (matchesPort(pat, host, port)) return true;
        return false;
    }

    fn record(p: *Proxy, e: Event) void {
        const host = p.gpa.dupe(u8, e.host) catch return;
        p.lock.lock();
        defer p.lock.unlock();
        if (p.events.items.len >= max_events) p.gpa.free(p.events.orderedRemove(0).host);
        var copy = e;
        copy.host = host;
        p.events.append(p.gpa, copy) catch p.gpa.free(host);
    }

    /// Serves one connection that the caller opened, such as a vsock
    /// stream of the guest, in a thread of its own. The proxy closes it.
    pub fn attach(p: *Proxy, conn: Fd) !void {
        p.spawn(conn);
    }

    /// Serves `conn` in a thread of its own, or closes it when
    /// `max_conns` connections are open.
    fn spawn(p: *Proxy, conn: Fd) void {
        if (p.active.fetchAdd(1, .acq_rel) >= max_conns) {
            _ = p.active.fetchSub(1, .acq_rel);
            sys.close(conn);
            p.record(.{ .start_ms = nowMs(), .host = "", .port = 0, .result = .refused });
            return;
        }
        const t = std.Thread.spawn(.{}, serveCounted, .{ p, conn }) catch {
            _ = p.active.fetchSub(1, .acq_rel);
            sys.close(conn);
            return;
        };
        t.detach();
    }

    /// Gives the events since the last call. The caller frees the list
    /// and each host with the allocator of the proxy.
    pub fn take(p: *Proxy) ![]Event {
        p.lock.lock();
        defer p.lock.unlock();
        return p.events.toOwnedSlice(p.gpa);
    }
};

fn loopback(port: u16) sys.Addr {
    var a: sys.Addr = .{ .port = port };
    a.bytes[0] = 127;
    a.bytes[3] = 1;
    return a;
}

/// True when `host:port` matches the allow list entry `pat` (lower
/// case): a host pattern with `:PORT`, or a host pattern alone for the
/// ports 443 and 80.
pub fn matchesPort(pat: []const u8, host: []const u8, port: u16) bool {
    if (std.mem.lastIndexOfScalar(u8, pat, ':')) |colon| {
        const want = std.fmt.parseInt(u16, pat[colon + 1 ..], 10) catch return false;
        return want == port and matches(pat[0..colon], host);
    }
    return (port == 443 or port == 80) and matches(pat, host);
}

/// True when the host matches the host pattern `pat` (lower case).
pub fn matches(pat: []const u8, host: []const u8) bool {
    if (std.mem.startsWith(u8, pat, "*.")) {
        const base = pat[2..];
        if (std.ascii.eqlIgnoreCase(host, base)) return true;
        return host.len > base.len + 1 and host[host.len - base.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - base.len ..], base);
    }
    return std.ascii.eqlIgnoreCase(pat, host);
}

/// The time of the wall clock in ms since 1970.
fn nowMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        var ft: u64 = 0;
        GetSystemTimePreciseAsFileTime(&ft);
        // 100 ns units since 1601.
        return @divFloor(@as(i64, @intCast(ft)) - 116_444_736_000_000_000, 10_000);
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

extern "kernel32" fn GetSystemTimePreciseAsFileTime(ft: *u64) callconv(.winapi) void;

/// The wait of the accept thread in `poll`, so `stop` ends it in at most
/// this time.
const accept_wait_ms = 200;

fn acceptLoop(p: *Proxy) void {
    while (!p.stopping.load(.acquire)) {
        var want = [1]sys.Want{.{ .fd = p.fd, .read = true }};
        sys.poll(p.gpa, &want, accept_wait_ms);
        if (!want[0].can_read) continue;
        const conn = (sys.accept(p.fd) orelse continue).fd;
        sys.setBlocking(conn, true);
        p.spawn(conn);
    }
}

fn writeAll(fd: Fd, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        switch (sys.write(fd, rest)) {
            .n => |n| {
                if (n == 0) return false;
                rest = rest[n..];
            },
            .again => std.Thread.yield() catch {},
            .err => return false,
        }
    }
    return true;
}

/// A read of some bytes before the wall clock time `deadline` (ms): the
/// count, 0 at the end, or null on an error or at the deadline.
fn readBefore(p: *Proxy, fd: Fd, buf: []u8, deadline: i64) ?usize {
    while (!p.stopping.load(.acquire)) {
        const left = deadline - nowMs();
        if (left <= 0) return null;
        var want = [1]sys.Want{.{ .fd = fd, .read = true }};
        sys.poll(p.gpa, &want, @intCast(@min(left, accept_wait_ms)));
        if (want[0].can_read) return readSome(fd, buf);
    }
    return null;
}

/// A read of some bytes: the count, 0 at the end, or null on an error.
fn readSome(fd: Fd, buf: []u8) ?usize {
    while (true) switch (sys.read(fd, buf)) {
        .n => |n| return n,
        .again => std.Thread.yield() catch {},
        .err => return null,
    };
}

/// The target of a request line: `CONNECT host:port HTTP/1.1`.
pub const Target = struct { host: []const u8, port: u16 };

pub fn parseConnect(line: []const u8) ?Target {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const method = words.next() orelse return null;
    if (!std.mem.eql(u8, method, "CONNECT")) return null;
    const hp = words.next() orelse return null;
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return null;
    var host = hp[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return null;
    if (host.len == 0 or port == 0) return null;
    return .{ .host = host, .port = port };
}

fn serveCounted(p: *Proxy, conn: Fd) void {
    defer _ = p.active.fetchSub(1, .acq_rel);
    serve(p, conn);
}

fn serve(p: *Proxy, conn: Fd) void {
    defer sys.close(conn);
    const t0 = nowMs();
    // The request head: up to the empty line, 8 KB at most, in
    // head_timeout_ms.
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    const head_end = while (len < buf.len) {
        const n = readBefore(p, conn, buf[len..], t0 + head_timeout_ms) orelse return;
        if (n == 0) return;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |i| break i + 4;
    } else return;
    const line_end = std.mem.indexOf(u8, buf[0..len], "\r\n") orelse return;
    const target = parseConnect(buf[0..line_end]) orelse {
        _ = writeAll(conn, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        p.record(.{ .start_ms = t0, .host = "", .port = 0, .result = .refused });
        return;
    };
    if (!p.allowed(target.host, target.port)) {
        _ = writeAll(conn, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        p.record(.{ .start_ms = t0, .host = target.host, .port = target.port, .result = .blocked });
        return;
    }
    const up = connectTo(p.gpa, target) orelse {
        _ = writeAll(conn, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        p.record(.{ .start_ms = t0, .host = target.host, .port = target.port, .result = .failed, .ms = nowMs() - t0 });
        return;
    };
    defer sys.close(up);
    if (!writeAll(conn, "HTTP/1.1 200 Connection established\r\n\r\n")) return;
    var sent: u64 = 0;
    var got: u64 = 0;
    // Bytes after the head go to the host.
    if (len > head_end) {
        if (!writeAll(up, buf[head_end..len])) return;
        sent += len - head_end;
    }
    relay(p, conn, up, &sent, &got);
    p.record(.{ .start_ms = t0, .host = target.host, .port = target.port, .result = .allowed, .up = sent, .down = got, .ms = nowMs() - t0 });
}

/// A connection to each address of the host in turn, until one answers.
fn connectTo(gpa: std.mem.Allocator, t: Target) ?Fd {
    var addrs: std.ArrayList(sys.Addr) = .empty;
    defer addrs.deinit(gpa);
    sys.resolve(gpa, t.host, &addrs) catch return null;
    for (addrs.items) |a| {
        var at = a;
        at.port = t.port;
        switch (sys.connectTo(at, null, true)) {
            .fd => |fd| {
                sys.setBlocking(fd, true);
                return fd;
            },
            .err => {},
        }
    }
    return null;
}

/// Copies bytes both ways until one side ends, or for idle_timeout_ms
/// no bytes come.
fn relay(p: *Proxy, client: Fd, host: Fd, sent: *u64, got: *u64) void {
    var buf: [16384]u8 = undefined;
    const ends = [2]Fd{ client, host };
    var last = nowMs();
    while (!p.stopping.load(.acquire)) {
        var wants = [2]sys.Want{ .{ .fd = client, .read = true }, .{ .fd = host, .read = true } };
        sys.poll(p.gpa, &wants, accept_wait_ms);
        if (!wants[0].can_read and !wants[1].can_read) {
            if (nowMs() - last >= idle_timeout_ms) return;
            continue;
        }
        last = nowMs();
        for (wants, 0..) |w, i| {
            if (!w.can_read) continue;
            const n = readSome(ends[i], &buf) orelse return;
            if (n == 0) return;
            const to = if (i == 0) host else client;
            if (!writeAll(to, buf[0..n])) return;
            if (i == 0) sent.* += n else got.* += n;
        }
    }
}

// ---- The Tcl commands ----

var the_proxy: ?*Proxy = null;

pub fn register(it: *ztcl.Interp) !void {
    try it.register("dockyard::proxy", cmdProxy);
}

/// `dockyard::proxy start ?port?` gives the port. `allow ?list?` sets or
/// gives the allow list. `events` gives the events since the last call,
/// each a dict. `stop` ends the proxy.
fn cmdProxy(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len < 2) return it.wrongArgs("dockyard::proxy start|allow|attach|events|stop ?arg?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "start")) {
        if (the_proxy != null) return it.fail("the proxy runs", .{});
        const port: u16 = if (argv.len > 2) @intCast(std.math.clamp(try it.int(argv[2]), 0, 65535)) else 0;
        the_proxy = Proxy.start(std.heap.smp_allocator, port) catch |e| return it.fail("proxy: {s}", .{@errorName(e)});
        return .{ .int = the_proxy.?.port };
    }
    const p = the_proxy orelse return it.fail("the proxy does not run", .{});
    if (std.mem.eql(u8, sub, "stop")) {
        p.stop();
        the_proxy = null;
        return .empty;
    }
    if (std.mem.eql(u8, sub, "allow")) {
        if (argv.len > 2) {
            const items = try it.list(argv[2]);
            var hosts: std.ArrayList([]const u8) = .empty;
            for (items) |v| try hosts.append(a, try it.str(v));
            try p.setAllow(hosts.items);
        }
        p.lock.lock();
        defer p.lock.unlock();
        var out: std.ArrayList(ztcl.Value) = .empty;
        for (p.allow_list.items) |h| try out.append(a, .{ .str = try a.dupe(u8, h) });
        return ztcl.value.newList(a, out.items);
    }
    if (std.mem.eql(u8, sub, "attach")) {
        // The channel leaves the interpreter, and its descriptor goes to
        // a thread of the proxy.
        if (argv.len != 3) return it.wrongArgs("dockyard::proxy attach channel");
        const name = try it.str(argv[2]);
        const ch = ztcl.chan.lookup(it, name) orelse return it.fail("can not find channel named \"{s}\"", .{name});
        if (ch.rbuf.items.len > ch.rpos or ch.wbuf.items.len > 0 or ch.wfd >= 0)
            return it.fail("proxy: the channel {s} has buffered bytes or two descriptors", .{name});
        _ = ztcl.chan.release(it, name);
        sys.setBlocking(ch.fd, true);
        p.attach(ch.fd) catch |e| {
            sys.close(ch.fd);
            return it.fail("proxy: {s}", .{@errorName(e)});
        };
        return .empty;
    }
    if (std.mem.eql(u8, sub, "events")) {
        const evs = try p.take();
        defer {
            for (evs) |e| p.gpa.free(e.host);
            p.gpa.free(evs);
        }
        var out: std.ArrayList(ztcl.Value) = .empty;
        for (evs) |e| try out.append(a, try ztcl.value.newList(a, &.{
            .{ .str = "time" },   .{ .int = e.start_ms },
            .{ .str = "host" },   .{ .str = try a.dupe(u8, e.host) },
            .{ .str = "port" },   .{ .int = e.port },
            .{ .str = "result" }, .{ .str = @tagName(e.result) },
            .{ .str = "up" },     .{ .int = @intCast(e.up) },
            .{ .str = "down" },   .{ .int = @intCast(e.down) },
            .{ .str = "ms" },     .{ .int = e.ms },
        }));
        return ztcl.value.newList(a, out.items);
    }
    return it.fail("bad option \"{s}\": must be start, allow, attach, events, or stop", .{sub});
}

test "allow list entries match hosts and suffixes" {
    try std.testing.expect(matches("api.example.com", "API.example.com"));
    try std.testing.expect(!matches("api.example.com", "example.com"));
    try std.testing.expect(matches("*.example.com", "example.com"));
    try std.testing.expect(matches("*.example.com", "a.b.example.com"));
    try std.testing.expect(!matches("*.example.com", "badexample.com"));
    try std.testing.expect(matchesPort("api.example.com", "api.example.com", 443));
    try std.testing.expect(matchesPort("api.example.com", "api.example.com", 80));
    try std.testing.expect(!matchesPort("api.example.com", "api.example.com", 22));
    try std.testing.expect(matchesPort("api.example.com:8443", "api.example.com", 8443));
    try std.testing.expect(!matchesPort("api.example.com:8443", "api.example.com", 443));
    try std.testing.expect(matchesPort("*.example.com:22", "git.example.com", 22));
}

test "a CONNECT line gives the host and the port" {
    const t = parseConnect("CONNECT api.example.com:443 HTTP/1.1").?;
    try std.testing.expectEqualStrings("api.example.com", t.host);
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("::1", parseConnect("CONNECT [::1]:8080 HTTP/1.1").?.host);
    try std.testing.expect(parseConnect("GET http://x/ HTTP/1.1") == null);
    try std.testing.expect(parseConnect("CONNECT x:0 HTTP/1.1") == null);
}

fn listenLocal() !struct { fd: Fd, port: u16 } {
    const fd = switch (sys.listenAt(loopback(0), false)) {
        .fd => |fd| fd,
        .err => return error.AddressInUse,
    };
    return .{ .fd = fd, .port = (sys.sockName(fd) orelse return error.SystemResources).port };
}

fn echoOnce(fd: Fd) void {
    var want = [1]sys.Want{.{ .fd = fd, .read = true }};
    sys.poll(std.testing.allocator, &want, 5000);
    const conn = (sys.accept(fd) orelse return).fd;
    defer sys.close(conn);
    sys.setBlocking(conn, true);
    var buf: [64]u8 = undefined;
    const n = readSome(conn, &buf) orelse return;
    if (n > 0) _ = writeAll(conn, buf[0..n]);
}

fn ask(port: u16, request: []const u8, reply: []u8) ![]const u8 {
    const fd = switch (sys.connectTo(loopback(port), null, true)) {
        .fd => |fd| fd,
        .err => return error.ConnectionRefused,
    };
    defer sys.close(fd);
    sys.setBlocking(fd, true);
    if (!writeAll(fd, request)) return error.BrokenPipe;
    var len: usize = 0;
    while (len < reply.len) {
        const n = readSome(fd, reply[len..]) orelse break;
        if (n == 0) break;
        len += n;
    }
    return reply[0..len];
}

test "the proxy relays an allowed host and blocks another one" {
    const gpa = std.testing.allocator;
    const server = try listenLocal();
    defer sys.close(server.fd);
    const echo = try std.Thread.spawn(.{}, echoOnce, .{server.fd});
    const p = try Proxy.start(gpa, 0);
    defer p.stop();
    var pat: [64]u8 = undefined;
    try p.setAllow(&.{try std.fmt.bufPrint(&pat, "127.0.0.1:{d}", .{server.port})});
    var buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf, "CONNECT 127.0.0.1:{d} HTTP/1.1\r\nHost: x\r\n\r\nhello", .{server.port});
    var reply: [256]u8 = undefined;
    const got = try ask(p.port, req, &reply);
    echo.join();
    try std.testing.expectEqualStrings("HTTP/1.1 200 Connection established\r\n\r\nhello", got);
    const blocked = try ask(p.port, "CONNECT other.example:443 HTTP/1.1\r\n\r\n", &reply);
    try std.testing.expect(std.mem.startsWith(u8, blocked, "HTTP/1.1 403"));
    // The relay thread records its event when both sides end.
    var all: std.ArrayList(Event) = .empty;
    defer {
        for (all.items) |e| gpa.free(e.host);
        all.deinit(gpa);
    }
    const end = nowMs() + 2000;
    while (all.items.len < 2 and nowMs() < end) {
        const evs = try p.take();
        defer gpa.free(evs);
        try all.appendSlice(gpa, evs);
        if (all.items.len < 2) std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 2), all.items.len);
    var saw_allowed = false;
    var saw_blocked = false;
    for (all.items) |e| switch (e.result) {
        .allowed => {
            saw_allowed = true;
            try std.testing.expectEqual(@as(u64, 5), e.up);
            try std.testing.expectEqual(@as(u64, 5), e.down);
        },
        .blocked => {
            saw_blocked = true;
            try std.testing.expectEqualStrings("other.example", e.host);
        },
        else => {},
    };
    try std.testing.expect(saw_allowed and saw_blocked);
}

test "the proxy closes a silent connection and a connection over the limit" {
    const gpa = std.testing.allocator;
    const saved = head_timeout_ms;
    defer head_timeout_ms = saved;
    head_timeout_ms = 300;
    const p = try Proxy.start(gpa, 0);
    defer p.stop();
    // A host with no port in the allow list allows 443 and 80 only.
    try p.setAllow(&.{"127.0.0.1"});
    var reply: [256]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try ask(p.port, "CONNECT 127.0.0.1:22 HTTP/1.1\r\n\r\n", &reply), "HTTP/1.1 403"));
    // max_conns silent clients fill the proxy. The next one closes at
    // once, and the silent ones close after head_timeout_ms.
    var fds: [max_conns]Fd = undefined;
    for (&fds) |*fd| {
        fd.* = switch (sys.connectTo(loopback(p.port), null, true)) {
            .fd => |f| f,
            .err => return error.ConnectionRefused,
        };
        sys.setBlocking(fd.*, true);
    }
    defer for (fds) |fd| sys.close(fd);
    const end = nowMs() + 2000;
    while (p.active.load(.acquire) < max_conns and nowMs() < end) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u32, max_conns), p.active.load(.acquire));
    const t0 = nowMs();
    try std.testing.expectEqualStrings("", try ask(p.port, "", &reply));
    try std.testing.expect(nowMs() - t0 < 250);
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), readSome(fds[0], &one));
    const evs = try p.take();
    defer {
        for (evs) |e| gpa.free(e.host);
        gpa.free(evs);
    }
    var refused: usize = 0;
    for (evs) |e| if (e.result == .refused) {
        refused += 1;
    };
    try std.testing.expect(refused >= 1);
}
