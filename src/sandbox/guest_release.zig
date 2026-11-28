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
pub fn isRelease(a: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    const p = std.fs.path.join(a, &.{ dir, "manifest.json" }) catch return false;
    return sandbox.readable(io, p);
}

/// Copies the release in `dir` to `project/.dockyard/guest`.
pub fn prepare(a: std.mem.Allocator, io: std.Io, project: []const u8, dir: []const u8) !Release {
    const out = try std.fs.path.join(a, &.{ project, ".dockyard", "guest" });
    try std.Io.Dir.cwd().createDirPath(io, out);
    try sandbox.writeFile(io, try std.fs.path.join(a, &.{ project, ".dockyard", ".gitignore" }), "*\n");
    const src_manifest = try std.fs.path.join(a, &.{ dir, "manifest.json" });
    const text = try readAll(a, io, src_manifest);
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
    const same = if (readAll(a, io, dst_manifest)) |old| std.mem.eql(u8, old, text) else |_| false;
    if (!same) {
        var files: std.ArrayList([]const u8) = .empty;
        try files.append(a, entry.kernel.file);
        if (entry.initrd) |x| try files.append(a, x.file);
        for (entry.disks) |d| try files.append(a, d.file);
        for (files.items) |f| {
            if (std.mem.indexOfScalar(u8, f, '/') != null) return error.BadManifest;
            try sandbox.place(a, io, try std.fs.path.join(a, &.{ dir, f }), out, f);
        }
        try sandbox.place(a, io, try std.fs.path.join(a, &.{ dir, "manifest.json.sig" }), out, "manifest.json.sig");
        // The manifest goes last, so a copy that stops halfway is not the same.
        try sandbox.place(a, io, src_manifest, out, "manifest.json");
    }
    return .{ .name = m.name, .counter = m.counter };
}

pub fn setVars(it: *ztcl.Interp, r: ?Release) !void {
    var buf: [24]u8 = undefined;
    // The namespace of the variables: ztcl fails a set in a namespace that does not exist, as Tcl does.
    _ = try it.eval("namespace eval ::dockyard {}");
    try it.setVar("::dockyard::sandbox_image", .{ .str = if (r) |x| x.name else "" });
    try it.setVar("::dockyard::sandbox_counter", .{ .str = if (r) |x| try std.fmt.bufPrint(&buf, "{d}", .{x.counter}) else "" });
}

/// The folder of the store of signed guest images: ZTCL_VM_IMAGES, or the
/// folder that the `ztcl` runner uses, so the two share the releases.
/// `env` is the environment of the program.
pub fn store(a: std.mem.Allocator, env: *const std.process.Environ.Map) []const u8 {
    if (env.get("ZTCL_VM_IMAGES")) |p| return p;
    if (comptime builtin.os.tag == .windows) {
        const local = env.get("LOCALAPPDATA") orelse return "";
        return std.fmt.allocPrint(a, "{s}\\ztcl\\vm-images", .{local}) catch "";
    }
    const home = env.get("HOME") orelse return "";
    if (comptime builtin.os.tag == .macos) return std.fmt.allocPrint(a, "{s}/Library/Application Support/ztcl/vm-images", .{home}) catch "";
    if (env.get("XDG_DATA_HOME")) |x| return std.fmt.allocPrint(a, "{s}/ztcl/vm-images", .{x}) catch "";
    return std.fmt.allocPrint(a, "{s}/.local/share/ztcl/vm-images", .{home}) catch "";
}

/// The bytes of a manifest, up to 1 MiB.
fn readAll(a: std.mem.Allocator, io: std.Io, p: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20));
}
