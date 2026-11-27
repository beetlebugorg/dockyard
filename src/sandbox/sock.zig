//! A stream socket of the local machine (`AF_UNIX`) at a path, for the
//! control socket of the preview (`control.zig`).
//!
//! Linux and macOS use the C library. Windows 10 and later have
//! `AF_UNIX` in Winsock, with the same address form: the calls are the
//! same with `SOCKET` handles, `WSAPoll` for the check with no wait,
//! `recv` and `send` for the data, and `closesocket`. Winsock starts at
//! the first call. A Windows socket file has no mode: it is in the temp
//! folder of the user, which other users cannot open.
//!
//! On Linux and macOS, `connect` checks that the socket file belongs to
//! the user and is not a link, so a socket that another user made at the
//! path gets no request. `privateDir` makes and checks a folder of mode
//! 0700 for the sockets.

const std = @import("std");
const builtin = @import("builtin");

const on_win = builtin.os.tag == .windows;

/// A socket: a descriptor, or a `SOCKET` handle on Windows.
pub const Fd = if (on_win) usize else c_int;

/// The longest path of a socket, with its zero byte.
pub const path_max = 108;

const Addr = extern struct { family: u16 = 1, path: [path_max]u8 };

fn addrOf(path: []const u8) !Addr {
    if (path.len >= path_max) return error.NameTooLong;
    var a: Addr = .{ .path = @splat(0) };
    @memcpy(a.path[0..path.len], path);
    return a;
}

/// A new stream socket of the local machine.
pub fn open() !Fd {
    if (comptime on_win) {
        try win.start();
        const s = win.socket(1, 1, 0);
        if (s == win.invalid) return error.SystemResources;
        return s;
    }
    // macOS has no SOCK_CLOEXEC: socket() with it fails with
    // EPROTONOSUPPORT, so the flag goes on with fcntl after the call.
    const is_mac = comptime @import("builtin").os.tag == .macos;
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | (if (is_mac) 0 else std.c.SOCK.CLOEXEC), 0);
    if (fd < 0) return error.SystemResources;
    if (is_mac) _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    return fd;
}

/// Binds `fd` to `path` and listens. A socket file of an earlier run is
/// removed first, since it blocks the bind.
pub fn bindListen(fd: Fd, path: [:0]const u8) !void {
    const addr = try addrOf(path);
    if (comptime on_win) {
        _ = win.DeleteFileA(path.ptr);
        if (win.bind(fd, &addr, @sizeOf(Addr)) != 0) return error.AddressInUse;
        if (win.listen(fd, 8) != 0) return error.SystemResources;
        return;
    }
    _ = std.c.unlink(path.ptr);
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(Addr)) != 0) return error.AddressInUse;
    _ = std.c.chmod(path.ptr, 0o600);
    if (std.c.listen(fd, 8) != 0) return error.SystemResources;
}

pub fn connect(fd: Fd, path: [:0]const u8) !void {
    const addr = try addrOf(path);
    if (comptime !on_win) {
        const st = statNoFollow(path) orelse return error.ConnectionRefused;
        if (st.mode & s_ifmt != s_ifsock or st.uid != uid()) return error.NotOwner;
    }
    const rc = if (comptime on_win) win.connect(fd, &addr, @sizeOf(Addr)) else std.c.connect(fd, @ptrCast(&addr), @sizeOf(Addr));
    if (rc != 0) return error.ConnectionRefused;
}

/// True when a connection or data waits on `fd`, with no wait.
pub fn readable(fd: Fd) bool {
    if (comptime on_win) {
        var p = [_]win.PollFd{.{ .fd = fd, .events = win.pollin, .revents = 0 }};
        return win.WSAPoll(&p, 1, 0) > 0 and p[0].revents & win.pollin != 0;
    }
    var p = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&p, 1, 0) > 0 and p[0].revents & std.c.POLL.IN != 0;
}

/// The next connection of a listening socket, or null.
pub fn accept(fd: Fd) ?Fd {
    if (comptime on_win) {
        const s = win.accept(fd, null, null);
        return if (s == win.invalid) null else s;
    }
    const c = std.c.accept(fd, null, null);
    return if (c < 0) null else c;
}

/// The bytes read into `buf`: 0 at the end, and less than 0 on an error
/// or a timeout.
pub fn read(fd: Fd, buf: []u8) isize {
    if (comptime on_win) return win.recv(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(i32))), 0);
    return std.c.read(fd, buf.ptr, buf.len);
}

/// The bytes written from `bytes`, or less than 1 on an error.
pub fn write(fd: Fd, bytes: []const u8) isize {
    if (comptime on_win) return win.send(fd, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(i32))), 0);
    return std.c.write(fd, bytes.ptr, bytes.len);
}

pub fn close(fd: Fd) void {
    if (comptime on_win) {
        _ = win.closesocket(fd);
    } else _ = std.c.close(fd);
}

pub const Dir = enum { recv, send };

/// The longest wait of a read or a write of `fd`.
pub fn setTimeout(fd: Fd, dir: Dir, ms: u32) void {
    if (comptime on_win) {
        const v: u32 = ms;
        _ = win.setsockopt(fd, win.sol_socket, if (dir == .recv) win.so_rcvtimeo else win.so_sndtimeo, std.mem.asBytes(&v), @sizeOf(u32));
        return;
    }
    const tv: std.c.timeval = .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, if (dir == .recv) std.c.SO.RCVTIMEO else std.c.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(std.c.timeval));
}

/// Removes the socket file at `path`.
pub fn unlink(path: [:0]const u8) void {
    if (comptime on_win) {
        _ = win.DeleteFileA(path.ptr);
    } else _ = std.c.unlink(path.ptr);
}

const win = struct {
    const invalid: usize = std.math.maxInt(usize);
    const sol_socket: i32 = 0xffff;
    const so_sndtimeo: i32 = 0x1005;
    const so_rcvtimeo: i32 = 0x1006;
    /// `POLLRDNORM | POLLRDBAND`.
    const pollin: i16 = 0x0300;
    const PollFd = extern struct { fd: usize, events: i16, revents: i16 };

    var started = std.atomic.Value(u8).init(0);

    fn start() !void {
        if (started.load(.acquire) == 1) return;
        var data: [512]u8 align(8) = undefined;
        if (WSAStartup(0x0202, &data) != 0) return error.SystemResources;
        started.store(1, .release);
    }

    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) usize;
    extern "ws2_32" fn bind(s: usize, addr: *const Addr, len: i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: usize, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(s: usize, addr: ?*anyopaque, len: ?*i32) callconv(.winapi) usize;
    extern "ws2_32" fn connect(s: usize, addr: *const Addr, len: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) i32;
    extern "ws2_32" fn setsockopt(s: usize, level: i32, opt: i32, value: [*]const u8, len: i32) callconv(.winapi) i32;
    extern "ws2_32" fn WSAPoll(fds: [*]PollFd, count: u32, timeout: i32) callconv(.winapi) i32;
    extern "kernel32" fn DeleteFileA(path: [*:0]const u8) callconv(.winapi) i32;
    extern "kernel32" fn GetTempPathA(len: u32, buf: [*]u8) callconv(.winapi) u32;
};

test "a socket at a path answers a connection" {
    var buf: [256]u8 = undefined;
    var tmp: [260]u8 = undefined;
    const dir = if (comptime on_win) tmp[0..win.GetTempPathA(tmp.len, &tmp)] else "/tmp/";
    if (dir.len == 0) return error.SkipZigTest;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}dockyard-sock-test.sock", .{dir}, 0);
    const server = try open();
    defer close(server);
    try bindListen(server, path);
    defer unlink(path);
    try std.testing.expect(!readable(server));
    const client = try open();
    defer close(client);
    try connect(client, path);
    try std.testing.expectEqual(@as(isize, 4), write(client, "ping"));
    // A connection of the local machine waits at once after `connect`.
    try std.testing.expect(readable(server));
    const conn = accept(server) orelse return error.NoConnection;
    defer close(conn);
    setTimeout(conn, .recv, 1000);
    var got: [8]u8 = undefined;
    const n = read(conn, &got);
    try std.testing.expectEqualStrings("ping", got[0..@intCast(n)]);
}

const s_ifmt: u32 = 0o170000;
const s_ifdir: u32 = 0o040000;
const s_ifsock: u32 = 0o140000;

pub const Owner = struct { uid: u32, mode: u32 };

/// The user ID of the process (0 on Windows, which has no user IDs here).
pub fn uid() u32 {
    if (comptime on_win) return 0;
    return @intCast(std.c.getuid());
}

/// The owner and the mode of `path`, without following a link at its
/// end, or null when it does not exist.
pub fn statNoFollow(path: [:0]const u8) ?Owner {
    if (comptime on_win) return null;
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &sx);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .uid = sx.uid, .mode = sx.mode };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return .{ .uid = @intCast(st.uid), .mode = @intCast(st.mode) };
}

/// Makes the folder `path` and each folder above it that does not exist
/// (mode 0700), then checks the last one: a folder, not a link, of the
/// user, with no rights for others. A folder of the user with more rights
/// gets mode 0700.
pub fn privateDir(path: [:0]const u8) !void {
    if (comptime on_win) return;
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len or path.len == 0 or path[0] != '/') return error.BadPath;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = std.c.mkdir(@ptrCast(&buf), 0o700);
    }
    const st = statNoFollow(path) orelse return error.NoFolder;
    if (st.mode & s_ifmt != s_ifdir or st.uid != uid()) return error.NotOwner;
    if (st.mode & 0o077 != 0) {
        if (std.c.chmod(path.ptr, 0o700) != 0) return error.NotOwner;
    }
}

test "a socket folder is private and a socket of another owner gets no connect" {
    if (comptime on_win) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const base = if (std.c.getenv("TMPDIR")) |t| std.mem.sliceTo(t, 0) else "/tmp";
    const dir = try std.fmt.bufPrintSentinel(&buf, "{s}/dockyard-test-sockdir-{d}/run", .{ base, std.c.getpid() }, 0);
    try privateDir(dir);
    try std.testing.expectEqual(@as(u32, 0o700), statNoFollow(dir).?.mode & 0o777);
    _ = std.c.chmod(dir.ptr, 0o755);
    try privateDir(dir);
    try std.testing.expectEqual(@as(u32, 0o700), statNoFollow(dir).?.mode & 0o777);
    // A link in the place of the folder is refused.
    var lbuf: [256]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&lbuf, "{s}/dockyard-test-sockdir-{d}/link", .{ base, std.c.getpid() }, 0);
    _ = std.c.symlink(dir.ptr, link.ptr);
    try std.testing.expectError(error.NotOwner, privateDir(link));
    // A plain file at the path of a socket gets no connect.
    var fbuf: [256]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&fbuf, "{s}/f.sock", .{dir}, 0);
    const fd = std.c.open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o600));
    _ = std.c.close(fd);
    const s = try open();
    defer close(s);
    try std.testing.expectError(error.NotOwner, connect(s, file));
    _ = std.c.unlink(file.ptr);
    _ = std.c.unlink(link.ptr);
    _ = std.c.rmdir(dir.ptr);
    var pbuf: [256]u8 = undefined;
    _ = std.c.rmdir((try std.fmt.bufPrintSentinel(&pbuf, "{s}/dockyard-test-sockdir-{d}", .{ base, std.c.getpid() }, 0)).ptr);
}
