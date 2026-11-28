//! Crash reports. A panic of Zig and a fatal signal (SIGSEGV, SIGBUS,
//! SIGILL, SIGFPE, SIGABRT) write a report file before the program ends:
//! the message, the version of dockyard, the system, and the stack with
//! the names of the functions. The folder is ~/Library/Logs/dockyard on
//! macOS, $XDG_STATE_HOME/dockyard/crashes (or ~/.local/state/...) on
//! Linux, and %LOCALAPPDATA%\dockyard\crashes on Windows. The folder keeps
//! the newest 20 reports. Nothing leaves the computer.
//!
//! At the next start, `install` finds the newest report that no start has
//! shown yet and gives its path to the window script, which shows "dockyard
//! crashed last time" with a button for `::dockyard::crash::open`. The
//! report is then marked shown with the suffix `.shown`.
//!
//! The handler of a signal writes with the allocator-free writer of a
//! static buffer and the stack walker of the standard library. That is not
//! async-signal-safe in each case; the program ends anyway, and the report
//! is best effort.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const Io = std.Io;

pub const version: []const u8 = @import("build_options").version;
const keep = 20;
const on_posix = builtin.os.tag != .windows;

var dir_buf: [1024]u8 = undefined;
var dir_len: usize = 0;
var the_io: ?Io = null;
var reporting = std.atomic.Value(bool).init(false);
var report_buf: [64 * 1024]u8 = undefined;

/// The folder of the reports, from the environment.
fn crashDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home = env.get("HOME") orelse return null;
            return std.fs.path.join(arena, &.{ home, "Library", "Logs", "dockyard" }) catch null;
        },
        .windows => {
            const base = env.get("LOCALAPPDATA") orelse return null;
            return std.fs.path.join(arena, &.{ base, "dockyard", "crashes" }) catch null;
        },
        else => {
            if (env.get("XDG_STATE_HOME")) |s| if (s.len > 0 and std.fs.path.isAbsolute(s))
                return std.fs.path.join(arena, &.{ s, "dockyard", "crashes" }) catch null;
            const home = env.get("HOME") orelse return null;
            return std.fs.path.join(arena, &.{ home, ".local", "state", "dockyard", "crashes" }) catch null;
        },
    }
}

/// Sets up the reports: the folder, the handlers of the fatal signals,
/// the pruning to the newest 20, and the report of the last crash for the
/// window script (`::dockyard::crash::last`, empty when there is none).
pub fn install(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, it: ?*ztcl.Interp) void {
    const dir = crashDir(arena, env) orelse return;
    if (dir.len > dir_buf.len) return;
    Io.Dir.cwd().createDirPath(io, dir) catch return;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_len = dir.len;
    the_io = io;
    if (on_posix) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.RESETHAND | std.posix.SA.ONSTACK,
        };
        for ([_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT }) |sig| std.posix.sigaction(sig, &act, null);
    }
    const last = prune(arena, io, dir);
    if (it) |interp| {
        _ = interp.eval("namespace eval ::dockyard::crash {}") catch {};
        interp.setVar("::dockyard::crash::last", .{ .str = last orelse "" }) catch {};
        interp.register("::dockyard::crash::open", cmdOpen) catch {};
    }
}

/// Keeps the newest `keep` reports, and gives the newest report that was
/// not shown, which it marks shown.
fn prune(arena: std.mem.Allocator, io: Io, dir: []const u8) ?[]const u8 {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iter = d.iterate();
    while (iter.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.startsWith(u8, e.name, "dockyard-")) continue;
        if (!std.mem.endsWith(u8, e.name, ".crash") and !std.mem.endsWith(u8, e.name, ".crash.shown")) continue;
        names.append(arena, arena.dupe(u8, e.name) catch continue) catch continue;
    }
    // The names start with the time in milliseconds at the same width, so
    // the order of the names is the order of the crashes.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    if (names.items.len > keep) {
        for (names.items[0 .. names.items.len - keep]) |n| d.deleteFile(io, n) catch {};
    }
    const newest = if (names.items.len > 0) names.items[names.items.len - 1] else return null;
    if (!std.mem.endsWith(u8, newest, ".crash")) return null;
    const shown = std.fmt.allocPrint(arena, "{s}.shown", .{newest}) catch return null;
    d.rename(newest, d, shown, io) catch return null;
    return std.fs.path.join(arena, &.{ dir, shown }) catch null;
}

/// `::dockyard::crash::open FILE`: the report in the program of the system
/// for text. Only a file of the folder of the reports opens.
fn cmdOpen(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 2) return it.wrongArgs("::dockyard::crash::open file");
    const file = try it.str(argv[1]);
    const dir = dir_buf[0..dir_len];
    if (dir_len == 0 or !std.mem.startsWith(u8, file, dir) or std.mem.indexOf(u8, file[dir.len..], "..") != null)
        return it.fail("not a crash report: {s}", .{file});
    const io = the_io orelse return it.fail("no crash folder", .{});
    const argv_open: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/usr/bin/open", "-t", file },
        .windows => &.{ "notepad.exe", file },
        else => &.{ "xdg-open", file },
    };
    var child = std.process.spawn(io, .{ .argv = argv_open, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |e|
        return it.fail("cannot open {s}: {s}", .{ file, @errorName(e) });
    _ = child.wait(io) catch {};
    return ztcl.Value.empty;
}

/// The panic handler of the program: a report, then the default panic.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    report(msg, first_trace_addr orelse @returnAddress(), null);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn onSignal(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    var buf: [96]u8 = undefined;
    const addr: usize = if (builtin.os.tag == .linux) @intFromPtr(info.fields.sigfault.addr) else @intFromPtr(info.addr);
    const msg = std.fmt.bufPrint(&buf, "signal {s} at address 0x{x}", .{ @tagName(sig), addr }) catch "signal";
    report(msg, null, ctx);
    // SA_RESETHAND gave the default action back: the signal again ends
    // the program as the system ends it, with its core and its status.
    _ = std.c.raise(sig);
}

/// Writes one report. The second report of a crash in the report is
/// skipped.
fn report(msg: []const u8, first_addr: ?usize, ctx: ?*anyopaque) void {
    if (reporting.swap(true, .acq_rel)) return;
    const io = the_io orelse return;
    if (dir_len == 0) return;
    var w: Io.Writer = .fixed(&report_buf);
    const now_ms = Io.Clock.real.now(io).toMilliseconds();
    w.print("dockyard {s} crashed\n\n{s}\n\n", .{ version, msg }) catch {};
    w.print("version: {s}\nsystem: {s} {s}", .{ version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }) catch {};
    if (on_posix) {
        const u = std.posix.uname();
        w.print(" ({s} {s})", .{ std.mem.sliceTo(&u.sysname, 0), std.mem.sliceTo(&u.release, 0) }) catch {};
    }
    w.print("\ntime (ms since 1970): {d}\nbuild: {s}\n\nstack:\n", .{ now_ms, @tagName(builtin.mode) }) catch {};
    std.debug.writeCurrentStackTrace(.{
        .first_address = if (ctx == null) first_addr else null,
        .context = if (ctx) |c| @ptrCast(@alignCast(c)) else null,
        .allow_unsafe_unwind = true,
    }, .{ .writer = &w, .mode = .no_color }) catch {};
    var name_buf: [1200]u8 = undefined;
    const path = std.fmt.bufPrint(&name_buf, "{s}{c}dockyard-{d:0>15}.crash", .{ dir_buf[0..dir_len], std.fs.path.sep, @as(u64, @intCast(@max(now_ms, 0))) }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() }) catch return;
    if (on_posix) {
        var line_buf: [1300]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "dockyard: crash report in {s}\n", .{path}) catch return;
        _ = std.c.write(2, line.ptr, line.len);
    }
}
