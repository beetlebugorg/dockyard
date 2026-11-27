//! The egress proxy of the sandbox (`docs/dev/vm.md`, step 1). It
//! listens on 127.0.0.1 and reads one HTTP request on each connection.
//! A `CONNECT host:port` request to a host of the allow list gets a
//! TCP connection to that host, and the proxy copies the bytes in both
//! directions until one side closes. A host outside the allow list gets
//! `403 Forbidden`. Each other request gets `405 Method Not Allowed`,
//! because a program in the sandbox uses `HTTPS_PROXY` and CONNECT.
//!
//! An allow list entry is a host name (`api.example.com`) or a suffix
//! with a star (`*.example.com`, which also matches `example.com`). The
//! names compare with no case.
//!
//! Each connection and each refused request is an event, kept in order
//! until a call of `events`: the start time in ms, the host, the port,
//! the result (`allowed`, `blocked`, `failed`, or `refused`), the bytes
//! from the client and to the client, and the duration in ms. The
//! monitor of issue 15 reads these events.
//!
//! One thread accepts the connections, and each connection has its own
//! thread with blocking sockets and `poll`. A mutex guards the allow
//! list and the events. Tcl commands: `dockyard::proxy start ?port?`,
//! `allow ?list?`, `events`, and `stop`.
//!
//! The proxy uses the sockets of the C library, so on Windows each
//! subcommand gives an error until the port of dockyard (dockyard#23).

const std = @import("std");
const ztcl = @import("ztcl");
const c = std.c;

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

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    fd: c.fd_t,
    port: u16,
    lock: c.pthread_mutex_t = .{},
    allow_list: std.ArrayList([]const u8) = .empty,
    events: std.ArrayList(Event) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Listens on 127.0.0.1:`port` (0 for a free port) and starts the
    /// thread that accepts the connections.
    pub fn start(gpa: std.mem.Allocator, port: u16) !*Proxy {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.SystemResources;
        errdefer _ = c.close(fd);
        const one: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
        var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.AddressInUse;
        if (c.listen(fd, 64) != 0) return error.SystemResources;
        var len: c.socklen_t = @sizeOf(c.sockaddr.in);
        _ = c.getsockname(fd, @ptrCast(&addr), &len);
        const p = try gpa.create(Proxy);
        p.* = .{ .gpa = gpa, .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        p.thread = try std.Thread.spawn(.{}, acceptLoop, .{p});
        return p;
    }

    /// Stops the accept thread and frees the proxy. Open connections
    /// end on their own.
    pub fn stop(p: *Proxy) void {
        p.stopping.store(true, .release);
        _ = c.shutdown(p.fd, 2);
        if (p.thread) |t| t.join();
        _ = c.close(p.fd);
        p.setAllow(&.{}) catch {};
        p.allow_list.deinit(p.gpa);
        for (p.events.items) |e| p.gpa.free(e.host);
        p.events.deinit(p.gpa);
        p.gpa.destroy(p);
    }

    /// Replaces the allow list.
    pub fn setAllow(p: *Proxy, hosts: []const []const u8) !void {
        _ = c.pthread_mutex_lock(&p.lock);
        defer _ = c.pthread_mutex_unlock(&p.lock);
        for (p.allow_list.items) |h| p.gpa.free(h);
        p.allow_list.clearRetainingCapacity();
        for (hosts) |h| try p.allow_list.append(p.gpa, try std.ascii.allocLowerString(p.gpa, h));
    }

    fn allowed(p: *Proxy, host: []const u8) bool {
        _ = c.pthread_mutex_lock(&p.lock);
        defer _ = c.pthread_mutex_unlock(&p.lock);
        for (p.allow_list.items) |pat| if (matches(pat, host)) return true;
        return false;
    }

    fn record(p: *Proxy, e: Event) void {
        const host = p.gpa.dupe(u8, e.host) catch return;
        _ = c.pthread_mutex_lock(&p.lock);
        defer _ = c.pthread_mutex_unlock(&p.lock);
        if (p.events.items.len >= max_events) p.gpa.free(p.events.orderedRemove(0).host);
        var copy = e;
        copy.host = host;
        p.events.append(p.gpa, copy) catch p.gpa.free(host);
    }

    /// Gives the events since the last call. The caller frees the list
    /// and each host with the allocator of the proxy.
    pub fn take(p: *Proxy) ![]Event {
        _ = c.pthread_mutex_lock(&p.lock);
        defer _ = c.pthread_mutex_unlock(&p.lock);
        return p.events.toOwnedSlice(p.gpa);
    }
};

/// True when the host matches the allow list entry `pat` (lower case).
pub fn matches(pat: []const u8, host: []const u8) bool {
    if (std.mem.startsWith(u8, pat, "*.")) {
        const base = pat[2..];
        if (std.ascii.eqlIgnoreCase(host, base)) return true;
        return host.len > base.len + 1 and host[host.len - base.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - base.len ..], base);
    }
    return std.ascii.eqlIgnoreCase(pat, host);
}

fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

fn acceptLoop(p: *Proxy) void {
    while (!p.stopping.load(.acquire)) {
        const conn = c.accept(p.fd, null, null);
        if (conn < 0) {
            if (p.stopping.load(.acquire)) return;
            continue;
        }
        const t = std.Thread.spawn(.{}, serve, .{ p, conn }) catch {
            _ = c.close(conn);
            continue;
        };
        t.detach();
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
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

fn serve(p: *Proxy, conn: c.fd_t) void {
    defer _ = c.close(conn);
    const t0 = nowMs();
    // The request head: up to the empty line, 8 KB at most.
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    const head_end = while (len < buf.len) {
        const n = c.read(conn, buf[len..].ptr, buf.len - len);
        if (n <= 0) return;
        len += @intCast(n);
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |i| break i + 4;
    } else return;
    const line_end = std.mem.indexOf(u8, buf[0..len], "\r\n") orelse return;
    const target = parseConnect(buf[0..line_end]) orelse {
        _ = writeAll(conn, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        p.record(.{ .start_ms = t0, .host = "", .port = 0, .result = .refused });
        return;
    };
    if (!p.allowed(target.host)) {
        _ = writeAll(conn, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        p.record(.{ .start_ms = t0, .host = target.host, .port = target.port, .result = .blocked });
        return;
    }
    const up = connectTo(target) orelse {
        _ = writeAll(conn, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        p.record(.{ .start_ms = t0, .host = target.host, .port = target.port, .result = .failed, .ms = nowMs() - t0 });
        return;
    };
    defer _ = c.close(up);
    if (!writeAll(conn, "HTTP/1.1 200 Connection established\r\n\r\n")) return;
    var sent: u64 = 0;
    var got: u64 = 0;
    // Bytes after the head go to the host.
    if (len > head_end) {
        if (!writeAll(up, buf[head_end..len])) return;
        sent += len - head_end;
    }
    relay(conn, up, &sent, &got);
    p.record(.{ .start_ms = t0, .host = target.host, .port = target.port, .result = .allowed, .up = sent, .down = got, .ms = nowMs() - t0 });
}

fn connectTo(t: Target) ?c.fd_t {
    var name_buf: [256]u8 = undefined;
    if (t.host.len >= name_buf.len) return null;
    @memcpy(name_buf[0..t.host.len], t.host);
    name_buf[t.host.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{t.port}, 0) catch return null;
    const hints: c.addrinfo = .{ .flags = .{}, .family = c.AF.UNSPEC, .socktype = c.SOCK.STREAM, .protocol = 0, .addrlen = 0, .addr = null, .canonname = null, .next = null };
    var res: ?*c.addrinfo = null;
    if (@backingInt(c.getaddrinfo(@ptrCast(&name_buf), port_z.ptr, &hints, &res)) != 0) return null;
    defer c.freeaddrinfo(res.?);
    var ai = res;
    while (ai) |a| : (ai = a.next) {
        const fd = c.socket(@intCast(a.family), c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) continue;
        if (c.connect(fd, a.addr.?, a.addrlen) == 0) return fd;
        _ = c.close(fd);
    }
    return null;
}

/// Copies bytes both ways until one side ends.
fn relay(client: c.fd_t, host: c.fd_t, sent: *u64, got: *u64) void {
    var buf: [16384]u8 = undefined;
    var fds = [_]c.pollfd{
        .{ .fd = client, .events = c.POLL.IN, .revents = 0 },
        .{ .fd = host, .events = c.POLL.IN, .revents = 0 },
    };
    while (true) {
        if (c.poll(&fds, 2, -1) <= 0) return;
        for (fds, 0..) |f, i| {
            if (f.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) == 0) continue;
            const n = c.read(f.fd, &buf, buf.len);
            if (n <= 0) return;
            const to = if (i == 0) host else client;
            if (!writeAll(to, buf[0..@intCast(n)])) return;
            if (i == 0) sent.* += @intCast(n) else got.* += @intCast(n);
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
    if (comptime @import("builtin").os.tag == .windows) return it.fail("proxy: the egress proxy is not available on Windows yet", .{});
    if (argv.len < 2) return it.wrongArgs("dockyard::proxy start|allow|events|stop ?arg?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "start")) {
        if (the_proxy != null) return it.fail("the proxy runs", .{});
        const port: u16 = if (argv.len > 2) @intCast(std.math.clamp(try it.int(argv[2]), 0, 65535)) else 0;
        the_proxy = Proxy.start(std.heap.c_allocator, port) catch |e| return it.fail("proxy: {s}", .{@errorName(e)});
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
            const items = try it.readList(argv[2]);
            var hosts: std.ArrayList([]const u8) = .empty;
            for (items) |v| try hosts.append(a, try it.str(v));
            try p.setAllow(hosts.items);
        }
        _ = c.pthread_mutex_lock(&p.lock);
        defer _ = c.pthread_mutex_unlock(&p.lock);
        var out: std.ArrayList(ztcl.Value) = .empty;
        for (p.allow_list.items) |h| try out.append(a, .{ .str = try a.dupe(u8, h) });
        return ztcl.value.newList(a, out.items);
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
    return it.fail("bad option \"{s}\": must be start, allow, events, or stop", .{sub});
}

test "allow list entries match hosts and suffixes" {
    try std.testing.expect(matches("api.example.com", "API.example.com"));
    try std.testing.expect(!matches("api.example.com", "example.com"));
    try std.testing.expect(matches("*.example.com", "example.com"));
    try std.testing.expect(matches("*.example.com", "a.b.example.com"));
    try std.testing.expect(!matches("*.example.com", "badexample.com"));
}

test "a CONNECT line gives the host and the port" {
    const t = parseConnect("CONNECT api.example.com:443 HTTP/1.1").?;
    try std.testing.expectEqualStrings("api.example.com", t.host);
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("::1", parseConnect("CONNECT [::1]:8080 HTTP/1.1").?.host);
    try std.testing.expect(parseConnect("GET http://x/ HTTP/1.1") == null);
    try std.testing.expect(parseConnect("CONNECT x:0 HTTP/1.1") == null);
}

fn listenLocal() !struct { fd: c.fd_t, port: u16 } {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    var addr: c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.AddressInUse;
    _ = c.listen(fd, 4);
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(fd, @ptrCast(&addr), &len);
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
}

fn echoOnce(fd: c.fd_t) void {
    const conn = c.accept(fd, null, null);
    if (conn < 0) return;
    defer _ = c.close(conn);
    var buf: [64]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n > 0) _ = writeAll(conn, buf[0..@intCast(n)]);
}

fn ask(port: u16, request: []const u8, reply: []u8) ![]const u8 {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    defer _ = c.close(fd);
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.ConnectionRefused;
    if (!writeAll(fd, request)) return error.BrokenPipe;
    var len: usize = 0;
    while (len < reply.len) {
        const n = c.read(fd, reply[len..].ptr, reply.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return reply[0..len];
}

test "the proxy relays an allowed host and blocks another one" {
    // The proxy uses the sockets of the C library, which Windows has not.
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const server = try listenLocal();
    defer _ = c.close(server.fd);
    const echo = try std.Thread.spawn(.{}, echoOnce, .{server.fd});
    const p = try Proxy.start(gpa, 0);
    defer p.stop();
    try p.setAllow(&.{"127.0.0.1"});
    var buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf, "CONNECT 127.0.0.1:{d} HTTP/1.1\r\nHost: x\r\n\r\nhello", .{server.port});
    var reply: [256]u8 = undefined;
    const got = try ask(p.port, req, &reply);
    echo.join();
    try std.testing.expectEqualStrings("HTTP/1.1 200 Connection established\r\n\r\nhello", got);
    const blocked = try ask(p.port, "CONNECT other.example:443 HTTP/1.1\r\n\r\n", &reply);
    try std.testing.expect(std.mem.startsWith(u8, blocked, "HTTP/1.1 403"));
    // The relay thread records its event when both sides end.
    var evs: []Event = &.{};
    var all: std.ArrayList(Event) = .empty;
    defer {
        for (all.items) |e| gpa.free(e.host);
        all.deinit(gpa);
    }
    var k: usize = 0;
    while (all.items.len < 2 and k < 200) : (k += 1) {
        evs = try p.take();
        defer gpa.free(evs);
        try all.appendSlice(gpa, evs);
        if (all.items.len < 2) _ = c.nanosleep(&.{ .sec = 0, .nsec = 10_000_000 }, null);
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
