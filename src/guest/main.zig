//! dockyard-guest: the helper of dockyard in the guest of the sandbox
//! (issue 13). The host copies it into the guest with the agent of
//! ztcl::vm and starts it with `dockyard-guest serve`. The helper then
//! listens on two vsock ports, and connects to one port of the host.
//! `docs/dev/guest.md` has the protocol.
//!
//!   7100  A terminal session: a program on a PTY of the guest.
//!   7101  The relay, on the host (CID 2): the helper connects once for
//!         each TCP client of the proxy port, and the bytes go both ways.
//!         `serve --relay PORT` gives another port.
//!   7103  The events: one JSON line for each program that starts or ends.
//!
//! The proxy port is 127.0.0.1:3128 of the guest. A guest kernel with no
//! IPv4 has no proxy port, and the helper writes a line on stderr. The
//! kernel starts with the loopback device down, so the helper sets the
//! flag IFF_UP of `lo` (SIOCGIFFLAGS, then SIOCSIFFLAGS) before it binds.
//!
//! The helper uses no libc, so one file builds for each architecture:
//!
//!   zig build-exe -target x86_64-linux-musl -O ReleaseSmall main.zig
//!
//! The tests run it on the host with `--unix DIR` (Unix sockets
//! DIR/7100, DIR/7101, and DIR/7103 in place of vsock), `--tcp PORT`, and
//! `--foreground`.
const std = @import("std");
const linux = std.os.linux;

pub const port_session: u32 = 7100;
pub const port_relay: u32 = 7101;
pub const port_events: u32 = 7103;
pub const max_frame = (1 << 20) + 1;

// The frames of a session (port 7100).
pub const t_open = 0x01; // host: rows u16, cols u16, argv list, env list, cwd string
pub const t_input = 0x02; // host: bytes for the PTY
pub const t_resize = 0x03; // host: rows u16, cols u16
pub const t_signal = 0x04; // host: signal u8 for the process group
pub const t_started = 0x10; // guest: pid u32
pub const t_output = 0x11; // guest: bytes of the PTY
pub const t_exit = 0x12; // guest: code i32 (minus the signal)
pub const t_error = 0x3f; // guest: errno u32, message string

const AF_VSOCK = 40;
const VMADDR_CID_ANY: u32 = 0xffff_ffff;
const VMADDR_CID_HOST: u32 = 2;
const TIOCSCTTY = 0x540E;
const TIOCSWINSZ = 0x5414;
const TIOCGPTN = 0x80045430;
const TIOCSPTLCK = 0x40045431;

const SockaddrVm = extern struct {
    family: u16 = AF_VSOCK,
    reserved1: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },
};

const SockaddrUn = extern struct { family: u16 = linux.AF.UNIX, path: [108]u8 = @splat(0) };

const SockaddrIn = extern struct {
    family: u16 = linux.AF.INET,
    port: u16,
    addr: u32,
    zero: [8]u8 = @splat(0),
};

fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

fn say(text: []const u8) void {
    _ = linux.write(2, text.ptr, text.len);
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) off += ok(linux.write(fd, bytes[off..].ptr, bytes.len - off)) orelse return false;
    return true;
}

fn send(c: i32, kind: u8, payload: []const u8) bool {
    var head: [5]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(payload.len + 1), .little);
    head[4] = kind;
    return writeAll(c, &head) and writeAll(c, payload);
}

fn sendError(c: i32, err: u32, text: []const u8) void {
    var b: [264]u8 = undefined;
    const t = text[0..@min(text.len, 256)];
    std.mem.writeInt(u32, b[0..4], err, .little);
    std.mem.writeInt(u32, b[4..8], @intCast(t.len), .little);
    @memcpy(b[8..][0..t.len], t);
    _ = send(c, t_error, b[0 .. 8 + t.len]);
}

fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn sleepMs(ms: u32) void {
    var ts: linux.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

// The options of the command line.
var unix_dir: ?[]const u8 = null;
var tcp_port: u16 = 3128;
/// The relay port of the host. On KVM the vsock ports of the host are
/// one space for each host, so each guest of a host gets its own port.
var relay_port: u32 = port_relay;
/// `serve --framed`: the relay speaks the framed relay of ztcl
/// (`ztcl::vm listen -framed 1`) to the host.
var relay_framed = false;
var foreground = false;
var self_pid: i32 = 0;

fn listenOn(port: u32) ?i32 {
    if (unix_dir) |dir| {
        const fd: i32 = @intCast(ok(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return null);
        var addr: SockaddrUn = .{};
        const p = std.fmt.bufPrint(addr.path[0 .. addr.path.len - 1], "{s}/{d}", .{ dir, port }) catch return null;
        _ = linux.unlink(@ptrCast(addr.path[0..p.len :0]));
        _ = ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) orelse return null;
        _ = ok(linux.listen(fd, 16)) orelse return null;
        return fd;
    }
    const fd: i32 = @intCast(ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return null);
    var addr: SockaddrVm = .{ .port = port, .cid = VMADDR_CID_ANY };
    _ = ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) orelse return null;
    _ = ok(linux.listen(fd, 16)) orelse return null;
    return fd;
}

/// A connection to `port` of the host: vsock CID 2, or DIR/PORT with
/// `--unix DIR`.
fn connectHost(port: u32) ?i32 {
    if (unix_dir) |dir| {
        const fd: i32 = @intCast(ok(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return null);
        var addr: SockaddrUn = .{};
        _ = std.fmt.bufPrint(addr.path[0 .. addr.path.len - 1], "{s}/{d}", .{ dir, port }) catch return null;
        if (ok(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) == null) {
            _ = linux.close(fd);
            return null;
        }
        return fd;
    }
    const fd: i32 = @intCast(ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return null);
    var addr: SockaddrVm = .{ .port = port, .cid = VMADDR_CID_HOST };
    if (ok(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) == null) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// The `struct ifreq` of the kernel: the name, then a union of 24 bytes
/// with the flags first.
const Ifreq = extern struct { name: [16]u8 = @splat(0), flags: i16 = 0, pad: [22]u8 = @splat(0) };
const SIOCGIFFLAGS = 0x8913;
const SIOCSIFFLAGS = 0x8914;
const IFF_UP = 0x1;

/// Sets IFF_UP on `lo` through the socket `fd` of AF_INET.
fn loopbackUp(fd: i32) bool {
    var ifr: Ifreq = .{};
    @memcpy(ifr.name[0..2], "lo");
    _ = ok(linux.ioctl(fd, SIOCGIFFLAGS, @intFromPtr(&ifr))) orelse return false;
    if (ifr.flags & IFF_UP != 0) return true;
    ifr.flags |= IFF_UP;
    return ok(linux.ioctl(fd, SIOCSIFFLAGS, @intFromPtr(&ifr))) != null;
}

fn listenTcp(port: u16) ?i32 {
    const fd: i32 = @intCast(ok(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return null);
    if (!loopbackUp(fd)) say("dockyard-guest: no loopback device up\n");
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var addr: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
    _ = ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrIn))) orelse return null;
    _ = ok(linux.listen(fd, 64)) orelse return null;
    return fd;
}

/// Mounts devpts at /dev/pts when the guest has no PTY folder, as after
/// the start of the agent of ztcl, which mounts devtmpfs only.
fn ptyFolder() void {
    if (linux.errno(linux.access("/dev/pts/ptmx", 0)) == .SUCCESS) return;
    _ = linux.mkdir("/dev/pts", 0o755);
    _ = linux.mount("devpts", "/dev/pts", "devpts", 0, @intFromPtr(@as([*:0]const u8, "ptmxmode=0666,mode=0620")));
}

pub fn main(init: std.process.Init.Minimal) void {
    const argv = init.args.vector;
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "hook")) {
        if (argv.len >= 3) hook_dir = std.mem.sliceTo(argv[2], 0);
        hook();
    }
    if (argv.len < 2 or !std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "serve")) {
        say("usage: dockyard-guest serve ?--unix DIR? ?--tcp PORT? ?--hooks DIR? ?--foreground? | dockyard-guest hook ?DIR?\n");
        linux.exit_group(2);
    }
    var k: usize = 2;
    while (k < argv.len) : (k += 1) {
        const a = std.mem.sliceTo(argv[k], 0);
        if (std.mem.eql(u8, a, "--foreground")) {
            foreground = true;
        } else if (k + 1 < argv.len and std.mem.eql(u8, a, "--unix")) {
            k += 1;
            unix_dir = std.mem.sliceTo(argv[k], 0);
        } else if (k + 1 < argv.len and std.mem.eql(u8, a, "--hooks")) {
            k += 1;
            hook_dir = std.mem.sliceTo(argv[k], 0);
        } else if (std.mem.eql(u8, a, "--framed")) {
            relay_framed = true;
        } else if (k + 1 < argv.len and std.mem.eql(u8, a, "--relay")) {
            k += 1;
            relay_port = std.fmt.parseInt(u32, std.mem.sliceTo(argv[k], 0), 10) catch port_relay;
        } else if (k + 1 < argv.len and std.mem.eql(u8, a, "--tcp")) {
            k += 1;
            tcp_port = std.fmt.parseInt(u16, std.mem.sliceTo(argv[k], 0), 10) catch 3128;
        } else {
            say("dockyard-guest: unknown option\n");
            linux.exit_group(2);
        }
    }
    if (linux.getuid() == 0) ptyFolder();
    const ports = [_]u32{ port_session, port_events };
    var fds: [3]linux.pollfd = undefined;
    for (ports, 0..) |p, i| {
        const fd = listenOn(p) orelse {
            say("dockyard-guest: no socket for a port\n");
            linux.exit_group(1);
        };
        fds[i] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    }
    var n_fds: usize = 2;
    if (listenTcp(tcp_port)) |fd| {
        fds[2] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
        n_fds = 3;
    } else say("dockyard-guest: no IPv4 in this guest, so no proxy port\n");
    if (!foreground) daemon();
    self_pid = linux.getpid();
    // A connection child of a session waits for its own program.
    var sa: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.CHLD, &sa, null);
    _ = linux.sigaction(.PIPE, &sa, null);
    // The ready line: the tests and the host wait for it in foreground mode.
    if (foreground) say("dockyard-guest: ready\n");
    serve(fds[0..n_fds]);
}

/// Goes to the background: a new session, and stdin, stdout, and stderr
/// on /dev/null, so the exec of the agent sees the end of its pipes.
fn daemon() void {
    const pid = linux.fork();
    if (pid != 0) linux.exit_group(0);
    _ = linux.setsid();
    const nul: i32 = @intCast(ok(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0)) orelse return);
    _ = linux.dup3(nul, 0, 0);
    _ = linux.dup3(nul, 1, 0);
    _ = linux.dup3(nul, 2, 0);
    if (nul > 2) _ = linux.close(nul);
}

fn serve(fds: []linux.pollfd) void {
    while (true) {
        _ = ok(linux.poll(fds.ptr, fds.len, -1)) orelse continue;
        for (fds, 0..) |f, i| {
            if (f.revents == 0) continue;
            const c: i32 = @intCast(ok(linux.accept4(f.fd, null, null, linux.SOCK.CLOEXEC)) orelse continue);
            switch (i) {
                0 => inChild(c, fds, session),
                1 => inChild(c, fds, events),
                else => inChild(c, fds, relay),
            }
        }
    }
}

fn inChild(c: i32, fds: []linux.pollfd, comptime run: fn (i32) void) void {
    const pid = linux.fork();
    if (pid == 0) {
        for (fds) |f| _ = linux.close(f.fd);
        var dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.CHLD, &dfl, null);
        run(c);
        linux.exit_group(0);
    }
    _ = linux.close(c);
}

/// A TCP client of the proxy port: a connection to the relay port of the
/// host, then the bytes go both ways. With no listener on the host, the
/// client closes.
fn relay(c: i32) void {
    const h = connectHost(relay_port) orelse return;
    if (relay_framed) spliceFramed(c, h) else splice(c, h);
}

/// The framed relay of ztcl (docs/dev/vm-agent.md of ztcl): the preamble
/// `ZTRELAY1`, then in each direction frames of a kind byte (0 data, 1
/// end), a length (u32, little endian, at most 65,536), and the data.
/// The end of the client `a` is an end frame to the host `b`, and an end
/// frame of the host is a shutdown of the writes to the client. The copy
/// ends when both directions end, or when the host closes.
fn spliceFramed(a: i32, b: i32) void {
    const max = 65536;
    if (!writeAll(b, "ZTRELAY1")) return;
    var out: [5 + max]u8 = undefined;
    var in: [2 * (5 + max)]u8 = undefined;
    var have: usize = 0;
    var open_a = true;
    var host_done = false;
    while (open_a or !host_done) {
        var pf = [2]linux.pollfd{
            .{ .fd = if (open_a) a else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = b, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = ok(linux.poll(&pf, 2, -1)) orelse return;
        if (pf[0].revents != 0) {
            const n = ok(linux.read(a, out[5..].ptr, max)) orelse 0;
            out[0] = if (n == 0) 1 else 0;
            std.mem.writeInt(u32, out[1..5], @intCast(n), .little);
            if (!writeAll(b, out[0 .. 5 + n])) return;
            if (n == 0) open_a = false;
        }
        if (pf[1].revents != 0) {
            const n = ok(linux.read(b, in[have..].ptr, in.len - have)) orelse 0;
            if (n == 0) return;
            have += n;
            var at: usize = 0;
            while (have - at >= 5) {
                const len = std.mem.readInt(u32, in[at + 1 ..][0..4], .little);
                if (len > max) return;
                if (have - at < 5 + len) break;
                switch (in[at]) {
                    0 => if (!host_done and !writeAll(a, in[at + 5 .. at + 5 + len])) return,
                    1 => {
                        host_done = true;
                        _ = linux.shutdown(a, linux.SHUT.WR);
                    },
                    else => return,
                }
                at += 5 + len;
            }
            std.mem.copyForwards(u8, in[0 .. have - at], in[at..have]);
            have -= at;
        }
    }
}

/// Copies the bytes both ways between the client `a` and the host `b`.
/// The end of `b` ends the copy, and the process exits, so both ends
/// close. The end of `a` stops the reads of `a` only: the answer of the
/// host still goes to the client. The relay sends no half close to the
/// host, since the vsock of VZ drops a half close while the host has
/// unread data. The sandbox uses `spliceFramed` (`serve --framed`); this
/// copy is for a host with no framed relay, as in the host test.
fn splice(a: i32, b: i32) void {
    var buf: [65536]u8 = undefined;
    var open_a = true;
    while (true) {
        var pf = [2]linux.pollfd{
            .{ .fd = if (open_a) a else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = b, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = ok(linux.poll(&pf, 2, -1)) orelse return;
        if (pf[0].revents != 0) {
            const n = ok(linux.read(a, &buf, buf.len)) orelse 0;
            if (n == 0) open_a = false else if (!writeAll(b, buf[0..n])) return;
        }
        if (pf[1].revents != 0) {
            const n = ok(linux.read(b, &buf, buf.len)) orelse 0;
            if (n == 0 or !writeAll(a, buf[0..n])) return;
        }
    }
}

// The frames that come in on a connection.
const Frame = struct { kind: u8, payload: []u8, size: usize };

const In = struct {
    fd: i32,
    buf: []u8,
    have: usize = 0,
    closed: bool = false,

    fn fill(in: *In) void {
        if (in.have == in.buf.len) return;
        const n = ok(linux.read(in.fd, in.buf[in.have..].ptr, in.buf.len - in.have)) orelse 0;
        if (n == 0) in.closed = true;
        in.have += n;
    }

    fn frame(in: *In) ?Frame {
        if (in.have < 5) return null;
        const len = std.mem.readInt(u32, in.buf[0..4], .little);
        if (len == 0 or len > max_frame) {
            in.closed = true;
            return null;
        }
        if (in.have < 4 + len) return null;
        return .{ .kind = in.buf[4], .payload = in.buf[5 .. 4 + len], .size = 4 + len };
    }

    fn drop(in: *In, n: usize) void {
        std.mem.copyForwards(u8, in.buf[0 .. in.have - n], in.buf[n..in.have]);
        in.have -= n;
    }
};

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn int(r: *Reader, comptime T: type) ?T {
        if (r.b.len - r.i < @sizeOf(T)) return null;
        defer r.i += @sizeOf(T);
        return std.mem.readInt(T, r.b[r.i..][0..@sizeOf(T)], .little);
    }
    fn str(r: *Reader) ?[]const u8 {
        const n = r.int(u32) orelse return null;
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
};

var in_buf: [max_frame + 4]u8 = undefined;
var strings: [1 << 18]u8 = undefined;
var argv_buf: [256:null]?[*:0]const u8 = undefined;
var env_buf: [256:null]?[*:0]const u8 = undefined;

fn putZ(at: *usize, s: []const u8) ?[*:0]u8 {
    if (strings.len - at.* < s.len + 1) return null;
    const p = strings[at.*..];
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    at.* += s.len + 1;
    return @ptrCast(p.ptr);
}

fn list(r: *Reader, at: *usize, out: [:null]?[*:0]const u8) ?void {
    const n = r.int(u32) orelse return null;
    if (n > out.len) return null;
    for (0..n) |k| out[k] = putZ(at, r.str() orelse return null) orelse return null;
    out[n] = null;
}

const Winsize = extern struct { rows: u16, cols: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

fn openPty(name: *[32]u8) ?i32 {
    const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
    const m: i32 = @intCast(ok(linux.open("/dev/ptmx", flags, 0)) orelse
        ok(linux.open("/dev/pts/ptmx", flags, 0)) orelse return null);
    var unlock: i32 = 0;
    var n: u32 = 0;
    if (ok(linux.ioctl(m, TIOCSPTLCK, @intFromPtr(&unlock))) == null or
        ok(linux.ioctl(m, TIOCGPTN, @intFromPtr(&n))) == null)
    {
        _ = linux.close(m);
        return null;
    }
    const s = std.fmt.bufPrint(name[0..31], "/dev/pts/{d}", .{n}) catch return null;
    name[s.len] = 0;
    return m;
}

/// A terminal session: the first frame is `open`, then the bytes of the
/// PTY go out as `output` frames until the program ends.
fn session(c: i32) void {
    var in: In = .{ .fd = c, .buf = &in_buf };
    const f = while (true) {
        if (in.frame()) |f| break f;
        if (in.closed) return;
        in.fill();
    };
    if (f.kind != t_open) return sendError(c, 22, "the first frame is not open");
    var r: Reader = .{ .b = f.payload };
    var at: usize = 0;
    const rows = r.int(u16) orelse return sendError(c, 22, "bad open frame");
    const cols = r.int(u16) orelse return sendError(c, 22, "bad open frame");
    list(&r, &at, &argv_buf) orelse return sendError(c, 22, "bad open frame");
    list(&r, &at, &env_buf) orelse return sendError(c, 22, "bad open frame");
    const cwd_s = r.str() orelse return sendError(c, 22, "bad open frame");
    const cwd = putZ(&at, if (cwd_s.len == 0) "/" else cwd_s) orelse return sendError(c, 36, "folder name too long");
    const prog = argv_buf[0] orelse return sendError(c, 22, "no program");
    in.drop(f.size);

    var name: [32]u8 = undefined;
    const m = openPty(&name) orelse return sendError(c, 5, "no PTY");
    var ws: Winsize = .{ .rows = rows, .cols = cols };
    _ = linux.ioctl(m, TIOCSWINSZ, @intFromPtr(&ws));
    var stat: [2]i32 = undefined;
    _ = ok(linux.pipe2(&stat, .{ .CLOEXEC = true })) orelse return sendError(c, 24, "no pipe");
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.setsid();
        const s: i32 = @intCast(ok(linux.open(@ptrCast(&name), .{ .ACCMODE = .RDWR }, 0)) orelse linux.exit_group(126));
        _ = linux.ioctl(s, TIOCSCTTY, 0);
        _ = linux.dup3(s, 0, 0);
        _ = linux.dup3(s, 1, 0);
        _ = linux.dup3(s, 2, 0);
        if (s > 2) _ = linux.close(s);
        var e: u32 = 0;
        if (linux.errno(linux.chdir(cwd)) == .SUCCESS) {
            e = @backingInt(linux.errno(linux.execve(prog, &argv_buf, &env_buf)));
        } else e = 2;
        _ = linux.write(stat[1], std.mem.asBytes(&e).ptr, 4);
        linux.exit_group(127);
    }
    _ = linux.close(stat[1]);
    var e: u32 = 0;
    if ((ok(linux.read(stat[0], std.mem.asBytes(&e).ptr, 4)) orelse 0) == 4) {
        var st: i32 = 0;
        _ = linux.wait4(@intCast(pid), &st, 0, null);
        return sendError(c, e, "the program did not start");
    }
    _ = linux.close(stat[0]);
    var pb: [4]u8 = undefined;
    std.mem.writeInt(u32, &pb, @intCast(pid), .little);
    _ = send(c, t_started, &pb);
    pump(c, m, &in, @intCast(pid));
}

fn pump(c: i32, m: i32, in: *In, pid: i32) void {
    var buf: [65536]u8 = undefined;
    var pty_open = true;
    while (true) {
        while (in.frame()) |f| {
            var r: Reader = .{ .b = f.payload };
            switch (f.kind) {
                t_input => _ = writeAll(m, f.payload),
                t_resize => if (r.int(u16)) |rows| if (r.int(u16)) |cols| {
                    var ws: Winsize = .{ .rows = rows, .cols = cols };
                    _ = linux.ioctl(m, TIOCSWINSZ, @intFromPtr(&ws));
                },
                t_signal => if (f.payload.len >= 1) {
                    _ = linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, -pid))), f.payload[0]);
                },
                else => {},
            }
            in.drop(f.size);
        }
        if (in.closed) {
            // The host went away: end the program, as the agent of ztcl does.
            _ = linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, -pid))), 9);
            break;
        }
        if (!pty_open) break;
        var pf = [2]linux.pollfd{
            .{ .fd = c, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = m, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = ok(linux.poll(&pf, 2, -1)) orelse continue;
        if (pf[0].revents != 0) in.fill();
        if (pf[1].revents != 0) {
            // EIO after the last process of the PTY closed it.
            const n = ok(linux.read(m, &buf, buf.len)) orelse 0;
            if (n == 0) pty_open = false else if (!send(c, t_output, buf[0..n])) in.closed = true;
        }
    }
    var sti: i32 = 0;
    _ = linux.wait4(pid, &sti, 0, null);
    const st: u32 = @bitCast(sti);
    const sig = st & 0x7f;
    const code: i32 = if (sig == 0) @intCast((st >> 8) & 0xff) else -@as(i32, @intCast(sig));
    var cb: [4]u8 = undefined;
    std.mem.writeInt(i32, &cb, code, .little);
    _ = send(c, t_exit, &cb);
}

// The events: a scan of /proc every 50 ms. A program counts when the
// helper is one of its parents, so the agent of ztcl and the helper
// itself are not in the stream.
const Seen = struct { pid: i32, start: u64, alive: bool };
var seen: [1024]?Seen = @splat(null);

fn events(c: i32) void {
    var first = true;
    while (true) {
        for (&seen) |*s| if (s.*) |*v| {
            v.alive = false;
        };
        if (!scan(c, first)) return;
        if (!sendHooks(c)) return;
        first = false;
        for (&seen) |*s| if (s.*) |v| if (!v.alive) {
            var line: [128]u8 = undefined;
            const t = std.fmt.bufPrint(&line, "{{\"type\":\"exit\",\"time\":{d},\"pid\":{d}}}\n", .{ nowMs(), v.pid }) catch unreachable;
            if (!writeAll(c, t)) return;
            s.* = null;
        };
        sleepMs(50);
        // A closed host ends the stream.
        var pf = [1]linux.pollfd{.{ .fd = c, .events = linux.POLL.IN, .revents = 0 }};
        if ((ok(linux.poll(&pf, 1, 0)) orelse 0) != 0) {
            var b: [64]u8 = undefined;
            if ((ok(linux.read(c, &b, b.len)) orelse 0) == 0) return;
        }
    }
}

var dents: [16384]u8 align(8) = undefined;

fn scan(c: i32, first: bool) bool {
    const d: i32 = @intCast(ok(linux.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)) orelse return true);
    defer _ = linux.close(d);
    while (true) {
        const n = ok(linux.getdents64(d, &dents, dents.len)) orelse return true;
        if (n == 0) return true;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&dents[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            const pid = std.fmt.parseInt(i32, name, 10) catch continue;
            if (!note(c, pid, first)) return false;
        }
    }
}

/// The parent and the start time of a process, from /proc/PID/stat.
fn statOf(pid: i32) ?struct { ppid: i32, start: u64 } {
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/stat", .{pid}, 0) catch return null;
    var buf: [1024]u8 = undefined;
    const t = readFile(p, &buf) orelse return null;
    // The name of the program is in parentheses and may have spaces.
    const close = std.mem.lastIndexOfScalar(u8, t, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, t[close + 1 ..], ' ');
    var field: usize = 3;
    var ppid: i32 = 0;
    while (it.next()) |w| : (field += 1) {
        if (field == 4) ppid = std.fmt.parseInt(i32, w, 10) catch return null;
        if (field == 22) return .{ .ppid = ppid, .start = std.fmt.parseInt(u64, w, 10) catch return null };
    }
    return null;
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd: i32 = @intCast(ok(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)) orelse return null);
    defer _ = linux.close(fd);
    var have: usize = 0;
    while (have < buf.len) {
        const n = ok(linux.read(fd, buf[have..].ptr, buf.len - have)) orelse return null;
        if (n == 0) break;
        have += n;
    }
    return buf[0..have];
}

fn underSelf(pid: i32) bool {
    var p = pid;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const s = statOf(p) orelse return false;
        if (s.ppid == self_pid) return true;
        if (s.ppid <= 1) return false;
        p = s.ppid;
    }
    return false;
}

fn note(c: i32, pid: i32, first: bool) bool {
    const s = statOf(pid) orelse return true;
    for (&seen) |*e| if (e.*) |*v| if (v.pid == pid and v.start == s.start) {
        v.alive = true;
        return true;
    };
    // The connection child of this stream and the sessions are not news.
    if (pid == linux.getpid() or s.ppid == self_pid or !underSelf(pid)) return true;
    const slot = for (&seen) |*e| {
        if (e.* == null) break e;
    } else return true;
    slot.* = .{ .pid = pid, .start = s.start, .alive = true };
    if (first) return true;
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/cmdline", .{pid}, 0) catch return true;
    var buf: [4096]u8 = undefined;
    const cmd = readFile(p, &buf) orelse return true;
    var line: [16384]u8 = undefined;
    var w: usize = 0;
    w += (std.fmt.bufPrint(line[w..], "{{\"type\":\"exec\",\"time\":{d},\"pid\":{d},\"ppid\":{d},\"argv\":[", .{ nowMs(), pid, s.ppid }) catch return true).len;
    var args = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cmd, "\x00"), 0);
    var k: usize = 0;
    while (args.next()) |arg| : (k += 1) {
        if (k > 0) {
            line[w] = ',';
            w += 1;
        }
        w = jsonString(&line, w, arg) orelse return true;
    }
    const tail = "]}\n";
    if (w + tail.len > line.len) return true;
    @memcpy(line[w..][0..tail.len], tail);
    w += tail.len;
    return writeAll(c, line[0..w]);
}

fn jsonString(out: []u8, at: usize, s: []const u8) ?usize {
    var w = at;
    if (w + 2 + s.len * 6 > out.len) return null;
    out[w] = '"';
    w += 1;
    for (s) |ch| {
        if (ch == '"' or ch == '\\') {
            out[w] = '\\';
            out[w + 1] = ch;
            w += 2;
        } else if (ch < 0x20) {
            const hex = "0123456789abcdef";
            @memcpy(out[w..][0..4], "\\u00");
            out[w + 4] = hex[ch >> 4];
            out[w + 5] = hex[ch & 15];
            w += 6;
        } else {
            out[w] = ch;
            w += 1;
        }
    }
    out[w] = '"';
    return w + 1;
}

// ---- Hooks of the agent program ----

/// The folder where `dockyard-guest hook` puts one file for each hook
/// call. The events stream reads the files there.
/// `serve --hooks DIR` and `hook DIR` change it, for the tests on the host.
var hook_dir: [:0]const u8 = "/tmp/dockyard-hooks";
var hook_in: [256 * 1024]u8 = undefined;
var hook_heap: [256 * 1024]u8 = undefined;
var hook_line: [64 * 1024]u8 = undefined;

/// `dockyard-guest hook`: the command of each hook of the agent program.
/// It reads the JSON of the hook on stdin, keeps the event, the tool,
/// the session, and the main argument of the tool, and writes them as
/// one flat JSON line to a new file in `hook_dir`. A temporary name and
/// a rename make each file whole before the events stream sees it. The
/// exit code is 0 in each case, so a hook never stops the agent program.
fn hook() noreturn {
    var n: usize = 0;
    while (n < hook_in.len) {
        const r = ok(linux.read(0, hook_in[n..].ptr, hook_in.len - n)) orelse break;
        if (r == 0) break;
        n += r;
    }
    var vals: [hook_fields.len]?[]const u8 = @splat(null);
    var p: Json = .{ .s = hook_in[0..n] };
    if (!p.object(&vals, .top)) linux.exit_group(0);
    var w = (std.fmt.bufPrint(&hook_line, "{{\"type\":\"hook\",\"time\":{d}", .{nowMs()}) catch linux.exit_group(0)).len;
    for (hook_fields, vals) |f, val| {
        w = putField(w, f.key, trimUtf8(val orelse continue, f.max)) orelse linux.exit_group(0);
    }
    if (w + 2 > hook_line.len) linux.exit_group(0);
    @memcpy(hook_line[w..][0..2], "}\n");
    w += 2;
    _ = linux.mkdir(hook_dir, 0o700);
    var tmp: [512]u8 = undefined;
    var name: [512]u8 = undefined;
    const pid = linux.getpid();
    const tz = std.fmt.bufPrintSentinel(&tmp, "{s}/.{d}", .{ hook_dir, pid }, 0) catch linux.exit_group(0);
    const nz = std.fmt.bufPrintSentinel(&name, "{s}/{d:0>13}-{d}", .{ hook_dir, nowMs(), pid }, 0) catch linux.exit_group(0);
    const fd: i32 = @intCast(ok(linux.open(tz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600)) orelse linux.exit_group(0));
    const good = writeAll(fd, hook_line[0..w]);
    _ = linux.close(fd);
    if (good) _ = linux.rename(tz, nz) else _ = linux.unlink(tz);
    linux.exit_group(0);
}

/// The fields of a hook that go on the events stream: the key on the
/// stream, the key in the JSON of the hook, and true for a key of
/// `tool_input`.
/// The part of the JSON of a hook that a field comes from: the top
/// object, `tool_input`, or `tool_response`.
const Scope = enum(u8) { top, input, response };

/// The fields of a hook that go to the events stream, each cut at
/// `max` bytes.
const hook_fields = [_]struct { key: []const u8, from: []const u8, scope: Scope, max: usize = 500 }{
    .{ .key = "event", .from = "hook_event_name", .scope = .top },
    .{ .key = "tool", .from = "tool_name", .scope = .top },
    .{ .key = "session", .from = "session_id", .scope = .top },
    .{ .key = "call", .from = "tool_use_id", .scope = .top },
    .{ .key = "prompt", .from = "prompt", .scope = .top, .max = 2000 },
    .{ .key = "path", .from = "file_path", .scope = .input },
    .{ .key = "command", .from = "command", .scope = .input, .max = 2000 },
    .{ .key = "pattern", .from = "pattern", .scope = .input },
    .{ .key = "url", .from = "url", .scope = .input },
    .{ .key = "old", .from = "old_string", .scope = .input, .max = 2000 },
    .{ .key = "new", .from = "new_string", .scope = .input, .max = 2000 },
    .{ .key = "content", .from = "content", .scope = .input, .max = 2000 },
    .{ .key = "stdout", .from = "stdout", .scope = .response, .max = 2000 },
    .{ .key = "stderr", .from = "stderr", .scope = .response, .max = 2000 },
};

/// A small reader of the JSON of a hook. It finds the string values of
/// `hook_fields` in the top object and in its object `tool_input`, and
/// skips each other value. The decoded strings go in `hook_heap`.
/// docs/dev/guest.md has the size against std.json.
const Json = struct {
    s: []const u8,
    i: usize = 0,
    heap: usize = 0,

    fn ws(p: *Json) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    fn eat(p: *Json, ch: u8) bool {
        p.ws();
        if (p.i < p.s.len and p.s[p.i] == ch) {
            p.i += 1;
            return true;
        }
        return false;
    }

    /// Reads an object of the part `scope` of the hook.
    fn object(p: *Json, vals: []?[]const u8, scope: Scope) bool {
        if (!p.eat('{')) return false;
        if (p.eat('}')) return true;
        while (true) {
            p.ws();
            const key = p.string() orelse return false;
            if (!p.eat(':')) return false;
            p.ws();
            const is_string = p.i < p.s.len and p.s[p.i] == '"';
            const want = for (hook_fields, 0..) |f, k| {
                if (f.scope == scope and std.mem.eql(u8, f.from, key)) break k;
            } else null;
            if (want != null and is_string) {
                vals[want.?] = p.string() orelse return false;
            } else if (scope == .top and p.i < p.s.len and p.s[p.i] == '{' and
                (std.mem.eql(u8, key, "tool_input") or std.mem.eql(u8, key, "tool_response")))
            {
                if (!p.object(vals, if (key[5] == 'i') .input else .response)) return false;
            } else if (!p.skip()) return false;
            if (p.eat('}')) return true;
            if (!p.eat(',')) return false;
        }
    }

    /// Skips one value.
    fn skip(p: *Json) bool {
        p.ws();
        if (p.i >= p.s.len) return false;
        switch (p.s[p.i]) {
            '"' => return p.string() != null,
            '{', '[' => {
                var depth: usize = 0;
                while (p.i < p.s.len) {
                    switch (p.s[p.i]) {
                        '"' => {
                            _ = p.string() orelse return false;
                            continue;
                        },
                        '{', '[' => depth += 1,
                        '}', ']' => {
                            depth -= 1;
                            if (depth == 0) {
                                p.i += 1;
                                return true;
                            }
                        },
                        else => {},
                    }
                    p.i += 1;
                }
                return false;
            },
            else => {
                while (p.i < p.s.len and std.mem.indexOfScalar(u8, ",}] \t\r\n", p.s[p.i]) == null) p.i += 1;
                return true;
            },
        }
    }

    /// Decodes the string at `i` into `hook_heap`.
    fn string(p: *Json) ?[]const u8 {
        if (p.i >= p.s.len or p.s[p.i] != '"') return null;
        p.i += 1;
        const start = p.heap;
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            p.i += 1;
            if (ch == '"') return hook_heap[start..p.heap];
            if (p.heap + 4 > hook_heap.len) return null;
            if (ch != '\\') {
                hook_heap[p.heap] = ch;
                p.heap += 1;
                continue;
            }
            if (p.i >= p.s.len) return null;
            const e = p.s[p.i];
            p.i += 1;
            const out: u8 = switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                'u' => {
                    var cp: u21 = p.hex4() orelse return null;
                    if (cp >= 0xd800 and cp < 0xdc00 and p.i + 1 < p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                        p.i += 2;
                        const lo = p.hex4() orelse return null;
                        cp = if (lo >= 0xdc00 and lo < 0xe000) 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00) else 0xfffd;
                    }
                    if (cp >= 0xd800 and cp < 0xe000) cp = 0xfffd;
                    p.heap += std.unicode.utf8Encode(cp, hook_heap[p.heap..][0..4]) catch return null;
                    continue;
                },
                else => e,
            };
            hook_heap[p.heap] = out;
            p.heap += 1;
        }
        return null;
    }

    fn hex4(p: *Json) ?u21 {
        if (p.i + 4 > p.s.len) return null;
        const v = std.fmt.parseInt(u16, p.s[p.i..][0..4], 16) catch return null;
        p.i += 4;
        return v;
    }
};

fn putField(at: usize, key: []const u8, val: []const u8) ?usize {
    var w = at;
    if (w + key.len + 4 > hook_line.len) return null;
    hook_line[w] = ',';
    hook_line[w + 1] = '"';
    @memcpy(hook_line[w + 2 ..][0..key.len], key);
    w += 2 + key.len;
    @memcpy(hook_line[w..][0..2], "\":");
    w += 2;
    return jsonString(&hook_line, w, val);
}

/// The first `max` bytes of `s`, cut at the start of a UTF-8 sequence.
fn trimUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return s[0..n];
}

/// Sends the line of each file in `hook_dir` on the events stream, then
/// removes the file. False when the host closed the stream.
fn sendHooks(c: i32) bool {
    const d: i32 = @intCast(ok(linux.open(hook_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)) orelse return true);
    defer _ = linux.close(d);
    var ents: [4096]u8 align(8) = undefined;
    while (true) {
        const n = ok(linux.getdents64(d, &ents, ents.len)) orelse return true;
        if (n == 0) return true;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&ents[off]);
            off += ent.reclen;
            const name: [*:0]const u8 = @ptrCast(&ent.name);
            if (name[0] == '.') continue;
            const fd: i32 = @intCast(ok(linux.openat(d, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)) orelse continue);
            const r = ok(linux.read(fd, &hook_line, hook_line.len)) orelse 0;
            _ = linux.close(fd);
            _ = linux.unlinkat(d, name, 0);
            if (r > 0 and !writeAll(c, hook_line[0..r])) return false;
        }
    }
}
