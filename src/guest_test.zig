//! Tests of the helper of the sandbox guest (src/guest/main.zig) and of
//! `sandbox.tcl`. The first test runs the helper on the host with Unix
//! sockets in place of vsock. The guest test boots a guest of ztcl::vm
//! when `DOCKYARD_GUEST_DIR` has the kernel and `agent.cpio`: on x86-64
//! Linux with access to /dev/kvm, and on macOS. No test runs the agent program.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const proxy = @import("proxy.zig");
const sandbox = @import("sandbox.zig");
const test_options = @import("test_options");
const c = std.c;

const on_linux = builtin.os.tag == .linux;

fn z(a: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return a.dupeSentinel(u8, s, 0);
}

fn tempDir(a: std.mem.Allocator, name: []const u8) ![:0]const u8 {
    const d = try std.fmt.allocPrint(a, "/tmp/dockyard-test-{s}-{d}", .{ name, c.getpid() });
    const dz = try z(a, d);
    _ = c.mkdir(dz.ptr, 0o755);
    return dz;
}

fn connectUnix(path: []const u8) !c.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SystemResources;
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) == 0) return fd;
        sleepMs(10);
    }
    return error.ConnectionRefused;
}

fn connectTcp(port: u16) !c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.ConnectionRefused;
    return fd;
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

fn writeAll(fd: c.fd_t, b: []const u8) !void {
    var off: usize = 0;
    while (off < b.len) {
        const n = c.write(fd, b[off..].ptr, b.len - off);
        if (n <= 0) return error.BrokenPipe;
        off += @intCast(n);
    }
}

/// Reads until the end, or until `want` is in the bytes, for 5 seconds.
fn readUntil(fd: c.fd_t, buf: []u8, want: ?[]const u8) ![]u8 {
    var have: usize = 0;
    var tries: usize = 0;
    while (have < buf.len and tries < 500) : (tries += 1) {
        var pf = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&pf, 1, 10) <= 0) continue;
        const n = c.read(fd, buf[have..].ptr, buf.len - have);
        if (n <= 0) break;
        have += @intCast(n);
        if (want) |w| if (std.mem.indexOf(u8, buf[0..have], w) != null) break;
    }
    return buf[0..have];
}

fn frame(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: u8, payload: []const u8) !void {
    var head: [5]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(payload.len + 1), .little);
    head[4] = kind;
    try out.appendSlice(a, &head);
    try out.appendSlice(a, payload);
}

fn putStr(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(s.len), .little);
    try out.appendSlice(a, &n);
    try out.appendSlice(a, s);
}

fn putList(out: *std.ArrayList(u8), a: std.mem.Allocator, l: []const []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(l.len), .little);
    try out.appendSlice(a, &n);
    for (l) |s| try putStr(out, a, s);
}

fn echoOnce(fd: c.fd_t) void {
    const conn = c.accept(fd, null, null);
    if (conn < 0) return;
    defer _ = c.close(conn);
    var buf: [256]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n > 0) _ = c.write(conn, &buf, @intCast(n));
}

test "the guest helper runs a program on a PTY, relays the proxy port, and gives the events" {
    if (comptime !on_linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tempDir(a, "guest");
    const tcp: u16 = @intCast(20000 + @mod(c.getpid(), 20000));
    const helper = try z(a, std.fmt.comptimePrint("{s}", .{test_options.guest_helper}));
    const port_z = try z(a, try std.fmt.allocPrint(a, "{d}", .{tcp}));
    const argv = [_:null]?[*:0]const u8{ helper.ptr, "serve", "--unix", dir.ptr, "--tcp", port_z.ptr, "--foreground" };
    const envp = [_:null]?[*:0]const u8{};
    const pid = c.fork();
    if (pid == 0) {
        _ = c.execve(helper.ptr, &argv, &envp);
        c._exit(127);
    }
    defer {
        _ = c.kill(pid, .KILL);
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
    }

    // The events start before the session, so the session is news.
    const ev = try connectUnix(try std.fmt.allocPrint(a, "{s}/7103", .{dir}));
    defer _ = c.close(ev);
    sleepMs(100);

    // A session: the size of the PTY, the folder, and the exit code.
    const s = try connectUnix(try std.fmt.allocPrint(a, "{s}/7100", .{dir}));
    defer _ = c.close(s);
    var open: std.ArrayList(u8) = .empty;
    var size: [4]u8 = undefined;
    std.mem.writeInt(u16, size[0..2], 30, .little);
    std.mem.writeInt(u16, size[2..4], 100, .little);
    try open.appendSlice(a, &size);
    try putList(&open, a, &.{ "/bin/sh", "-c", "stty size; pwd; sleep 0.2; exit 3" });
    try putList(&open, a, &.{"PATH=/usr/bin:/bin"});
    try putStr(&open, a, "/tmp");
    var msg: std.ArrayList(u8) = .empty;
    try frame(&msg, a, 0x01, open.items);
    try writeAll(s, msg.items);
    var buf: [8192]u8 = undefined;
    const got = try readUntil(s, &buf, null);
    try std.testing.expect(got.len > 5 and got[4] == 0x10);
    try std.testing.expect(std.mem.indexOf(u8, got, "30 100\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "/tmp\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, &.{ 5, 0, 0, 0, 0x12, 3, 0, 0, 0 }));
    var ebuf: [4096]u8 = undefined;
    const evs = try readUntil(ev, &ebuf, "\"sleep\",\"0.2\"]");
    try std.testing.expect(std.mem.indexOf(u8, evs, "{\"type\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs, "\"argv\":[\"sleep\",\"0.2\"]") != null);

    // The relay: a client of the proxy port reaches the egress proxy,
    // which connects to an allowed server.
    const p = try proxy.Proxy.start(std.testing.allocator, 0);
    defer p.stop();
    try p.setAllow(&.{"127.0.0.1"});
    const server = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    defer _ = c.close(server);
    var addr: c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    try std.testing.expect(c.bind(server, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0);
    _ = c.listen(server, 4);
    var alen: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(server, @ptrCast(&addr), &alen);
    const echo = try std.Thread.spawn(.{}, echoOnce, .{server});
    const ctl = try connectUnix(try std.fmt.allocPrint(a, "{s}/7101", .{dir}));
    defer _ = c.close(ctl);
    const client = try connectTcp(tcp);
    defer _ = c.close(client);
    var id: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), (try readUntil(ctl, &id, null)).len);
    const data = try connectUnix(try std.fmt.allocPrint(a, "{s}/7102", .{dir}));
    try writeAll(data, &id);
    try p.attach(data);
    const req = try std.fmt.allocPrint(a, "CONNECT 127.0.0.1:{d} HTTP/1.1\r\n\r\nhello", .{std.mem.bigToNative(u16, addr.port)});
    try writeAll(client, req);
    var rbuf: [256]u8 = undefined;
    const reply = try readUntil(client, &rbuf, "hello");
    echo.join();
    try std.testing.expectEqualStrings("HTTP/1.1 200 Connection established\r\n\r\nhello", reply);
}

fn hasKvm() bool {
    return c.access("/dev/kvm", 6) == 0 and c.access("/dev/vhost-vsock", 6) == 0;
}

fn copyFile(a: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const in = c.open((try z(a, src)).ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (in < 0) return error.FileNotFound;
    defer _ = c.close(in);
    const out = c.open((try z(a, dst)).ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o755));
    if (out < 0) return error.AccessDenied;
    defer _ = c.close(out);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(in, &buf, buf.len);
        if (n <= 0) return;
        try writeAll(out, buf[0..@intCast(n)]);
    }
}

fn ticks(_: ?*anyopaque) i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
}

fn hostSleep(_: ?*anyopaque, us: i64) void {
    if (us <= 0) return;
    var ts: c.timespec = .{ .sec = @intCast(@divTrunc(us, 1_000_000)), .nsec = @intCast(@mod(us, 1_000_000) * 1000) };
    _ = c.nanosleep(&ts, null);
}

const kvm_script =
    \\set kernel [expr {[file exists bzImage] ? "bzImage" : "Image"}]
    \\set vm [dockyard::sandbox::boot -kernel $kernel -initrd agent.cpio -helper dockyard-guest -memory 128]
    \\set ::out ""
    \\set ::events {}
    \\proc out {t} {append ::out $t}
    \\proc ex {code} {set ::done $code}
    \\proc ev {d} {lappend ::events $d}
    \\dockyard::sandbox::events $vm ev
    \\after 200
    \\set s [dockyard::sandbox::session $vm -rows 30 -cols 100 -output out -exit ex]
    \\dockyard::sandbox::input $s "/bin/busybox stty size; echo héllo; /bin/busybox sleep 0.3; exit 4\n"
    \\after 10000 {set ::done timeout}
    \\vwait ::done
    \\set argv {}
    \\foreach e $::events {if {[dict get $e type] eq "exec"} {lappend argv [dict get $e argv]}}
    \\ztcl::vm delete $vm
    \\list $::done [string match "*30 100*héllo*" $::out] [expr {[list /bin/busybox sleep 0.3] in $argv}]
;

test "the terminal of the sandbox runs on a PTY of a guest over vsock" {
    // KVM on x86-64 Linux, and Virtualization.framework on macOS. The
    // guest folder has `bzImage` (x86-64) or `Image` (arm64), and `agent.cpio`.
    if (comptime !((on_linux and builtin.cpu.arch == .x86_64) or builtin.os.tag == .macos)) return error.SkipZigTest;
    const src = std.mem.sliceTo(c.getenv("DOCKYARD_GUEST_DIR") orelse return error.SkipZigTest, 0);
    if (comptime on_linux) if (!hasKvm()) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tempDir(a, "kvm");
    const kernel = if (builtin.cpu.arch == .x86_64) "bzImage" else "Image";
    try copyFile(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ src, kernel }), try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, kernel }));
    try copyFile(a, try std.fmt.allocPrint(a, "{s}/agent.cpio", .{src}), try std.fmt.allocPrint(a, "{s}/agent.cpio", .{dir}));
    try copyFile(a, std.fmt.comptimePrint("{s}", .{test_options.guest_helper}), try std.fmt.allocPrint(a, "{s}/dockyard-guest", .{dir}));

    var it: ztcl.Interp = undefined;
    try it.init(std.heap.page_allocator);
    defer it.deinit();
    const cap = ztcl.interp.Capability;
    try it.allow(@backingInt(cap.vm) | @backingInt(cap.file) | @backingInt(cap.channels) | @backingInt(cap.event));
    try ztcl.fsroot.setRoot(&it, dir);
    it.event_host = .{ .now = ticks, .sleep = hostSleep };
    _ = it.eval(sandbox.script) catch return error.TclError;
    const res = it.eval(kvm_script) catch {
        std.debug.print("{s}\n", .{it.str(it.result) catch "error"});
        return error.TclError;
    };
    try std.testing.expectEqualStrings("4 1 1", try it.str(res));
}
