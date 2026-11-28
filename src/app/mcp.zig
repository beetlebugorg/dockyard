//! `dockyard --mcp [project folder]`: the MCP server of the bridge.
//!
//! The agent program starts this mode from the `.mcp.json` of the
//! project. It reads JSON-RPC 2.0 messages from stdin, one on each line,
//! and writes the answers to stdout, one on each line. It answers
//! `initialize`, `ping`, `tools/list`, and `tools/call`, and gives no
//! answer to a notification.
//!
//! Each tool call is one Tcl script. The server connects to the control
//! socket of the preview child (`control.zig`, at `host.controlPath` of
//! the project), sends the script, and gives the answer of the child to
//! the client. The scripts call the procs of `bridge.tcl`. Each word
//! from the client goes into the script with a backslash before each
//! special character, so it stays one word.

const std = @import("std");
const Io = std.Io;
const control = @import("control.zig");

const server_name = "dockyard";
const default_version = "2025-06-18";

const instructions =
    "These tools drive the live preview of the ztk app in this folder. " ++
    "dockyard runs main.tcl again after each change of a file. " ++
    "Call errors after a change, then screenshot to see the result. " ++
    "Coordinates are logical pixels in the toplevel.";

const tools_json =
    \\{"tools":[
    \\{"name":"screenshot","description":"A PNG image of the preview window, or of one widget.","inputSchema":{"type":"object","properties":{"widget":{"type":"string","description":"The widget path. The default is \".\"."}}}},
    \\{"name":"widgets","description":"The widget tree: one line per widget with the path, the class, x y width height in the toplevel, the mapped flag (1 or 0), and the -text option.","inputSchema":{"type":"object","properties":{"widget":{"type":"string","description":"The root of the tree. The default is \".\"."}}}},
    \\{"name":"eval","description":"Evaluate a Tcl script at the global level of the preview interpreter. Gives the result.","inputSchema":{"type":"object","properties":{"script":{"type":"string"}},"required":["script"]}},
    \\{"name":"click","description":"Press and release a mouse button at x y of a toplevel. Gives the path of the widget under the point.","inputSchema":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"integer","description":"1 (the default), 2, or 3."},"toplevel":{"type":"string","description":"The default is \".\"."}},"required":["x","y"]}},
    \\{"name":"type","description":"Type text: a key press and release for each character, to the widget with the focus or to the given widget.","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"widget":{"type":"string"}},"required":["text"]}},
    \\{"name":"key","description":"Press and release one key, with modifiers, for example Return, Tab, or Control-a.","inputSchema":{"type":"object","properties":{"key":{"type":"string"},"widget":{"type":"string"}},"required":["key"]}},
    \\{"name":"scroll","description":"Turn the mouse wheel at x y of a toplevel. A negative delta scrolls down.","inputSchema":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"delta":{"type":"integer","description":"120 is one step up."},"toplevel":{"type":"string"}},"required":["x","y","delta"]}},
    \\{"name":"errors","description":"The errors of the preview since the last call, with the Tcl traces.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"log","description":"The output of the preview since the last call.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"restart","description":"Start the preview again from main.tcl.","inputSchema":{"type":"object","properties":{}}}
    \\]}
;

pub fn main(gpa: std.mem.Allocator, io: Io, socket_path: [:0]const u8) !void {
    var in_buf: [1 << 20]u8 = undefined;
    var in_r = Io.File.stdin().reader(io, &in_buf);
    var out_buf: [1 << 16]u8 = undefined;
    var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    while (true) {
        const line = in_r.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = in_r.interface.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => return,
        } orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const answer = handle(arena.allocator(), socket_path, line) catch continue;
        if (answer.len == 0) continue;
        try out.writeAll(answer);
        try out.writeByte('\n');
        try out.flush();
    }
}

/// The answer to one message, or "" for a notification.
pub fn handle(a: std.mem.Allocator, socket_path: [:0]const u8, line: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return "";
    const msg = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch
        return failure(a, .null, -32700, "parse error");
    if (msg != .object) return failure(a, .null, -32600, "invalid request");
    const id = msg.object.get("id") orelse return "";
    const method = switch (msg.object.get("method") orelse .null) {
        .string => |s| s,
        else => return failure(a, id, -32600, "invalid request"),
    };
    const params: std.json.Value = msg.object.get("params") orelse .null;
    if (std.mem.eql(u8, method, "initialize")) {
        var version: []const u8 = default_version;
        if (params == .object) if (params.object.get("protocolVersion")) |v| if (v == .string) {
            version = v.string;
        };
        return success(a, id, .{
            .protocolVersion = version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = server_name, .version = @import("build_options").version },
            .instructions = instructions,
        });
    }
    if (std.mem.eql(u8, method, "ping")) return successRaw(a, id, "{}");
    if (std.mem.eql(u8, method, "tools/list")) return successRaw(a, id, tools_json);
    if (std.mem.eql(u8, method, "tools/call")) {
        if (params != .object) return failure(a, id, -32602, "tools/call needs params");
        const name = switch (params.object.get("name") orelse .null) {
            .string => |s| s,
            else => return failure(a, id, -32602, "tools/call needs a name"),
        };
        const args: std.json.Value = params.object.get("arguments") orelse .null;
        const script = toolScript(a, name, args) catch |e| switch (e) {
            error.UnknownTool => return failure(a, id, -32602, try std.fmt.allocPrint(a, "unknown tool: {s}", .{name})),
            error.BadArgument => return success(a, id, textResult(try std.fmt.allocPrint(a, "bad arguments for {s}: see the input schema", .{name}), true)),
            else => return e,
        };
        const reply = control.call(a, socket_path, script, 30_000) catch |e| return success(a, id, textResult(try std.fmt.allocPrint(
            a,
            "The preview is not running ({s}). Open this folder in dockyard, and check that main.tcl exists.",
            .{@errorName(e)},
        ), true));
        if (!reply.ok) {
            const text = if (reply.info.len > 0) reply.info else reply.@"error";
            return success(a, id, textResult(text, true));
        }
        if (std.mem.eql(u8, name, "screenshot")) {
            return success(a, id, .{ .content = .{.{ .type = "image", .data = reply.result, .mimeType = "image/png" }} });
        }
        var text = reply.result;
        if (text.len == 0) text = if (std.mem.eql(u8, name, "errors")) "(no errors)" else if (std.mem.eql(u8, name, "log")) "(no output)" else "(empty result)";
        return success(a, id, textResult(text, false));
    }
    return failure(a, id, -32601, try std.fmt.allocPrint(a, "unknown method: {s}", .{method}));
}

fn textResult(text: []const u8, is_error: bool) struct { content: struct { struct { type: []const u8, text: []const u8 } }, isError: bool } {
    return .{ .content = .{.{ .type = "text", .text = text }}, .isError = is_error };
}

fn success(a: std.mem.Allocator, id: std.json.Value, result: anytype) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .result = result }, .{}, &out.writer);
    return out.written();
}

fn successRaw(a: std.mem.Allocator, id: std.json.Value, raw: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &out.writer);
    try out.writer.writeAll(",\"result\":");
    for (raw) |ch| if (ch != '\n') try out.writer.writeByte(ch);
    try out.writer.writeByte('}');
    return out.written();
}

fn failure(a: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}, &out.writer);
    return out.written();
}

/// Appends `s` as one Tcl word: each special character gets a backslash.
fn word(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, ' ');
    if (s.len == 0) return out.appendSlice(a, "{}");
    for (s) |ch| switch (ch) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        '\\', '{', '}', '[', ']', '$', '"', ';', ' ', '#' => {
            try out.append(a, '\\');
            try out.append(a, ch);
        },
        // Each other control character (NUL, \v, \f, and the rest) as
        // \u00XX, so the word stays one word.
        0...8, 11, 12, 14...31, 127 => try out.print(a, "\\u{x:0>4}", .{ch}),
        else => try out.append(a, ch),
    };
}

fn argString(args: std.json.Value, name: []const u8, default: ?[]const u8) ![]const u8 {
    if (args == .object) if (args.object.get(name)) |v| switch (v) {
        .string => |s| return s,
        .null => {},
        else => return error.BadArgument,
    };
    return default orelse error.BadArgument;
}

fn argInt(args: std.json.Value, name: []const u8, default: ?i64) !i64 {
    if (args == .object) if (args.object.get(name)) |v| switch (v) {
        .integer => |n| return n,
        // A float in the exact range of an f64 integer (2^53), and
        // finite. A larger value, NaN, or an infinity is an error.
        .float => |f| {
            if (!std.math.isFinite(f) or @abs(f) > 9007199254740992.0) return error.BadArgument;
            return @intFromFloat(@round(f));
        },
        .null => {},
        else => return error.BadArgument,
    };
    return default orelse error.BadArgument;
}

/// The Tcl script of the tool `name` with the arguments `args`.
pub fn toolScript(a: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const eq = std.mem.eql;
    if (eq(u8, name, "eval")) return argString(args, "script", null);
    if (eq(u8, name, "screenshot")) {
        try s.appendSlice(a, "ztk::snapshot");
        try word(&s, a, try argString(args, "widget", "."));
    } else if (eq(u8, name, "widgets")) {
        try s.appendSlice(a, "::dockyard::bridge::widgets");
        try word(&s, a, try argString(args, "widget", "."));
    } else if (eq(u8, name, "click")) {
        try s.print(a, "::dockyard::bridge::click {d} {d} {d}", .{ try argInt(args, "x", null), try argInt(args, "y", null), try argInt(args, "button", 1) });
        try word(&s, a, try argString(args, "toplevel", "."));
    } else if (eq(u8, name, "type")) {
        try s.appendSlice(a, "::dockyard::bridge::type");
        try word(&s, a, try argString(args, "text", null));
        try word(&s, a, try argString(args, "widget", ""));
    } else if (eq(u8, name, "key")) {
        try s.appendSlice(a, "::dockyard::bridge::key");
        try word(&s, a, try argString(args, "key", null));
        try word(&s, a, try argString(args, "widget", ""));
    } else if (eq(u8, name, "scroll")) {
        try s.print(a, "::dockyard::bridge::scroll {d} {d} {d}", .{ try argInt(args, "x", null), try argInt(args, "y", null), try argInt(args, "delta", null) });
        try word(&s, a, try argString(args, "toplevel", "."));
    } else if (eq(u8, name, "errors")) {
        try s.appendSlice(a, "::dockyard::bridge::errors");
    } else if (eq(u8, name, "log")) {
        try s.appendSlice(a, "::dockyard::bridge::log");
    } else if (eq(u8, name, "restart")) {
        try s.appendSlice(a, "::dockyard::bridge::restart");
    } else return error.UnknownTool;
    return s.items;
}

test "a tool word keeps its special characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"text\":\"a [b] $c {d}\\n\"}", .{});
    try std.testing.expectEqualStrings("::dockyard::bridge::type a\\ \\[b\\]\\ \\$c\\ \\{d\\}\\n {}", try toolScript(a, "type", args));
    try std.testing.expectError(error.BadArgument, toolScript(a, "click", args));
    try std.testing.expectError(error.UnknownTool, toolScript(a, "no-such-tool", args));
    // A vertical tab, a form feed, and a NUL stay in one word.
    const ctl = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"text\":\"a\\u000bb\\u000cc\\u0000d\"}", .{});
    try std.testing.expectEqualStrings("::dockyard::bridge::type a\\u000bb\\u000cc\\u0000d {}", try toolScript(a, "type", ctl));
}

test "an integer argument refuses a float out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"x\":2.6}", .{});
    try std.testing.expectEqual(@as(i64, 3), try argInt(ok, "x", null));
    const big = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"x\":1e300}", .{});
    try std.testing.expectError(error.BadArgument, argInt(big, "x", null));
    var nan = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"x\":0.5}", .{});
    nan.object.getPtr("x").?.* = .{ .float = std.math.nan(f64) };
    try std.testing.expectError(error.BadArgument, argInt(nan, "x", null));
}

test "the server answers initialize and gives no answer to a notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const init_answer = try handle(a, "/nonexistent.sock", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}");
    try std.testing.expect(std.mem.indexOf(u8, init_answer, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expectEqualStrings("", try handle(a, "/nonexistent.sock", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
    const list = try handle(a, "/nonexistent.sock", "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"tools/list\"}");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, list, .{});
    try std.testing.expectEqual(10, parsed.object.get("result").?.object.get("tools").?.array.items.len);
    const down = try handle(a, "/nonexistent.sock", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"log\"}}");
    try std.testing.expect(std.mem.indexOf(u8, down, "The preview is not running") != null);
}
