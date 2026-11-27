//! The Build button and the app list. The Tcl commands of this file run
//! in the window interpreter, whose `file` root is the project folder,
//! so they get the full paths of the host here.
//!
//! The Build button copies the ztk program of a target with the app in
//! its slot (`ztk bundle`, `ztk.bundle.run`). The ztk program of each
//! target is in `lib/ztk/runtime/TARGET/` next to the folder of the
//! dockyard program (`zig build -Druntimes=...`). The app is `main.tcl`
//! and the other files of the project, without the hidden files,
//! `build/`, `CLAUDE.md`, and `LICENSE`. The output is
//! `build/TARGET/NAME` in the project, with `.exe` on Windows. The app
//! gets the capabilities of the preview: `file`, `channels`, and
//! `clock`.
//!
//! The app list is each folder next to the project folder (the folder
//! of the apps, `~/dockyard/` in the user guide) that has a `main.tcl`.
//! Each app has the files of its `build/` folder.

const std = @import("std");
const Io = std.Io;
const ztcl = @import("ztcl");
const ztk = @import("ztk");

/// The targets of `ztk bundle`, in the order of the window.
pub const targets = [_][]const u8{ "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows" };

/// The capabilities of a built app.
const app_caps = "file,channels,clock";

/// The files of a project that the app does not get.
const skipped = [_][]const u8{ "build", "CLAUDE.md", "LICENSE" };

var the_io: Io = undefined;
var project_buf: [std.fs.max_path_bytes]u8 = undefined;
var project: []const u8 = "";

/// Registers the commands. `folder` is the full path of the project.
pub fn register(it: *ztcl.Interp, io: Io, folder: []const u8) !void {
    the_io = io;
    @memcpy(project_buf[0..folder.len], folder);
    project = project_buf[0..folder.len];
    try it.register("dockyard::build::targets", cmdTargets);
    try it.register("dockyard::build::run", cmdBuild);
    try it.register("dockyard::apps::scan", cmdList);
    try it.register("dockyard::apps::spawn", cmdSpawn);
    try it.register("dockyard::build::host", cmdHost);
}

/// The file name of the program of a target: `name`, or `name.exe`.
fn programName(a: std.mem.Allocator, target: []const u8, name: []const u8) ![]const u8 {
    return if (std.mem.endsWith(u8, target, "windows")) std.fmt.allocPrint(a, "{s}.exe", .{name}) else name;
}

/// The folder of the ztk programs, for the tests. The default is
/// `lib/ztk/runtime` next to the folder of this program.
pub var runtime_root: ?[]const u8 = null;

/// The path of the ztk program of a target.
fn runtimePath(a: std.mem.Allocator, target: []const u8) ![]const u8 {
    const root = runtime_root orelse try std.fs.path.join(a, &.{ try std.process.executableDirPathAlloc(the_io, a), "..", "lib", "ztk", "runtime" });
    return std.fs.path.join(a, &.{ root, target, try programName(a, target, "ztk") });
}

fn exists(path: []const u8) bool {
    Io.Dir.cwd().access(the_io, path, .{}) catch return false;
    return true;
}

/// `dockyard::build::host`: the target of this computer, for example
/// `x86_64-linux`.
fn cmdHost(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("dockyard::build::host");
    return .{ .str = ztcl.buildnative.hostTarget() };
}

/// `dockyard::build::targets`: a list of target names and flags. The
/// flag is 1 when the ztk program of the target is there.
fn cmdTargets(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("dockyard::build::targets");
    const a = it.alloc();
    var out: std.ArrayList(ztcl.Value) = .empty;
    for (targets) |t| {
        const ok = exists(runtimePath(a, t) catch return error.OutOfMemory);
        try out.appendSlice(a, &.{ .{ .str = t }, .{ .int = @intFromBool(ok) } });
    }
    return ztcl.value.newList(a, out.items);
}

/// The paths of the files of the app: `main.tcl` first, then the other
/// files and folders of the project.
fn appFiles(a: std.mem.Allocator, folder: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, try std.fs.path.join(a, &.{ folder, "main.tcl" }));
    var dir = try Io.Dir.cwd().openDir(the_io, folder, .{ .iterate = true });
    defer dir.close(the_io);
    var iter = dir.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try iter.next(the_io)) |e| {
        if (e.name.len == 0 or e.name[0] == '.' or std.mem.eql(u8, e.name, "main.tcl")) continue;
        if (for (skipped) |s| {
            if (std.mem.eql(u8, s, e.name)) break true;
        } else false) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |n| try out.append(a, try std.fs.path.join(a, &.{ folder, n }));
    return out.items;
}

/// `dockyard::build::run target`: builds the program of the project
/// for the target. Gives the path of the program in the project, for
/// example `/build/x86_64-linux/my-app`.
fn cmdBuild(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 2) return it.wrongArgs("dockyard::build::run target");
    const target = try it.str(argv[1]);
    const known = for (targets) |t| {
        if (std.mem.eql(u8, t, target)) break true;
    } else false;
    if (!known) return it.fail("unknown target \"{s}\"", .{target});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = build(a, target) catch |e| return it.fail("build of {s}: {s}", .{ target, @errorName(e) });
    if (r.status != 0) return it.fail("{s}", .{std.mem.trimEnd(u8, r.log, "\n")});
    return .{ .str = try it.alloc().dupe(u8, r.path) };
}

const BuildResult = struct { status: u8, log: []const u8, path: []const u8 };

fn build(a: std.mem.Allocator, target: []const u8) !BuildResult {
    const name = std.fs.path.basename(project);
    const file = try programName(a, target, name);
    const out_dir = try std.fs.path.join(a, &.{ project, "build", target });
    try Io.Dir.cwd().createDirPath(the_io, out_dir);
    const out_path = try std.fs.path.join(a, &.{ out_dir, file });
    var args: std.ArrayList([:0]const u8) = .empty;
    for ([_][]const u8{ "-o", out_path, "--target", target, "--runner", try runtimePath(a, target), "--allow", app_caps, "--name", name }) |s|
        try args.append(a, try a.dupeSentinel(u8, s, 0));
    // icon.png of the project is the icon of the program: an .icns file
    // in a macOS app, the icon resource of a Windows program.
    const icon = try std.fs.path.joinZ(a, &.{ project, "icon.png" });
    if (std.c.access(icon.ptr, 4) == 0) {
        try args.append(a, "--icon");
        try args.append(a, icon);
    }
    for (try appFiles(a, project)) |f| try args.append(a, try a.dupeSentinel(u8, f, 0));
    var log: Io.Writer.Allocating = .init(a);
    const status = try ztk.bundle.run(the_io, a, args.items, &log.writer);
    return .{ .status = status, .log = log.written(), .path = try std.fmt.allocPrint(a, "/build/{s}/{s}", .{ target, file }) };
}

/// `dockyard::apps::scan`: one item for each app next to the project:
/// `{name path builds}`. `builds` has `{target file size}` items, with
/// the full path of each file.
fn cmdList(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("dockyard::apps::scan");
    const a = it.alloc();
    const root = std.fs.path.dirname(project) orelse return ztcl.value.newList(a, &.{});
    return listApps(a, root) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => it.fail("app list of {s}: {s}", .{ root, @errorName(e) }),
    };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn listApps(a: std.mem.Allocator, root: []const u8) !ztcl.Value {
    var dir = try Io.Dir.cwd().openDir(the_io, root, .{ .iterate = true });
    defer dir.close(the_io);
    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(the_io)) |e| {
        if (e.kind != .directory or e.name[0] == '.') continue;
        const main = try std.fs.path.join(a, &.{ root, e.name, "main.tcl" });
        if (!exists(main)) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var apps: std.ArrayList(ztcl.Value) = .empty;
    for (names.items) |n| {
        const path = try std.fs.path.join(a, &.{ root, n });
        var builds: std.ArrayList(ztcl.Value) = .empty;
        for (targets) |t| {
            const file = try std.fs.path.join(a, &.{ path, "build", t, try programName(a, t, n) });
            const st = Io.Dir.cwd().statFile(the_io, file, .{}) catch continue;
            try builds.append(a, try ztcl.value.newList(a, &.{ .{ .str = t }, .{ .str = file }, .{ .int = @intCast(st.size) } }));
        }
        try apps.append(a, try ztcl.value.newList(a, &.{ .{ .str = n }, .{ .str = path }, try ztcl.value.newList(a, builds.items) }));
    }
    return ztcl.value.newList(a, apps.items);
}

/// `dockyard::apps::spawn file ?arg ...?`: starts a program, with its
/// folder as the current folder. The program runs on after dockyard
/// ends.
fn cmdSpawn(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len < 2) return it.wrongArgs("dockyard::apps::spawn file ?arg ...?");
    const a = it.alloc();
    var words: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |v| try words.append(a, try it.str(v));
    const file = words.items[0];
    if (!std.fs.path.isAbsolute(file)) return it.fail("not a full path: {s}", .{file});
    _ = std.process.spawn(the_io, .{
        .argv = words.items,
        .cwd = .{ .path = std.fs.path.dirname(file) orelse "/" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| return it.fail("cannot start {s}: {s}", .{ file, @errorName(e) });
    return .empty;
}

test "the app files start with main.tcl and leave out the build files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    the_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "main.tcl", "lib.tcl", "CLAUDE.md", "LICENSE", ".mcp.json" }) |n|
        try tmp.dir.writeFile(the_io, .{ .sub_path = n, .data = "" });
    try tmp.dir.createDirPath(the_io, "build/x86_64-linux");
    try tmp.dir.createDirPath(the_io, "images");
    const folder = try tmp.dir.realPathFileAlloc(the_io, ".", a);
    const files = try appFiles(a, folder);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("main.tcl", std.fs.path.basename(files[0]));
    try std.testing.expectEqualStrings("images", std.fs.path.basename(files[1]));
    try std.testing.expectEqualStrings("lib.tcl", std.fs.path.basename(files[2]));
}
