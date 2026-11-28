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
const Io = std.Io;

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
pub fn prepare(a: std.mem.Allocator, io: Io, project: []const u8, dir: []const u8, exe: []const u8) !Guest {
    const out = try std.fs.path.join(a, &.{ project, ".dockyard", "guest" });
    try Io.Dir.cwd().createDirPath(io, out);
    try writeFile(io, try std.fs.path.join(a, &.{ project, ".dockyard", ".gitignore" }), "*\n");
    const kernel = for (kernel_names) |k| {
        if (readable(io, try std.fs.path.join(a, &.{ dir, k }))) break k;
    } else return error.NoKernel;
    try place(a, io, try std.fs.path.join(a, &.{ dir, kernel }), out, kernel);
    try place(a, io, try std.fs.path.join(a, &.{ dir, "agent.cpio" }), out, "agent.cpio");
    const near = try std.fs.path.join(a, &.{ dir, "dockyard-guest" });
    const helper = if (readable(io, near)) near else blk: {
        const bin = std.fs.path.dirname(exe) orelse ".";
        break :blk try std.fs.path.join(a, &.{ bin, "..", "lib", "dockyard", "guest", arch, "dockyard-guest" });
    };
    try place(a, io, helper, out, "dockyard-guest");
    return .{ .kernel = kernel };
}

pub fn setVars(it: *ztcl.Interp, g: ?Guest, argv: []const u8, allow: []const u8) !void {
    // The namespace of the variables: ztcl fails a set in a namespace that does not exist, as Tcl does.
    _ = try it.eval("namespace eval ::dockyard {}");
    try it.setVar("::dockyard::sandbox", .{ .str = if (g != null) jail_dir else "" });
    try it.setVar("::dockyard::sandbox_kernel", .{ .str = if (g) |x| x.kernel else "" });
    try it.setVar("::dockyard::sandbox_argv", .{ .str = argv });
    try it.setVar("::dockyard::sandbox_allow", .{ .str = allow });
}

/// True when the file at `p` can be read.
pub fn readable(io: Io, p: []const u8) bool {
    Io.Dir.cwd().access(io, p, .{ .read = true }) catch return false;
    return true;
}

pub fn writeFile(io: Io, p: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
}

/// A copy of `src` as `dir/name`, with the permissions of `src`. The copy
/// replaces an old file at once, so a guest never reads half of it.
pub fn place(a: std.mem.Allocator, io: Io, src: []const u8, dir: []const u8, name: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.copyFile(src, cwd, try std.fs.path.join(a, &.{ dir, name }), io, .{});
}

test "prepare puts copies of the guest files in the project" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const root = try std.fs.path.join(ar, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const dir = try std.fs.path.join(ar, &.{ root, "guest" });
    const project = try std.fs.path.join(ar, &.{ root, "project" });
    try tmp.dir.createDirPath(io, "guest");
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.writeFile(io, .{ .sub_path = "guest/bzImage", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "guest/agent.cpio", .data = "agent" });
    try tmp.dir.writeFile(io, .{ .sub_path = "guest/dockyard-guest", .data = "helper" });
    const g = try prepare(ar, io, project, dir, "dockyard");
    try std.testing.expectEqualStrings("bzImage", g.kernel);
    for ([_][2][]const u8{ .{ "bzImage", "kernel" }, .{ "agent.cpio", "agent" }, .{ "dockyard-guest", "helper" } }) |f| {
        const got = try tmp.dir.readFileAlloc(io, try std.fs.path.join(ar, &.{ "project", ".dockyard", "guest", f[0] }), ar, .limited(64));
        try std.testing.expectEqualStrings(f[1], got);
    }
    try std.testing.expectEqualStrings("*\n", try tmp.dir.readFileAlloc(io, "project/.dockyard/.gitignore", ar, .limited(64)));
    // A second start puts the new files in the place of the old ones.
    try tmp.dir.writeFile(io, .{ .sub_path = "guest/agent.cpio", .data = "agent 2" });
    _ = try prepare(ar, io, project, dir, "dockyard");
    try std.testing.expectEqualStrings("agent 2", try tmp.dir.readFileAlloc(io, "project/.dockyard/guest/agent.cpio", ar, .limited(64)));
    // A folder with no kernel.
    try tmp.dir.createDirPath(io, "empty");
    try std.testing.expectError(error.NoKernel, prepare(ar, io, project, try std.fs.path.join(ar, &.{ root, "empty" }), "dockyard"));
}
