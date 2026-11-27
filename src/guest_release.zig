//! A signed release of the sandbox guest for `dockyard --sandbox DIR`,
//! when DIR has a `manifest.json` (the output of `os/tools/manifest.sh`).
//! `ztcl::vm image install` reads a folder below the root folder of
//! `file`, so dockyard copies the manifest, its signature, and the files
//! of this architecture to `.dockyard/guest/` of the project. It skips the
//! copy when the manifest there is the same. `sandbox.tcl` installs the
//! release in the store and boots it with `create -image`.
//!
//! The test key of dockyard (`os/tools/testkey`) signs the release of CI.
//! Its private half is in the repository, so only a Debug build trusts
//! it, and only for a name that ends in `-test`.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const sandbox = @import("sandbox.zig");

/// The keys of guest releases that this build trusts.
pub const keys: []const ztcl.vmimage.Key = if (builtin.mode == .debug) &.{test_key} else &.{};

/// The public half of `os/tools/testkey/test_ed25519.pub`.
pub const test_key: ztcl.vmimage.Key = .{
    .name = "dockyard-test",
    .test_only = true,
    .key = ztcl.vmimage.sshKey("AAAAC3NzaC1lZDI1NTE5AAAAINH7vAkatg3vINjwK4B6wUQNey7R/aDaiB2SKtaKqdWQ"),
};

/// The architecture names of the manifest.
const manifest_arch = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    else => "x86_64",
};

pub const Release = struct { name: []const u8, counter: u64 };

/// True when `dir` has a release.
pub fn isRelease(a: std.mem.Allocator, dir: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return false;
    const p = std.fs.path.joinZ(a, &.{ dir, "manifest.json" }) catch return false;
    return std.c.access(p.ptr, 4) == 0;
}

/// Copies the release in `dir` to `project/.dockyard/guest`.
pub fn prepare(a: std.mem.Allocator, project: []const u8, dir: []const u8) !Release {
    if (comptime builtin.os.tag == .windows) return error.Unsupported;
    const out = try std.fmt.allocPrint(a, "{s}/.dockyard/guest", .{project});
    try sandbox.mkdirs(a, out);
    try sandbox.writeFile(a, try std.fmt.allocPrint(a, "{s}/.dockyard/.gitignore", .{project}), "*\n");
    const src_manifest = try std.fs.path.join(a, &.{ dir, "manifest.json" });
    const text = try readAll(a, src_manifest);
    const M = struct {
        name: []const u8,
        counter: u64,
        archs: std.json.ArrayHashMap(struct {
            kernel: struct { file: []const u8 },
            initrd: ?struct { file: []const u8 } = null,
            disks: []const struct { file: []const u8 },
        }),
    };
    const m = try std.json.parseFromSliceLeaky(M, a, text, .{ .ignore_unknown_fields = true });
    const entry = m.archs.map.get(manifest_arch) orelse return error.NoArch;
    const dst_manifest = try std.fs.path.join(a, &.{ out, "manifest.json" });
    const same = if (readAll(a, dst_manifest)) |old| std.mem.eql(u8, old, text) else |_| false;
    if (!same) {
        var files: std.ArrayList([]const u8) = .empty;
        try files.append(a, entry.kernel.file);
        if (entry.initrd) |x| try files.append(a, x.file);
        for (entry.disks) |d| try files.append(a, d.file);
        for (files.items) |f| {
            if (std.mem.indexOfScalar(u8, f, '/') != null) return error.BadManifest;
            try sandbox.place(a, try std.fs.path.join(a, &.{ dir, f }), out, f);
        }
        try sandbox.place(a, try std.fs.path.join(a, &.{ dir, "manifest.json.sig" }), out, "manifest.json.sig");
        // The manifest goes last, so a copy that stops halfway is not the same.
        try sandbox.place(a, src_manifest, out, "manifest.json");
    }
    return .{ .name = m.name, .counter = m.counter };
}

pub fn setVars(it: *ztcl.Interp, r: ?Release) !void {
    var buf: [24]u8 = undefined;
    try it.setVar("::dockyard::sandbox_image", .{ .str = if (r) |x| x.name else "" });
    try it.setVar("::dockyard::sandbox_counter", .{ .str = if (r) |x| try std.fmt.bufPrint(&buf, "{d}", .{x.counter}) else "" });
}

/// The folder of the store of signed guest images: ZTCL_VM_IMAGES, or the
/// folder that the `ztcl` runner uses, so the two share the releases.
pub fn store(a: std.mem.Allocator) []const u8 {
    const env = struct {
        fn get(k: [:0]const u8) ?[]const u8 {
            return if (std.c.getenv(k)) |v| std.mem.sliceTo(v, 0) else null;
        }
    }.get;
    if (comptime builtin.os.tag == .windows) return "";
    if (env("ZTCL_VM_IMAGES")) |p| return p;
    const home = env("HOME") orelse return "";
    if (comptime builtin.os.tag == .macos) return std.fmt.allocPrint(a, "{s}/Library/Application Support/ztcl/vm-images", .{home}) catch "";
    if (env("XDG_DATA_HOME")) |x| return std.fmt.allocPrint(a, "{s}/ztcl/vm-images", .{x}) catch "";
    return std.fmt.allocPrint(a, "{s}/.local/share/ztcl/vm-images", .{home}) catch "";
}

fn readAll(a: std.mem.Allocator, p: []const u8) ![]u8 {
    const fd = std.c.open((try a.dupeSentinel(u8, p, 0)).ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.InputOutput;
        if (n == 0) return out.items;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
}
