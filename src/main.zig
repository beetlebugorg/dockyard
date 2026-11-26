//! The `dockyard` program. `dockyard [flags] [project folder]` opens the
//! window of `dockyard.tcl` for the folder (default: the current
//! folder). The terminal pane runs the agent program from the `PATH`,
//! or a shell when the `PATH` has none.
//!
//! The program makes a ztcl interpreter with the capabilities of
//! `host.zig`, a backend (Wayland on Linux, AppKit on macOS, or the
//! headless backend with `--headless`), and a ztk `App`, as the `ztk`
//! program of ztk does.

const std = @import("std");
const Io = std.Io;
const ztcl = @import("ztcl");
const ztk = @import("ztk");
const host = @import("host.zig");

const window_script = @embedFile("dockyard.tcl");

const usage =
    \\usage: dockyard [flags] [project folder]
    \\  --agent PROGRAM          run PROGRAM in the terminal pane (default: claude from the PATH)
    \\  --headless               use the headless backend
    \\  --dark                   the dark color scheme
    \\  --exit-after-frames N    exit after N frames
    \\  --screenshot FILE.png    with --headless: write the last frame at the exit
    \\
;

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const w: *Io.Writer = @ptrCast(@alignCast(ctx.?));
    w.writeAll(bytes) catch {};
}

fn fail(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print(fmt, args) catch {};
    err.flush() catch {};
    std.process.exit(1);
}

var exit_err: ?*Io.Writer = null;

fn exitNow(code: u8) noreturn {
    if (exit_err) |e| e.flush() catch {};
    std.process.exit(code);
}

pub fn main(init: std.process.Init) !void {
    const start_us = ztk.loop.system_clock.now(null);
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var err_buf: [1024]u8 = undefined;
    var err_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};
    exit_err = err;

    var headless = false;
    var dark = false;
    var max_frames: ?u64 = null;
    var screenshot: ?[]const u8 = null;
    var agent_flag: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, a, "--dark")) {
            dark = true;
        } else if (std.mem.eql(u8, a, "--agent") and has_value) {
            i += 1;
            agent_flag = args[i];
        } else if (std.mem.eql(u8, a, "--exit-after-frames") and has_value) {
            i += 1;
            max_frames = std.fmt.parseInt(u64, args[i], 10) catch fail(err, "dockyard: bad frame count\n", .{});
        } else if (std.mem.eql(u8, a, "--screenshot") and has_value) {
            i += 1;
            screenshot = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try out.writeAll(usage);
            return;
        } else if (a.len > 0 and a[0] == '-') {
            fail(err, "dockyard: unknown flag {s}\n{s}", .{ a, usage });
        } else project = a;
    }

    // The project folder as a full path.
    // The shell gives the current folder in PWD.
    const cwd = init.environ_map.get("PWD") orelse "/";
    const folder = if (project) |p| try std.fs.path.resolve(arena, &.{ cwd, p }) else cwd;
    const env = try host.environment(arena, init.environ_map);
    const path = try host.cleanPath(arena, init.environ_map.get("PATH") orelse "/usr/bin:/bin");
    const agent = if (agent_flag) |f| f else try host.findProgram(arena, path, "claude");

    var it: ztcl.Interp = undefined;
    try it.init(init.gpa);
    defer it.deinit();
    it.output = .{ .ctx = out, .write = write };
    try host.allow(&it, folder, env);
    try host.setVars(&it, .{
        .project = folder,
        .agent = agent,
        .shell = init.environ_map.get("SHELL") orelse "/bin/sh",
        .path = path,
    });

    var head: ?*ztk.headless.Headless = null;
    var wl: if (ztk.wayland_enabled) ?*ztk.wayland.Wayland else void = if (ztk.wayland_enabled) null else {};
    var mac: if (ztk.appkit_enabled) ?*ztk.appkit.AppKit else void = if (ztk.appkit_enabled) null else {};
    var platform: ztk.platform.Platform = undefined;
    if (headless) {
        head = try ztk.headless.Headless.init(init.gpa);
        platform = head.?.platform();
    } else if (ztk.appkit_enabled) {
        mac = ztk.appkit.AppKit.init(init.gpa) catch |e| fail(err, "dockyard: cannot use AppKit: {s}\n", .{@errorName(e)});
        platform = mac.?.platform();
    } else if (ztk.wayland_enabled) {
        if (init.environ_map.get("WAYLAND_DISPLAY") == null) fail(err, "dockyard: no Wayland display. Use --headless, or run in a Wayland session.\n", .{});
        wl = ztk.wayland.Wayland.init(init.gpa) catch |e| fail(err, "dockyard: cannot use the Wayland display: {s}\n", .{@errorName(e)});
        platform = wl.?.platform();
    } else fail(err, "dockyard: this build has no window backend. Use --headless.\n", .{});
    defer if (head) |h| h.deinit();
    defer if (ztk.appkit_enabled) {
        if (mac) |m| m.deinit();
    };
    defer if (ztk.wayland_enabled) {
        if (wl) |w| w.deinit();
    };

    const app = try ztk.App.init(init.gpa, &it, .{ .root_class = "Dockyard", .app_name = "dockyard", .platform = platform, .dark = dark, .io = io, .on_exit = exitNow, .render_mode = .threaded, .start_us = start_us });
    defer app.deinit();
    app.max_frames = max_frames;

    var status: u8 = 0;
    if (app.runScript(window_script)) |_| {
        app.run() catch |e| {
            err.print("{s}\n", .{if (e == error.TclError) it.str(it.result) catch "error" else @errorName(e)}) catch {};
            status = 1;
        };
    } else |e| {
        err.print("{s}\n", .{if (e == error.TclError) it.str(it.result) catch "error" else @errorName(e)}) catch {};
        status = 1;
    }
    app.render.flush();
    if (screenshot) |file| if (head) |h| if (app.window) |win| if (h.image(win)) |img| {
        const bytes = try ztk.png.encode(init.gpa, img);
        defer init.gpa.free(bytes);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes });
    };
    out.flush() catch {};
    err.flush() catch {};
    if (status != 0) exitNow(status);
}
