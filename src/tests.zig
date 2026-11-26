//! Tests of dockyard. They run the window on the headless backend with
//! `/bin/sh` as the agent program. No test starts the real agent program.

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

    fn start(r: *Run, agent: ?[]const u8) !void {
        const gpa = std.testing.allocator;
        try r.it.init(gpa);
        const a = r.arena.allocator();
        const env = try a.dupe([:0]const u8, &.{ "PATH=/usr/bin:/bin", "HOME=/tmp", "PS1=$ " });
        try host.allow(&r.it, "/tmp", env);
        try host.setVars(&r.it, .{ .project = "/tmp", .agent = agent, .shell = "/bin/sh", .path = "/usr/bin:/bin", .agent_name = "no-such-agent-program" });
        r.head = try ztk.headless.Headless.init(gpa);
        r.app = try ztk.App.init(gpa, &r.it, .{ .platform = r.head.platform(), .app_name = "dockyard" });
        r.app.runScript(window_script) catch |e| {
            defer r.stop();
            std.debug.print("error: {s}\n", .{r.it.str(r.it.result) catch ""});
            return e;
        };
    }

    fn stop(r: *Run) void {
        r.app.deinit();
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
        var k: usize = 0;
        while (k < 500) : (k += 1) {
            _ = try r.eval("after 10 {set ::tick 1}; vwait ::tick");
            const text = try r.eval(".term get -100 100");
            if (std.mem.indexOf(u8, text, want) != null) return;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        std.debug.print("the terminal has no \"{s}\":\n{s}\n", .{ want, try r.eval(".term get -100 100") });
        return error.TestExpectedEqual;
    }
};

test "the terminal pane runs the agent program in the project folder" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start("/bin/sh");
    defer r.stop();
    try std.testing.expect((try r.eval(".term channel")).len > 0);
    _ = try r.eval(".term send \"echo dockyard-\\$((40 + 2)) in \\$(pwd)\\r\"");
    try r.waitFor("dockyard-42 in /tmp");
    // The program ends, and Return starts it again.
    _ = try r.eval(".term send \"exit\\r\"");
    try r.waitFor("the program ended: exit 0");
    try std.testing.expectEqualStrings("", try r.eval(".term channel"));
    _ = try r.eval(".term send \"\\r\"");
    try std.testing.expect((try r.eval(".term channel")).len > 0);
}

test "a missing agent program gives a shell and the install advice" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(null);
    defer r.stop();
    try r.waitFor("no-such-agent-program is not on the PATH");
    try r.waitFor("npm install -g @anthropic-ai/claude-code");
    _ = try r.eval(".term send \"echo shell-\\$((1 + 1))\\r\"");
    try r.waitFor("shell-2");
}
