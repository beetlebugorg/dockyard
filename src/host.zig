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
//!
//! On Windows the socket of the preview is in the temp folder of the
//! user, the `PATH` has `;` between its folders, a program is a file
//! with `.exe` or `.cmd`, and the clock has no zone files.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const control = @import("control.zig");

const on_win = builtin.os.tag == .windows;
const delimiter: u8 = if (on_win) ';' else ':';

/// True when `p` is a full path: `/x`, or on Windows `C:\x`, `C:/x`,
/// or `\\server\share`.
fn isFull(p: []const u8) bool {
    if (comptime !on_win) return p.len > 0 and p[0] == '/';
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return std.mem.startsWith(u8, p, "\\\\");
}

extern "kernel32" fn GetTempPathA(len: u32, buf: [*]u8) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesA(name: [*:0]const u8) callconv(.winapi) u32;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(ft: *u64) callconv(.winapi) void;

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
    /// True when the window uses the dark color scheme. The preview
    /// child uses the same scheme.
    dark: bool = false,
};

/// The path of the control socket of the preview of `project`, from
/// the folder `runtime` (`XDG_RUNTIME_DIR`). With no folder, the path
/// is in `/tmp` with the user ID in its name, and on Windows in the temp
/// folder of the user.
pub fn controlPath(a: std.mem.Allocator, runtime: ?[]const u8, project: []const u8) ![:0]const u8 {
    const hash = std.hash.Wyhash.hash(0, project);
    if (runtime) |r| if (r.len > 0) return std.fmt.allocPrintSentinel(a, "{s}/dockyard-{x:0>16}.sock", .{ r, hash }, 0);
    if (comptime on_win) {
        var buf: [260]u8 = undefined;
        const n = GetTempPathA(buf.len, &buf);
        if (n == 0 or n >= buf.len) return error.NoTempFolder;
        // The folder ends with `\`.
        return std.fmt.allocPrintSentinel(a, "{s}dockyard-{x:0>16}.sock", .{ buf[0..n], hash }, 0);
    }
    return std.fmt.allocPrintSentinel(a, "/tmp/dockyard-{d}-{x:0>16}.sock", .{ std.c.getuid(), hash }, 0);
}

/// The `PATH` with only its full paths, in memory of `a`.
pub fn cleanPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, delimiter);
    while (it.next()) |p| {
        if (!isFull(p)) continue;
        if (out.items.len > 0) try out.append(a, delimiter);
        try out.appendSlice(a, p);
    }
    return out.items;
}

/// The first executable file `name` in the folders of `path`. On
/// Windows it is `name` with `.exe`, then with `.cmd`.
pub fn findProgram(a: std.mem.Allocator, path: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, path, delimiter);
    while (it.next()) |dir| {
        if (!isFull(dir)) continue;
        if (comptime on_win) {
            for ([_][]const u8{ ".exe", ".cmd" }) |ext| {
                const full = try std.fmt.allocPrintSentinel(a, "{s}\\{s}{s}", .{ std.mem.trimEnd(u8, dir, "\\/"), name, ext }, 0);
                const attrs = GetFileAttributesA(full.ptr);
                // A file: not INVALID_FILE_ATTRIBUTES and not a folder.
                if (attrs != std.math.maxInt(u32) and attrs & 0x10 == 0) return full;
            }
            continue;
        }
        const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        if (std.c.access(full.ptr, 1) == 0) return full;
    }
    return null;
}

/// Turns on the capabilities and gives `exec` the environment. `env`
/// has `NAME=value` strings that live as long as the interpreter.
pub fn allow(it: *ztcl.Interp, project: []const u8, env: []const [:0]const u8) !void {
    const cap = ztcl.interp.Capability;
    try it.allow(@backingInt(cap.exec) | @backingInt(cap.channels) | @backingInt(cap.file));
    try ztcl.fsroot.setRoot(it, project);
    it.clock_host = clock_host;
    it.exec_host = .{ .allow = null, .timeout_ms = 0, .env = env };
    try it.register("::dockyard::findProgram", cmdFindProgram);
    // The preview child gets the same environment, so the same socket path.
    var runtime: ?[]const u8 = null;
    for (env) |e| if (std.mem.startsWith(u8, e, "XDG_RUNTIME_DIR=")) {
        runtime = e["XDG_RUNTIME_DIR=".len..];
    };
    var fba = std.heap.FixedBufferAllocator.init(&preview_path_buf);
    preview_path = try controlPath(fba.allocator(), runtime, project);
    try it.register("dockyard::preview::call", cmdPreviewCall);
}

/// Turns on the capabilities of the preview child: `file`, `channels`,
/// and `clock`, below the folder of the project.
pub fn allowPreview(it: *ztcl.Interp, project: []const u8) !void {
    const cap = ztcl.interp.Capability;
    try it.allow(@backingInt(cap.file) | @backingInt(cap.channels) | @backingInt(cap.clock));
    try ztcl.fsroot.setRoot(it, project);
    it.clock_host = clock_host;
}

/// The host clock of `clock` and `time`: the real time of the system,
/// and the zone files of `/usr/share/zoneinfo`.
const ClockHost = @typeInfo(@FieldType(ztcl.Interp, "clock_host")).optional.child;
pub const clock_host: ClockHost = .{ .now = clockNow, .zone = clockZone };

fn clockNow(_: ?*anyopaque) i64 {
    if (comptime on_win) {
        // 100 ns units since 1601-01-01, to microseconds since 1970.
        var ft: u64 = 0;
        GetSystemTimePreciseAsFileTime(&ft);
        return @divFloor(@as(i64, @intCast(ft)) - 116_444_736_000_000_000, 10);
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
}

/// The zone file `name`. Windows has no zone files, so a zone by name
/// is an error there.
fn clockZone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    if (comptime on_win) return null;
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

var preview_path_buf: [512]u8 = undefined;
var preview_path: [:0]const u8 = "";

/// `::dockyard::preview::call script ?timeout_ms?`: runs the script in
/// the preview child over its control socket and gives the result. The
/// default timeout is 250 ms, so a child in a long loop stops the
/// window for at most that time.
fn cmdPreviewCall(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("::dockyard::preview::call script ?timeout_ms?");
    const timeout: u32 = if (argv.len == 3) @intCast(std.math.clamp(try it.int(argv[2]), 1, 60_000)) else 250;
    const a = it.alloc();
    const reply = control.call(a, preview_path, try it.str(argv[1]), timeout) catch |e| return it.fail("no preview: {s}", .{@errorName(e)});
    if (!reply.ok) return it.fail("{s}", .{reply.@"error"});
    return .{ .str = reply.result };
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

/// The shell of the terminal pane: `SHELL`, or `/bin/sh`. On Windows
/// `COMSPEC`, or the cmd.exe of the system folder.
pub fn shellOf(map: *const std.process.Environ.Map) []const u8 {
    if (comptime on_win) return map.get("COMSPEC") orelse "C:\\Windows\\System32\\cmd.exe";
    return map.get("SHELL") orelse "/bin/sh";
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
    try it.setVar("::dockyard::dark", .{ .str = if (s.dark) "1" else "0" });
    try it.setVar("::dockyard::windows", .{ .str = if (on_win) "1" else "0" });
    try it.setVar("::dockyard::claude_md", .{ .str = claude_md });
}

test "the control path depends on the project folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try controlPath(a, "/run/user/7", "/home/u/app");
    try std.testing.expect(std.mem.startsWith(u8, one, "/run/user/7/dockyard-"));
    try std.testing.expect(!std.mem.eql(u8, one, try controlPath(a, "/run/user/7", "/home/u/other")));
    const plain = try controlPath(a, null, "/x");
    if (comptime on_win) {
        try std.testing.expect(isFull(plain) and std.mem.indexOf(u8, plain, "\\dockyard-") != null);
    } else try std.testing.expect(std.mem.startsWith(u8, plain, "/tmp/dockyard-"));
}

test "the PATH of Windows keeps only full paths" {
    if (comptime !on_win) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("C:\\Windows;D:/tools;\\\\srv\\bin", try cleanPath(a, ".;C:\\Windows;;rel;D:/tools;\\\\srv\\bin;"));
    const cmd = (try findProgram(a, "C:\\nonexistent;C:\\Windows\\System32", "cmd")).?;
    try std.testing.expect(std.ascii.endsWithIgnoreCase(cmd, "\\System32\\cmd.exe"));
    try std.testing.expect(try findProgram(a, "C:\\Windows", "no-such-program-here") == null);
}

test "the PATH keeps only full paths" {
    if (comptime on_win) return error.SkipZigTest;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", try cleanPath(arena.allocator(), ".:/usr/bin::bin:/bin:"));
    try std.testing.expectEqualStrings("/bin/sh", (try findProgram(arena.allocator(), "/nonexistent:/bin", "sh")).?);
    try std.testing.expect(try findProgram(arena.allocator(), "/bin", "no-such-program-here") == null);
}
