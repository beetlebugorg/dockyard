//! The host side of the sandbox (issue 13): `dockyard --sandbox DIR`.
//! DIR has the guest of ztcl::vm: the kernel (`bzImage` on x86-64,
//! `Image` on arm64) and the agent (`agent.cpio`). The helper of the
//! guest (`dockyard-guest`, src/guest/main.zig) comes from DIR, or from
//! `lib/dockyard/guest/ARCH/` next to the `bin` folder of dockyard.
//!
//! A path of ztcl::vm must be below the root folder of `file`, which is
//! the project folder. So dockyard puts a copy of each file in
//! `.dockyard/guest/` of the project, with a `.gitignore`, at each
//! start. It is a copy and not a hard link: the guest can write the
//! project folder, and a write to a link would change the file of DIR.
//! Signed images in the store of ztcl::vm (`create -image`) take the
//! place of this folder when each backend has them.
//!
//! `sandbox.tcl` has the Tcl side: the guest, the PTY sessions, the
//! relay of the proxy port, and the events.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");

pub const script = @embedFile("sandbox.tcl");

/// The folder of the guest files in the project, as a path of the file
/// jail, and the files in it.
pub const jail_dir = "/.dockyard/guest";
const kernel_names = [_][]const u8{ "bzImage", "Image" };

/// The hosts that the guest reaches by default: the API of the agent
/// program and the registry of npm.
pub const default_allow = "api.anthropic.com statsig.anthropic.com registry.npmjs.org";

pub const Guest = struct { kernel: []const u8 };

/// The arch folder of the helper for this machine.
pub const arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    else => "x86_64",
};

/// Puts the guest files in `project/.dockyard/guest`. `exe` is the path
/// of the dockyard program.
pub fn prepare(a: std.mem.Allocator, project: []const u8, dir: []const u8, exe: []const u8) !Guest {
    if (comptime builtin.os.tag == .windows) return error.Unsupported;
    const out = try std.fmt.allocPrint(a, "{s}/.dockyard/guest", .{project});
    try mkdirs(a, out);
    try writeFile(a, try std.fmt.allocPrint(a, "{s}/.dockyard/.gitignore", .{project}), "*\n");
    const kernel = for (kernel_names) |k| {
        if (exists(a, try std.fs.path.join(a, &.{ dir, k }))) break k;
    } else return error.NoKernel;
    try place(a, try std.fs.path.join(a, &.{ dir, kernel }), out, kernel);
    try place(a, try std.fs.path.join(a, &.{ dir, "agent.cpio" }), out, "agent.cpio");
    const near = try std.fs.path.join(a, &.{ dir, "dockyard-guest" });
    const helper = if (exists(a, near)) near else blk: {
        const bin = std.fs.path.dirname(exe) orelse ".";
        break :blk try std.fs.path.join(a, &.{ bin, "..", "lib", "dockyard", "guest", arch, "dockyard-guest" });
    };
    try place(a, helper, out, "dockyard-guest");
    return .{ .kernel = kernel };
}

pub fn setVars(it: *ztcl.Interp, g: ?Guest, argv: []const u8, allow: []const u8) !void {
    try it.setVar("::dockyard::sandbox", .{ .str = if (g != null) jail_dir else "" });
    try it.setVar("::dockyard::sandbox_kernel", .{ .str = if (g) |x| x.kernel else "" });
    try it.setVar("::dockyard::sandbox_argv", .{ .str = argv });
    try it.setVar("::dockyard::sandbox_allow", .{ .str = allow });
}

fn z(a: std.mem.Allocator, p: []const u8) ![:0]const u8 {
    return a.dupeSentinel(u8, p, 0);
}

fn exists(a: std.mem.Allocator, p: []const u8) bool {
    const pz = z(a, p) catch return false;
    return std.c.access(pz.ptr, 4) == 0;
}

pub fn mkdirs(a: std.mem.Allocator, p: []const u8) !void {
    var k: usize = 1;
    while (k <= p.len) : (k += 1) {
        if (k == p.len or p[k] == '/') _ = std.c.mkdir((try z(a, p[0..k])).ptr, 0o755);
    }
}

pub fn writeFile(a: std.mem.Allocator, p: []const u8, data: []const u8) !void {
    const fd = std.c.open((try z(a, p)).ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.AccessDenied;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, data.ptr, data.len) != @as(isize, @intCast(data.len))) return error.InputOutput;
}

/// A copy of `src` as `dir/name`.
pub fn place(a: std.mem.Allocator, src: []const u8, dir: []const u8, name: []const u8) !void {
    const dst = try z(a, try std.fs.path.join(a, &.{ dir, name }));
    const s = try z(a, src);
    if (std.c.access(s.ptr, 4) != 0) return error.FileNotFound;
    _ = std.c.unlink(dst.ptr);
    const in = std.c.open(s.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (in < 0) return error.FileNotFound;
    defer _ = std.c.close(in);
    const out = std.c.open(dst.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o755));
    if (out < 0) return error.AccessDenied;
    defer _ = std.c.close(out);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(in, &buf, buf.len);
        if (n < 0) return error.InputOutput;
        if (n == 0) return;
        if (std.c.write(out, &buf, @intCast(n)) != n) return error.InputOutput;
    }
}
