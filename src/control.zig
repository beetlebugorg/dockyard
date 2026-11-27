//! The control socket of the preview child, for the MCP bridge.
//!
//! The Tcl script of the preview has no `socket` command. This Zig code
//! opens a Unix socket at `host.controlPath` of the project before
//! main.tcl runs. A native timer of the ztk loop polls the socket every
//! 20 ms with no wait. For each connection it reads one request line,
//! `{"tcl": SCRIPT}`, evaluates SCRIPT at the global level of the
//! interpreter, writes one answer line, and closes the connection. The
//! answer is `{"ok": true, "result": TEXT}` or `{"ok": false, "error":
//! TEXT, "info": ERRORINFO}`.
//!
//! The output of the script and the background errors go to the pane
//! as before, and also to two buffers. `::dockyard::bridge::log` and
//! `::dockyard::bridge::errors` give the text of a buffer since the last
//! call and clear it. `::dockyard::bridge::frames` gives the count of
//! drawn frames. `::dockyard::bridge::restart` ends the child with
//! status 75 after the answer, and the window script starts it again.
//!
//! The socket file has mode 0600, and on Windows it is in the temp
//! folder of the user (`sock.zig`). A request can do what the preview
//! script can do, with the same capabilities.
//!
//! `call` is the client side: the MCP server and the preview pane of
//! the window use it.

const std = @import("std");
const ztcl = @import("ztcl");
const ztk = @import("ztk");
const sock = @import("sock.zig");

const bridge_script = @embedFile("bridge.tcl");

/// The exit status that asks the window script for a new run.
pub const restart_status: u8 = 75;

/// The most bytes that each buffer keeps. Older text goes first.
const buffer_max = 256 * 1024;
const request_max = 16 * 1024 * 1024;
const poll_us = 20 * 1000;

pub const Control = struct {
    gpa: std.mem.Allocator,
    app: *ztk.App,
    fd: sock.Fd,
    out: ?ztcl.Output,
    err: ztcl.Output,
    log: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    restart: bool = false,
    exit: *const fn (u8) noreturn,

    /// Writes to the original sink and to the buffers.
    fn writeOut(ctx: ?*anyopaque, bytes: []const u8) void {
        const c: *Control = @ptrCast(@alignCast(ctx.?));
        if (c.out) |o| o.write(o.ctx, bytes);
        keep(c.gpa, &c.log, bytes);
    }

    fn writeErr(ctx: ?*anyopaque, bytes: []const u8) void {
        const c: *Control = @ptrCast(@alignCast(ctx.?));
        c.err.write(c.err.ctx, bytes);
        keep(c.gpa, &c.log, bytes);
        keep(c.gpa, &c.errors, bytes);
    }

    /// Records an error of main.tcl, with its trace.
    pub fn loadError(c: *Control, text: []const u8) void {
        writeErr(c, text);
        writeErr(c, "\n");
    }
};

var current: ?*Control = null;

fn keep(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), bytes: []const u8) void {
    buf.appendSlice(gpa, bytes) catch return;
    if (buf.items.len > buffer_max) {
        const drop = buf.items.len - buffer_max;
        std.mem.copyForwards(u8, buf.items[0..buffer_max], buf.items[drop..]);
        buf.shrinkRetainingCapacity(buffer_max);
    }
}

/// Opens the socket at `path`, puts the buffers between the interpreter
/// and its sinks, registers the bridge commands, and starts the timer.
pub fn start(gpa: std.mem.Allocator, app: *ztk.App, path: [:0]const u8, err: ztcl.Output, exit: *const fn (u8) noreturn) !*Control {
    const fd = try listen(path);
    const c = try gpa.create(Control);
    c.* = .{ .gpa = gpa, .app = app, .fd = fd, .out = app.it.output, .err = err, .exit = exit };
    app.it.output = .{ .ctx = c, .write = Control.writeOut };
    app.err_output = .{ .ctx = c, .write = Control.writeErr };
    current = c;
    const it = app.it;
    try it.register("dockyard::bridge::log", cmdLog);
    try it.register("dockyard::bridge::errors", cmdErrors);
    try it.register("dockyard::bridge::restart", cmdRestart);
    try it.register("dockyard::bridge::frames", cmdFrames);
    _ = try it.eval(bridge_script);
    _ = try app.loop.addNative(poll_us, tick, c);
    return c;
}

fn listen(path: [:0]const u8) !sock.Fd {
    const fd = try sock.open();
    errdefer sock.close(fd);
    try sock.bindListen(fd, path);
    return fd;
}

fn tick(ctx: ?*anyopaque) void {
    const c: *Control = @ptrCast(@alignCast(ctx.?));
    while (sock.readable(c.fd)) {
        const conn = sock.accept(c.fd) orelse break;
        serve(c, conn);
        sock.close(conn);
        if (c.restart) c.exit(restart_status);
    }
    _ = c.app.loop.addNative(poll_us, tick, c) catch {};
}

/// Reads one request line from `conn`, runs it, and writes the answer.
fn serve(c: *Control, conn: sock.Fd) void {
    sock.setTimeout(conn, .recv, 2000);
    sock.setTimeout(conn, .send, 10_000);
    var arena = std.heap.ArenaAllocator.init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var line: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (std.mem.indexOfScalar(u8, line.items, '\n') == null) {
        const n = sock.read(conn, &buf);
        if (n <= 0) return;
        line.appendSlice(a, buf[0..@intCast(n)]) catch return;
        if (line.items.len > request_max) return;
    }
    const text = line.items[0..std.mem.indexOfScalar(u8, line.items, '\n').?];
    const answer = run(c, a, text) catch return;
    writeAll(conn, answer);
}

const Request = struct { tcl: []const u8 };

/// The answer line for one request.
pub fn run(c: *Control, a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const req = std.json.parseFromSliceLeaky(Request, a, text, .{ .ignore_unknown_fields = true }) catch {
        try std.json.Stringify.value(.{ .ok = false, .@"error" = "bad request: want {\"tcl\": SCRIPT}" }, .{}, &out.writer);
        try out.writer.writeByte('\n');
        return out.written();
    };
    const result = evalGlobal(c, a, req.tcl);
    if (result.ok) {
        try std.json.Stringify.value(.{ .ok = true, .result = result.text }, .{}, &out.writer);
    } else {
        try std.json.Stringify.value(.{ .ok = false, .@"error" = result.text, .info = result.info }, .{}, &out.writer);
    }
    try out.writer.writeByte('\n');
    return out.written();
}

const Result = struct { ok: bool, text: []const u8, info: []const u8 = "" };

/// Evaluates `script` at the global level, as a callback of the loop does.
fn evalGlobal(c: *Control, a: std.mem.Allocator, script: []const u8) Result {
    const app = c.app;
    const it = app.it;
    const saved_frame = it.frame;
    const saved_ns = it.ns;
    const saved_result = it.result;
    it.frame = &it.global;
    it.ns = "";
    app.enter();
    defer {
        it.frame = saved_frame;
        it.ns = saved_ns;
        it.result = saved_result;
        app.leave();
    }
    const v = it.eval(script) catch |e| {
        if (e != error.TclError) return .{ .ok = false, .text = @errorName(e) };
        it.finishError() catch {};
        const msg = a.dupe(u8, it.str(it.result) catch "error") catch "error";
        const info_v = it.getVarPlain("::errorInfo") catch it.result;
        const info = a.dupe(u8, it.str(info_v) catch "") catch "";
        return .{ .ok = false, .text = msg, .info = info };
    };
    return .{ .ok = true, .text = a.dupe(u8, it.str(v) catch "") catch "" };
}

fn writeAll(fd: sock.Fd, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = sock.write(fd, rest);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

pub const Reply = struct { ok: bool, result: []const u8 = "", @"error": []const u8 = "", info: []const u8 = "" };

/// Sends `script` to the control socket at `path` and reads the answer.
/// The read ends after `timeout_ms` with no data, for example when a
/// script of the child runs a loop that does not end.
pub fn call(a: std.mem.Allocator, path: [:0]const u8, script: []const u8, timeout_ms: u32) !Reply {
    const fd = try sock.open();
    defer sock.close(fd);
    try sock.connect(fd, path);
    var req: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .tcl = script }, .{}, &req.writer);
    try req.writer.writeByte('\n');
    var rest = req.written();
    while (rest.len > 0) {
        const n = sock.write(fd, rest);
        if (n <= 0) return error.BrokenPipe;
        rest = rest[@intCast(n)..];
    }
    sock.setTimeout(fd, .recv, timeout_ms);
    var answer: std.ArrayList(u8) = .empty;
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const n = sock.read(fd, &buf);
        if (n < 0) return error.Timeout;
        if (n == 0) break;
        try answer.appendSlice(a, buf[0..@intCast(n)]);
    }
    if (answer.items.len == 0) return error.NoAnswer;
    return std.json.parseFromSliceLeaky(Reply, a, answer.items, .{ .ignore_unknown_fields = true });
}

fn takeBuffer(it: *ztcl.Interp, buf: *std.ArrayList(u8)) ztcl.Error!ztcl.Value {
    const text = try it.alloc().dupe(u8, buf.items);
    buf.clearRetainingCapacity();
    return .{ .str = text };
}

/// `::dockyard::bridge::log`: the output since the last call.
fn cmdLog(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("::dockyard::bridge::log");
    return takeBuffer(it, &current.?.log);
}

/// `::dockyard::bridge::errors`: the errors since the last call.
fn cmdErrors(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("::dockyard::bridge::errors");
    return takeBuffer(it, &current.?.errors);
}

/// `::dockyard::bridge::restart`: ends the child after the answer.
fn cmdRestart(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("::dockyard::bridge::restart");
    current.?.restart = true;
    return ztcl.Value.empty;
}

/// `::dockyard::bridge::frames`: the count of frames that the App drew.
/// The pane of the window reads a new image when the count changes.
fn cmdFrames(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len != 1) return it.wrongArgs("::dockyard::bridge::frames");
    return .{ .int = @intCast(current.?.app.frames) };
}
