//! The host side of dockyard: the capabilities of the interpreter, the
//! environment of the programs, and the search for the agent program.
//!
//! dockyard turns on `exec`, `channels`, and `file`. The root folder of
//! `file` is the project folder, so `/` in a script is the project. The
//! terminal pane runs a program with the full power of the user, and
//! `exec` is not a sandbox.
//!
//! The preview child (`dockyard --run FILE`) turns on `file`,
//! `channels` (for `source`), and `clock`, with the folder of FILE as
//! the root folder. It has no `exec` and no `socket`. Both interpreters
//! get the clock of the system for `clock` and `time`. The capabilities
//! that a project declares, and the limits of `ztk::limit`, come with
//! step 2 of the spec.
//!
//! The environment of a program is the environment of dockyard. The
//! `PATH` keeps only its full paths, because `ztcl::pty` refuses a
//! relative entry.

const std = @import("std");
const ztcl = @import("ztcl");

/// The CLAUDE.md that dockyard writes into a project that has none.
pub const claude_md = @embedFile("project/CLAUDE.md");

pub const Setup = struct {
    /// The folder of the project. The terminal starts in it.
    project: []const u8,
    /// The full path of the agent program, or null when the `PATH` has none.
    agent: ?[]const u8,
    /// The name that dockyard searched for.
    agent_name: []const u8 = "claude",
    /// The shell for a pane with no agent program.
    shell: []const u8,
    /// The clean `PATH`, for a new search after an install.
    path: []const u8 = "",
    /// The program that runs the preview child with `--run`.
    runner: []const u8 = "",
    /// True when the preview child also uses the headless backend.
    headless: bool = false,
};

/// The path of the control socket of the preview of `project`, from
/// the folder `runtime` (`XDG_RUNTIME_DIR`). With no folder, the path
/// is in `/tmp` with the user ID in its name.
pub fn controlPath(a: std.mem.Allocator, runtime: ?[]const u8, project: []const u8) ![:0]const u8 {
    const hash = std.hash.Wyhash.hash(0, project);
    if (runtime) |r| if (r.len > 0) return std.fmt.allocPrintSentinel(a, "{s}/dockyard-{x:0>16}.sock", .{ r, hash }, 0);
    return std.fmt.allocPrintSentinel(a, "/tmp/dockyard-{d}-{x:0>16}.sock", .{ std.c.getuid(), hash }, 0);
}

/// The `PATH` with only its full paths, in memory of `a`.
pub fn cleanPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |p| {
        if (p.len == 0 or p[0] != '/') continue;
        if (out.items.len > 0) try out.append(a, ':');
        try out.appendSlice(a, p);
    }
    return out.items;
}

/// The first executable file `name` in the folders of `path`.
pub fn findProgram(a: std.mem.Allocator, path: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir[0] != '/') continue;
        const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        if (std.c.access(full.ptr, 1) == 0) return full;
    }
    return null;
}

/// Turns on the capabilities and gives `exec` the environment. `env`
/// has `NAME=value` strings that live as long as the interpreter.
pub fn allow(it: *ztcl.Interp, project: []const u8, env: []const [:0]const u8) !void {
    const cap = ztcl.interp.Capability;
    try it.allow(@intFromEnum(cap.exec) | @intFromEnum(cap.channels) | @intFromEnum(cap.file));
    try ztcl.fsroot.setRoot(it, project);
    it.clock_host = clock_host;
    it.exec_host = .{ .allow = null, .timeout_ms = 0, .env = env };
    try it.register("::dockyard::findProgram", cmdFindProgram);
}

/// Turns on the capabilities of the preview child: `file`, `channels`,
/// and `clock`, below the folder of the project.
pub fn allowPreview(it: *ztcl.Interp, project: []const u8) !void {
    const cap = ztcl.interp.Capability;
    try it.allow(@intFromEnum(cap.file) | @intFromEnum(cap.channels) | @intFromEnum(cap.clock));
    try ztcl.fsroot.setRoot(it, project);
    it.clock_host = clock_host;
}

/// The host clock of `clock` and `time`: the real time of the system,
/// and the zone files of `/usr/share/zoneinfo`.
const ClockHost = @typeInfo(@FieldType(ztcl.Interp, "clock_host")).optional.child;
pub const clock_host: ClockHost = .{ .now = clockNow, .zone = clockZone };

fn clockNow(_: ?*anyopaque) i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
}

fn clockZone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const path = std.fmt.allocPrintSentinel(a, "/usr/share/zoneinfo/{s}", .{name}, 0) catch return null;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (out.items.len < 1 << 20) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return null;
        if (n == 0) break;
        out.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return out.items;
}

/// `::dockyard::findProgram name path`: the full path of the program,
/// or an empty string. The root folder of `file` hides the host folders,
/// so the search runs here.
fn cmdFindProgram(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 3) return it.wrongArgs("::dockyard::findProgram name path");
    const found = try findProgram(it.alloc(), try it.str(argv[2]), try it.str(argv[1]));
    return .{ .str = found orelse "" };
}

/// The environment of dockyard as `NAME=value` strings, with a clean `PATH`.
pub fn environment(a: std.mem.Allocator, map: *const std.process.Environ.Map) ![]const [:0]const u8 {
    var out: std.ArrayList([:0]const u8) = .empty;
    var iter = map.iterator();
    while (iter.next()) |e| {
        const k = e.key_ptr.*;
        var v = e.value_ptr.*;
        if (std.mem.eql(u8, k, "PATH")) v = try cleanPath(a, v);
        try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, v }, 0));
    }
    return out.items;
}

/// Sets the variables of `dockyard.tcl`.
pub fn setVars(it: *ztcl.Interp, s: Setup) !void {
    try it.setVar("::dockyard::project", .{ .str = s.project });
    try it.setVar("::dockyard::agent", .{ .str = s.agent orelse "" });
    try it.setVar("::dockyard::agent_name", .{ .str = s.agent_name });
    try it.setVar("::dockyard::shell", .{ .str = s.shell });
    try it.setVar("::dockyard::path", .{ .str = s.path });
    try it.setVar("::dockyard::runner", .{ .str = s.runner });
    try it.setVar("::dockyard::headless", .{ .str = if (s.headless) "1" else "0" });
    try it.setVar("::dockyard::claude_md", .{ .str = claude_md });
}

test "the control path depends on the project folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try controlPath(a, "/run/user/7", "/home/u/app");
    try std.testing.expect(std.mem.startsWith(u8, one, "/run/user/7/dockyard-"));
    try std.testing.expect(!std.mem.eql(u8, one, try controlPath(a, "/run/user/7", "/home/u/other")));
    try std.testing.expect(std.mem.startsWith(u8, try controlPath(a, null, "/x"), "/tmp/dockyard-"));
}

test "the PATH keeps only full paths" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", try cleanPath(arena.allocator(), ".:/usr/bin::bin:/bin:"));
    try std.testing.expectEqualStrings("/bin/sh", (try findProgram(arena.allocator(), "/nonexistent:/bin", "sh")).?);
    try std.testing.expect(try findProgram(arena.allocator(), "/bin", "no-such-program-here") == null);
}
