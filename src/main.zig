//! The `dockyard` program. `dockyard [flags] [project folder]` opens the
//! window of `dockyard.tcl` for the folder (default: the current
//! folder). The terminal pane runs the agent program from the `PATH`,
//! or a shell when the `PATH` has none.
//!
//! `dockyard --run FILE` runs the script of a project for the preview
//! pane instead. The window script starts this mode as a child process,
//! on a pseudo-terminal, so the output of the script shows in the pane.
//!
//! In this mode the child also opens the control socket of the MCP
//! bridge (`control.zig`). An error of the script goes to the pane and
//! to the bridge, and the child keeps running, so the bridge can report
//! the error.
//!
//! `dockyard --mcp [project folder]` is the MCP server of the bridge
//! (`mcp.zig`), for the agent program. It makes no interpreter and no
//! window.
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
const control = @import("control.zig");
const mcp = @import("mcp.zig");
const apps = @import("apps.zig");
const proxy = @import("proxy.zig");
const sandbox = @import("sandbox.zig");
const guest_release = @import("guest_release.zig");
const monitor = @import("monitor.zig");
const audit = @import("audit.zig");
const monitor_script = @embedFile("monitor.tcl");
const audit_script = @embedFile("audit.tcl");

const window_script = @embedFile("ui-icons.tcl") ++ @embedFile("theme.tcl") ++ @embedFile("ui.tcl") ++ @embedFile("activity.tcl") ++ @embedFile("dockyard.tcl");
/// The icon of the window and the logo of the bar (tools/icons.py).
const icon_script = @embedFile("icon.tcl");

const usage =
    \\usage: dockyard [flags] [project folder]
    \\  --agent PROGRAM          run PROGRAM in the terminal pane (default: claude from the PATH)
    \\  --run FILE               run the script FILE of a project (the preview child)
    \\  --sandbox DIR            run the terminal pane in a guest of ztcl::vm with the files of DIR
    \\  --sandbox-command LIST    the program of the pane in the guest (default: /bin/busybox sh -l)
    \\  --monitor                show the sandbox monitor of the project
    \\  --tui                    with --monitor: write the timeline to the terminal
    \\  --audit-export           write the audit log of the project as JSON lines, with a check of the chain
    \\  --mcp                    serve the MCP bridge of the project on stdin and stdout
    \\  --headless               use the headless backend
    \\  --dark                   the dark color scheme
    \\  --exit-after-frames N    exit after N frames
    \\  --exit-after-ms N        exit N ms after the start
    \\  --screenshot FILE.png    with --headless: write the last frame at the exit
    \\  --view NAME              open the view workspace, activity, or apps
    \\
;

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const w: *Io.Writer = @ptrCast(@alignCast(ctx.?));
    w.writeAll(bytes) catch {};
    // The preview pane shows each line when the script writes it.
    w.flush() catch {};
}

fn fail(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print(fmt, args) catch {};
    err.flush() catch {};
    std.process.exit(1);
}

var exit_err: ?*Io.Writer = null;
var the_app: ?*ztk.App = null;

/// `::dockyard::stop`: `App.run` returns at the start of the next pass,
/// as it does after the last frame of `--exit-after-frames`. So the
/// screenshot of `--screenshot` is written.
fn cmdStop(_: *ztcl.Interp, _: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (the_app) |a| a.max_frames = a.frames;
    return .{ .str = "" };
}

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
    var exit_ms: ?u64 = null;
    var screenshot: ?[]const u8 = null;
    var view: []const u8 = "workspace";
    var agent_flag: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var run_file: ?[]const u8 = null;
    var serve_mcp = false;
    var sandbox_dir: ?[]const u8 = null;
    var monitor_mode = false;
    var tui = false;
    var audit_export = false;
    var sandbox_argv: []const u8 = "/bin/busybox sh -l";
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
        } else if (std.mem.eql(u8, a, "--run") and has_value) {
            i += 1;
            run_file = args[i];
        } else if (std.mem.eql(u8, a, "--sandbox") and has_value) {
            i += 1;
            sandbox_dir = args[i];
        } else if (std.mem.eql(u8, a, "--sandbox-command") and has_value) {
            i += 1;
            sandbox_argv = args[i];
        } else if (std.mem.eql(u8, a, "--monitor")) {
            monitor_mode = true;
        } else if (std.mem.eql(u8, a, "--tui")) {
            tui = true;
            headless = true;
        } else if (std.mem.eql(u8, a, "--audit-export")) {
            audit_export = true;
        } else if (std.mem.eql(u8, a, "--mcp")) {
            serve_mcp = true;
        } else if (std.mem.eql(u8, a, "--exit-after-frames") and has_value) {
            i += 1;
            max_frames = std.fmt.parseInt(u64, args[i], 10) catch fail(err, "dockyard: bad frame count\n", .{});
        } else if (std.mem.eql(u8, a, "--exit-after-ms") and has_value) {
            i += 1;
            exit_ms = std.fmt.parseInt(u64, args[i], 10) catch fail(err, "dockyard: bad time\n", .{});
        } else if (std.mem.eql(u8, a, "--view") and has_value) {
            i += 1;
            view = args[i];
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
    // The shell gives the current folder in PWD. Windows has no PWD, or
    // the POSIX form of a Git shell, so it asks the system.
    const cwd = if (comptime @import("builtin").os.tag == .windows)
        try std.process.currentPathAlloc(io, arena)
    else
        init.environ_map.get("PWD") orelse "/";
    const folder = if (project) |p| try std.fs.path.resolve(arena, &.{ cwd, p }) else cwd;
    const runtime = init.environ_map.get("XDG_RUNTIME_DIR");
    const audit_dir = audit.dirFor(arena, init.environ_map, folder) catch "";
    if (audit_export) {
        // The exit code is 1 when the chain is broken.
        if (comptime @import("builtin").os.tag == .windows) fail(err, "dockyard: Windows has no audit log yet\n", .{});
        const ok = audit.exportTo(arena, audit_dir, 1) catch |e| fail(err, "dockyard: no audit log in {s}: {s}\n", .{ audit_dir, @errorName(e) });
        if (!ok) std.process.exit(1);
        return;
    }
    if (serve_mcp) {
        const sock = try host.controlPath(arena, runtime, folder);
        try mcp.main(init.gpa, io, sock);
        return;
    }
    const run_path = if (run_file) |f| try std.fs.path.resolve(arena, &.{ cwd, f }) else null;
    const env = try host.environment(arena, init.environ_map);
    const path = try host.cleanPath(arena, init.environ_map.get("PATH") orelse "/usr/bin:/bin");
    const agent = if (agent_flag) |f| f else try host.findProgram(arena, path, "claude");

    var it: ztcl.Interp = undefined;
    try it.init(init.gpa);
    defer it.deinit();
    it.output = .{ .ctx = out, .write = write };
    if (run_path) |f| {
        try host.allowPreview(&it, std.fs.path.dirname(f) orelse "/");
    } else {
        try host.allow(&it, folder, env);
        try apps.register(&it, io, folder);
        try proxy.register(&it);
        try host.setVars(&it, .{
            .project = folder,
            .agent = agent,
            .shell = host.shellOf(init.environ_map),
            .path = path,
            .runner = try std.process.executablePathAlloc(io, arena),
            .headless = headless,
            .dark = dark,
        });
        try it.setVar("::dockyard::view", .{ .str = view });
        const sandbox_abs = if (sandbox_dir) |d| try std.fs.path.resolve(arena, &.{ cwd, d }) else null;
        const release = if (sandbox_abs) |d| if (guest_release.isRelease(arena, io, d)) guest_release.prepare(arena, io, folder, d) catch |e|
            fail(err, "dockyard: the guest release in {s}: {s}\n", .{ d, @errorName(e) }) else null else null;
        const guest = if (release != null) sandbox.Guest{ .kernel = "" } else if (sandbox_abs) |d| sandbox.prepare(arena, io, folder, d, try std.process.executablePathAlloc(io, arena)) catch |e|
            fail(err, "dockyard: no guest files in {s}: {s}\n", .{ d, @errorName(e) }) else null;
        try sandbox.setVars(&it, guest, sandbox_argv, sandbox.default_allow);
        try guest_release.setVars(&it, release);
        it.vm_host.image_keys = guest_release.keys;
        it.vm_host.image_store = guest_release.store(arena, init.environ_map);
        try monitor.register(&it, try host.controlPath(arena, runtime, folder));
        // Windows has no audit log yet: the writer uses POSIX files.
        if (comptime @import("builtin").os.tag != .windows) if (audit_dir.len > 0) try audit.register(&it, audit_dir);
        try it.setVar("::dockyard::tui", .{ .str = if (tui) "1" else "0" });
    }

    var head: ?*ztk.headless.Headless = null;
    var wl: if (ztk.wayland_enabled) ?*ztk.wayland.Wayland else void = if (ztk.wayland_enabled) null else {};
    var mac: if (ztk.appkit_enabled) ?*ztk.appkit.AppKit else void = if (ztk.appkit_enabled) null else {};
    var platform: ztk.platform.Platform = undefined;
    if (headless) {
        head = try ztk.headless.Headless.init(init.gpa);
        // A person sees the headless window in the preview pane, so its
        // timers use the clock of the system. `--exit-after-frames` keeps
        // the clock of the tests, which moves by the full timeout of each
        // wait.
        head.?.real_clock = max_frames == null;
        platform = head.?.platform();
    } else if (ztk.appkit_enabled) {
        mac = ztk.appkit.AppKit.init(init.gpa) catch |e| fail(err, "dockyard: cannot use AppKit: {s}\n", .{@errorName(e)});
        platform = mac.?.platform();
    } else if (ztk.wayland_enabled) {
        if (init.environ_map.get("WAYLAND_DISPLAY") == null) fail(err, "dockyard: no Wayland display. Use --headless, or run in a Wayland session.\n", .{});
        wl = ztk.wayland.Wayland.init(init.gpa, .{
            .runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
            .display = init.environ_map.get("WAYLAND_DISPLAY"),
        }) catch |e| fail(err, "dockyard: cannot use the Wayland display: {s}\n", .{@errorName(e)});
        platform = wl.?.platform();
    } else fail(err, "dockyard: this build has no window backend. Use --headless.\n", .{});
    defer if (head) |h| h.deinit();
    defer if (ztk.appkit_enabled) {
        if (mac) |m| m.deinit();
    };
    defer if (ztk.wayland_enabled) {
        if (wl) |w| w.deinit();
    };

    const run_name = if (run_path) |f| std.fs.path.basename(f) else "";
    const app = try ztk.App.init(init.gpa, &it, .{ .root_class = if (run_path != null) "Preview" else "Dockyard", .app_name = if (run_path != null) "preview" else "dockyard", .platform = platform, .dark = dark, .io = io, .on_exit = exitNow, .render_mode = .threaded, .start_us = start_us });
    defer app.deinit();
    app.max_frames = max_frames;
    the_app = app;
    if (exit_ms != null) try it.register("dockyard::stop", cmdStop);

    var ctl: ?*control.Control = null;
    if (run_path) |f| {
        const sock = try host.controlPath(arena, runtime, std.fs.path.dirname(f) orelse "/");
        const err_sink: ztcl.Output = .{ .ctx = err, .write = write };
        ctl = control.start(arena, app, sock, err_sink, exitNow) catch |e| blk: {
            // The stderr of the child is buffered: the line goes out now, so
            // the log of the preview shows why the bridge is missing.
            err.print("dockyard: no MCP bridge at {s}: {s}\n", .{ sock, @errorName(e) }) catch {};
            err.flush() catch {};
            break :blk null;
        };
    }

    var status: u8 = 0;
    const main_script = if (run_path != null) try std.fmt.allocPrint(arena, "source {{/{s}}}", .{run_name}) else if (monitor_mode) icon_script ++ monitor_script else sandbox.script ++ audit_script ++ icon_script ++ window_script;
    // The timer of --exit-after-ms starts with the script.
    const script = if (exit_ms) |ms| try std.fmt.allocPrint(arena, "after {d} ::dockyard::stop\n{s}", .{ ms, main_script }) else main_script;
    if (ctl) |c| {
        // The child keeps running after an error, for the bridge.
        app.runScript(script) catch |e| {
            const info = if (e == error.TclError) it.str(it.getVarPlain("::errorInfo") catch it.result) catch "error" else @errorName(e);
            c.loadError(info);
        };
        app.run() catch |e| {
            err.print("{s}\n", .{if (e == error.TclError) it.str(it.result) catch "error" else @errorName(e)}) catch {};
            status = 1;
        };
    } else if (app.runScript(script)) |_| {
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
