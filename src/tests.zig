//! Tests of dockyard. They run the window on the headless backend with
//! `/bin/sh` as the agent program. No test starts the real agent program.
//! Each test has its own project folder in `/tmp`. The preview child is
//! the installed `dockyard` program (`DOCKYARD_EXE`) on the headless
//! backend.

const std = @import("std");
const ztcl = @import("ztcl");
const ztk = @import("ztk");
const host = @import("host.zig");

test {
    _ = host;
}

const window_script = @embedFile("dockyard.tcl");

const Run = struct {
    it: ztcl.Interp = undefined,
    head: *ztk.headless.Headless = undefined,
    app: *ztk.App = undefined,
    arena: std.heap.ArenaAllocator,
    dir: [28:0]u8 = "/tmp/dockyard-test-XXXXXX\x00\x00\x00".*,

    /// Makes the project folder, with `main` as main.tcl when it is not null.
    fn project(r: *Run, main: ?[]const u8) ![]const u8 {
        if (mkdtemp(&r.dir) == null) return error.Unexpected;
        const folder = std.mem.sliceTo(&r.dir, 0);
        if (main) |text| try writeFile(r.arena.allocator(), folder, "main.tcl", text);
        return folder;
    }

    fn start(r: *Run, agent: ?[]const u8, main: ?[]const u8) !void {
        const gpa = std.testing.allocator;
        const folder = try r.project(main);
        try r.it.init(gpa);
        const a = r.arena.allocator();
        const env = try a.dupe([:0]const u8, &.{ "PATH=/usr/bin:/bin", "HOME=/tmp", "PS1=$ " });
        try host.allow(&r.it, folder, env);
        const runner = std.mem.sliceTo(std.c.getenv("DOCKYARD_EXE") orelse "/bin/false", 0);
        try host.setVars(&r.it, .{ .project = folder, .agent = agent, .shell = "/bin/sh", .path = "/usr/bin:/bin", .agent_name = "no-such-agent-program", .runner = runner, .headless = true });
        r.head = try ztk.headless.Headless.init(gpa);
        r.app = try ztk.App.init(gpa, &r.it, .{ .platform = r.head.platform(), .app_name = "dockyard" });
        r.app.runScript(window_script) catch |e| {
            defer r.stop();
            std.debug.print("error: {s}\n", .{r.it.str(r.it.result) catch ""});
            return e;
        };
    }

    fn stop(r: *Run) void {
        // The child processes end with the widgets.
        r.app.deinit();
        removeFolder(r.arena.allocator(), std.mem.sliceTo(&r.dir, 0));
        r.head.deinit();
        r.it.deinit();
        r.arena.deinit();
    }

    fn eval(r: *Run, script: []const u8) ![]const u8 {
        const v = r.it.eval(script) catch |e| {
            std.debug.print("error: {s}\n", .{r.it.str(r.it.result) catch ""});
            return e;
        };
        return r.it.str(v);
    }

    /// Runs the loop until the terminal shows `want`, for at most 5 s.
    fn waitFor(r: *Run, want: []const u8) !void {
        return r.waitIn(".term", want);
    }

    /// Runs the loop until the terminal widget `w` shows `want`, for at most 5 s.
    fn waitIn(r: *Run, w: []const u8, want: []const u8) !void {
        var buf: [64]u8 = undefined;
        const get = try std.fmt.bufPrint(&buf, "{s} get -100 100", .{w});
        var k: usize = 0;
        while (k < 500) : (k += 1) {
            _ = try r.eval("after 10 {set ::tick 1}; vwait ::tick");
            const text = try r.eval(get);
            if (std.mem.indexOf(u8, text, want) != null) return;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        std.debug.print("{s} has no \"{s}\":\n{s}\n", .{ w, want, try r.eval(get) });
        return error.TestExpectedEqual;
    }
};

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn writeFile(a: std.mem.Allocator, folder: []const u8, name: []const u8, text: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ folder, name }, 0);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.Unexpected;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, text.ptr, text.len) != @as(isize, @intCast(text.len))) return error.Unexpected;
}

/// Removes the files of a test project and the folder. A project has no subfolders.
fn removeFolder(a: std.mem.Allocator, folder: []const u8) void {
    for ([_][]const u8{"main.tcl"}) |name| {
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ folder, name }, 0) catch return;
        _ = std.c.unlink(path.ptr);
    }
    const dir = a.dupeZ(u8, folder) catch return;
    _ = std.c.rmdir(dir.ptr);
}

test "the terminal pane runs the agent program in the project folder" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start("/bin/sh", null);
    defer r.stop();
    try std.testing.expect((try r.eval(".term channel")).len > 0);
    _ = try r.eval(".term send \"echo dockyard-\\$((40 + 2)) in \\$(pwd)\\r\"");
    try r.waitFor("dockyard-42 in /tmp/dockyard-test-");
    // The program ends, and Return starts it again.
    _ = try r.eval(".term send \"exit\\r\"");
    try r.waitFor("the program ended: exit 0");
    try std.testing.expectEqualStrings("", try r.eval(".term channel"));
    _ = try r.eval(".term send \"\\r\"");
    try std.testing.expect((try r.eval(".term channel")).len > 0);
}

test "a missing agent program gives a shell and the install advice" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(null, null);
    defer r.stop();
    try r.waitFor("no-such-agent-program is not on the PATH");
    try r.waitFor("npm install -g @anthropic-ai/claude-code");
    _ = try r.eval(".term send \"echo shell-\\$((1 + 1))\\r\"");
    try r.waitFor("shell-2");
}

test "the preview runs main.tcl and starts it again after a change" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start("/bin/sh", "puts preview-[expr {20 + 1}]\n");
    defer r.stop();
    try r.waitIn(".preview.log", "preview-21");
    try std.testing.expect(std.mem.startsWith(u8, try r.eval(".preview.head.state cget -text"), "Run 1 of main.tcl"));
    _ = try r.eval("set f [open /main.tcl w]; puts $f {puts preview-[expr {20 + 2}]}; close $f");
    try r.waitIn(".preview.log", "preview-22");
    try std.testing.expect(std.mem.startsWith(u8, try r.eval(".preview.head.state cget -text"), "Run 2 of main.tcl"));
}

test "the preview shows an error of main.tcl" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start("/bin/sh", "no-such-command 1 2\n");
    defer r.stop();
    try r.waitIn(".preview.log", "invalid command name \"no-such-command\"");
    var k: usize = 0;
    while (k < 200 and std.mem.indexOf(u8, try r.eval(".preview.head.state cget -text"), "ended") == null) : (k += 1) {
        _ = try r.eval("after 10 {set ::tick 1}; vwait ::tick");
    }
    try std.testing.expectEqualStrings("Run 1 of main.tcl ended: exit 1", try r.eval(".preview.head.state cget -text"));
}

test "a project with no main.tcl gives a note" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start("/bin/sh", null);
    defer r.stop();
    try std.testing.expectEqualStrings("The project has no main.tcl yet.", try r.eval(".preview.head.state cget -text"));
}
