//! Tests of dockyard. They run the window on the headless backend with
//! the shell as the agent program: `/bin/sh`, or cmd.exe on Windows. No
//! test starts the real agent program. Each test has its own project
//! folder in `/tmp`, or in the temp folder of Windows. The preview child
//! is the `dockyard` program of the build, or `DOCKYARD_EXE` when it is
//! set (not on Windows), on the headless backend.

const std = @import("std");
const Io = std.Io;
const ztcl = @import("ztcl");
const ztk = @import("ztk");
const host = @import("host.zig");
const test_options = @import("test_options");
const mcp = @import("mcp.zig");
const apps = @import("apps.zig");

const on_win = @import("builtin").os.tag == .windows;

/// The shell and the PATH of the tests.
const test_shell = if (on_win) "C:\\Windows\\System32\\cmd.exe" else "/bin/sh";
const test_path = if (on_win) "C:\\Windows\\System32;C:\\Windows" else "/usr/bin:/bin";

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTempPathA(len: u32, buf: [*]u8) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn sleepMs(ms: u32) void {
    if (comptime on_win) return Sleep(ms);
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// The full path of `rel`, a path relative to the folder of the test run.
fn fullPath(a: std.mem.Allocator, rel: []const u8) ![:0]const u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    const p = try std.fs.path.resolve(a, &.{ cwd, rel });
    return a.dupeSentinel(u8, p, 0);
}

/// The path of the dockyard program: `DOCKYARD_EXE`, or the program of
/// the build, as a full path, since the path of the build can be
/// relative to the build root.
fn exePath() [:0]const u8 {
    if (comptime !on_win) {
        if (std.c.getenv("DOCKYARD_EXE")) |p| return std.mem.sliceTo(p, 0);
    }
    const built = std.fmt.comptimePrint("{s}", .{test_options.dockyard_exe});
    return fullPath(std.heap.page_allocator, built) catch built;
}

/// A text for the shell of the tests: POSIX sh, or cmd.exe.
fn sh(comptime posix: []const u8, comptime cmd: []const u8) []const u8 {
    return if (on_win) cmd else posix;
}

var next_project = std.atomic.Value(u32).init(0);

test {
    _ = host;
    _ = @import("mcp.zig");
    _ = @import("apps.zig");
    _ = @import("proxy.zig");
    _ = @import("sock.zig");
}

const window_script = @embedFile("dockyard.tcl");

const Run = struct {
    it: ztcl.Interp = undefined,
    head: *ztk.headless.Headless = undefined,
    app: *ztk.App = undefined,
    arena: std.heap.ArenaAllocator,
    dir: []const u8 = "",

    /// Makes the project folder, with `main` as main.tcl when it is not null.
    fn project(r: *Run, main: ?[]const u8) ![]const u8 {
        const a = r.arena.allocator();
        if (comptime on_win) {
            var tmp: [260]u8 = undefined;
            const n = GetTempPathA(tmp.len, &tmp);
            if (n == 0 or n >= tmp.len) return error.Unexpected;
            r.dir = try std.fmt.allocPrint(a, "{s}dockyard-test-{d}-{d}", .{ tmp[0..n], GetCurrentProcessId(), next_project.fetchAdd(1, .monotonic) });
            Io.Dir.cwd().deleteTree(std.testing.io, r.dir) catch {};
            try Io.Dir.cwd().createDirPath(std.testing.io, r.dir);
        } else {
            var t: [28:0]u8 = "/tmp/dockyard-test-XXXXXX\x00\x00\x00".*;
            if (mkdtemp(&t) == null) return error.Unexpected;
            r.dir = try a.dupe(u8, std.mem.sliceTo(&t, 0));
        }
        if (main) |text| try writeFile(a, r.dir, "main.tcl", text);
        return r.dir;
    }

    fn start(r: *Run, agent: ?[]const u8, main: ?[]const u8) !void {
        const gpa = std.testing.allocator;
        const folder = try r.project(main);
        try r.it.init(gpa);
        const a = r.arena.allocator();
        // On Windows the preview child finds its control socket in the
        // temp folder, which comes from TEMP or TMP, as in its parent.
        const env = if (comptime on_win) blk: {
            var tmp: [260]u8 = undefined;
            const n = GetTempPathA(tmp.len, &tmp);
            const t = std.mem.trimEnd(u8, tmp[0..n], "\\");
            break :blk try a.dupe([:0]const u8, &.{
                "PATH=" ++ test_path,
                "SystemRoot=C:\\Windows",
                "COMSPEC=" ++ test_shell,
                "PROMPT=$P$G",
                try std.fmt.allocPrintSentinel(a, "TEMP={s}", .{t}, 0),
                try std.fmt.allocPrintSentinel(a, "TMP={s}", .{t}, 0),
            });
        } else
            try a.dupe([:0]const u8, &.{ "PATH=" ++ test_path, "HOME=/tmp", "PS1=$ " });
        try host.allow(&r.it, folder, env);
        // The folder of the ztk programs has the ztk program of the build,
        // for the target of this computer: a link, or a copy on Windows,
        // where a link needs a right of the user.
        const rt_root = try std.fmt.allocPrint(a, "{s}/.runtimes", .{folder});
        const rt_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ rt_root, ztcl.buildnative.hostTarget() });
        try Io.Dir.cwd().createDirPath(std.testing.io, rt_dir);
        const built = std.fmt.comptimePrint("{s}", .{test_options.host_runtime});
        const full = try fullPath(a, built);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ rt_dir, if (on_win) "ztk.exe" else "ztk" });
        if (comptime on_win) {
            try Io.Dir.copyFile(Io.Dir.cwd(), full, Io.Dir.cwd(), dest, std.testing.io, .{});
        } else try Io.Dir.cwd().symLink(std.testing.io, full, dest, .{});
        apps.runtime_root = rt_root;
        try apps.register(&r.it, std.testing.io, folder);
        try host.setVars(&r.it, .{ .project = folder, .agent = agent, .shell = test_shell, .path = test_path, .agent_name = "no-such-agent-program", .runner = exePath(), .headless = true });
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
        removeFolder(r.arena.allocator(), r.dir);
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

    /// Calls the tool `name` of the bridge with the JSON `args`, as
    /// `dockyard --mcp` does, and gives the JSON-RPC answer. It waits up
    /// to 5 s for the control socket of the preview child.
    fn tool(r: *Run, name: []const u8, args: []const u8) ![]const u8 {
        const a = r.arena.allocator();
        const folder = r.dir;
        const sock = try host.controlPath(a, null, folder);
        const msg = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ name, args });
        var k: usize = 0;
        while (true) : (k += 1) {
            const answer = try mcp.handle(a, sock, msg);
            if (std.mem.indexOf(u8, answer, "The preview is not running") == null or k >= 250) return answer;
            _ = try r.eval("after 20 {set ::tick 1}; vwait ::tick");
        }
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
            sleepMs(10);
        }
        std.debug.print("{s} has no \"{s}\":\n{s}\n", .{ w, want, try r.eval(get) });
        return error.TestExpectedEqual;
    }
};

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn writeFile(a: std.mem.Allocator, folder: []const u8, name: []const u8, text: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, name });
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
}

/// Removes a test project with its folders, and its control socket.
fn removeFolder(a: std.mem.Allocator, folder: []const u8) void {
    if (host.controlPath(a, null, folder)) |sock| {
        Io.Dir.cwd().deleteFile(std.testing.io, sock) catch {};
    } else |_| {}
    Io.Dir.cwd().deleteTree(std.testing.io, folder) catch {};
}

test "the terminal pane runs the agent program in the project folder" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, null);
    defer r.stop();
    try std.testing.expect((try r.eval(".term channel")).len > 0);
    // The output differs from the typed text, so the wait sees the work
    // of the shell: the arithmetic of sh, or a variable of cmd.exe.
    _ = try r.eval(sh(".term send \"echo dockyard-\\$((40 + 2)) in \\$(pwd)\\r\"", ".term send \"set x=42\\r\"; .term send \"echo dockyard-%x% in %CD%\\r\""));
    try r.waitFor(sh("dockyard-42 in /tmp/dockyard-test-", "dockyard-42 in "));
    if (comptime on_win) try r.waitFor("\\dockyard-test-");
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
    _ = try r.eval(sh(".term send \"echo shell-\\$((1 + 1))\\r\"", ".term send \"set y=2\\r\"; .term send \"echo shell-%y%\\r\""));
    try r.waitFor("shell-2");
}

test "the preview runs main.tcl and starts it again after a change" {
    // The ztcl of the pin of ztk has ztcl::watch on Linux only. An update
    // of the pin gives it the watch of Windows (ztcl#257).
    if (comptime on_win) return error.SkipZigTest;
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, "puts preview-[expr {20 + 1}]\n");
    defer r.stop();
    try r.waitIn(".preview.log", "preview-21");
    try std.testing.expect(std.mem.startsWith(u8, try r.eval(".preview.head.state cget -text"), "Run 1 of main.tcl"));
    _ = try r.eval("set f [open /main.tcl w]; puts $f {puts preview-[expr {20 + 2}]}; close $f");
    try r.waitIn(".preview.log", "preview-22");
    try std.testing.expect(std.mem.startsWith(u8, try r.eval(".preview.head.state cget -text"), "Run 2 of main.tcl"));
}

test "the preview shows an error of main.tcl" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, "no-such-command 1 2\n");
    defer r.stop();
    try r.waitIn(".preview.log", "invalid command name \"no-such-command\"");
    // The child keeps running, and the bridge gives the error with its trace.
    try std.testing.expectEqualStrings("Run 1 of main.tcl", try r.eval(".preview.head.state cget -text"));
    const errors = try r.tool("errors", "{}");
    try std.testing.expect(std.mem.indexOf(u8, errors, "no-such-command 1 2") != null);
}

test "a project with no main.tcl gives a note" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, null);
    defer r.stop();
    try std.testing.expectEqualStrings("The project has no main.tcl yet.", try r.eval(".preview.head.state cget -text"));
}

test "the window writes .mcp.json and CLAUDE.md into the project" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, null);
    defer r.stop();
    const json = try r.eval("set f [open /.mcp.json]; set t [read $f]; close $f; set t");
    try std.testing.expect(std.mem.indexOf(u8, json, "\"args\": [\"--mcp\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, try r.eval("file size /CLAUDE.md"), "0") != 0);
}

test "the bridge drives the preview" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell,
        \\set ::count 0
        \\button .b -text "Add one" -command {incr ::count; puts count=$::count}
        \\entry .e
        \\pack .b .e -padx 20 -pady 10
        \\focus .e
        \\
    );
    defer r.stop();
    const has = struct {
        fn f(text: []const u8, want: []const u8) !void {
            if (std.mem.indexOf(u8, text, want) == null) {
                std.debug.print("no \"{s}\" in {s}\n", .{ want, text });
                return error.TestExpectedEqual;
            }
        }
    }.f;
    try has(try r.tool("widgets", "{}"), ".b Button 80 10 78 31 1 text={Add one}");
    try has(try r.tool("click", "{\"x\":100,\"y\":20}"), "\"text\":\".b\"");
    try has(try r.tool("eval", "{\"script\":\"set ::count\"}"), "\"text\":\"1\"");
    try has(try r.tool("log", "{}"), "count=1");
    try has(try r.tool("type", "{\"text\":\"hi [there]\",\"widget\":\".e\"}"), "\"text\":\".e\"");
    try has(try r.tool("key", "{\"key\":\"BackSpace\"}"), "\".e\"");
    try has(try r.tool("eval", "{\"script\":\".e get\"}"), "\"text\":\"hi [there\"");
    try has(try r.tool("eval", "{\"script\":\"error inner\"}"), "\"isError\":true");
    try has(try r.tool("screenshot", "{\"widget\":\".b\"}"), "\"type\":\"image\",\"data\":\"iVBORw0KGgo");
    try has(try r.tool("errors", "{}"), "(no errors)");
    // The preview child has the host clock.
    try has(try r.tool("eval", "{\"script\":\"clock format 0 -format %Y -gmt 1\"}"), "\"text\":\"1970\"");
    // The restart tool ends the child with status 75, and the window starts a new run.
    try has(try r.tool("restart", "{}"), "(empty result)");
    var k: usize = 0;
    while (k < 250 and std.mem.indexOf(u8, try r.eval(".preview.head.state cget -text"), "Run 2") == null) : (k += 1) {
        _ = try r.eval("after 20 {set ::tick 1}; vwait ::tick");
    }
    try std.testing.expectEqualStrings("Run 2 of main.tcl", try r.eval(".preview.head.state cget -text"));
}

extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;

test "dockyard --mcp answers a client on stdin and stdout" {
    // The client is a child of fork with pipes, which Windows has not.
    if (comptime on_win) return error.SkipZigTest;
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, "label .l -text ready; pack .l\n");
    defer r.stop();
    // The preview child is up when a tool call gets its answer.
    _ = try r.tool("log", "{}");
    const a = r.arena.allocator();
    const exe = exePath();
    const folder = try a.dupeSentinel(u8, r.dir, 0);
    var to_child: [2]c_int = undefined;
    var from_child: [2]c_int = undefined;
    if (std.c.pipe(&to_child) != 0 or std.c.pipe(&from_child) != 0) return error.Unexpected;
    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.dup2(to_child[0], 0);
        _ = std.c.dup2(from_child[1], 1);
        for ([_]c_int{ to_child[0], to_child[1], from_child[0], from_child[1] }) |fd| _ = std.c.close(fd);
        const argv = [_:null]?[*:0]const u8{ exe, "--mcp", folder.ptr };
        const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
        _ = execve(exe, &argv, &envp);
        std.c._exit(127);
    }
    _ = std.c.close(to_child[0]);
    _ = std.c.close(from_child[1]);
    defer {
        _ = std.c.kill(pid, std.c.SIG.TERM);
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        _ = std.c.close(from_child[0]);
    }
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"eval","arguments":{"script":"winfo class .l"}}}
        \\not json
        \\
    ;
    if (std.c.write(to_child[1], input.ptr, input.len) != input.len) return error.Unexpected;
    _ = std.c.close(to_child[1]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(from_child[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.items, "\n"), '\n');
    var ids: std.ArrayList(i64) = .empty;
    var label_class = false;
    while (lines.next()) |line| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        const id = v.object.get("id").?;
        try ids.append(a, if (id == .integer) id.integer else -1);
        if (std.mem.indexOf(u8, line, "\"text\":\"Label\"") != null) label_class = true;
    }
    // The notification has no answer, and the bad line gets a parse error with a null id.
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3, -1 }, ids.items);
    try std.testing.expect(label_class);
}

test "the pane shows the image of the preview and sends the input to it" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell,
        \\set ::count 0
        \\button .b -text add -command {incr ::count}
        \\place .b -x 0 -y 0 -width 100 -height 40
        \\entry .e
        \\place .e -x 0 -y 60 -width 200
        \\
    );
    defer r.stop();
    _ = try r.tool("log", "{}");
    // The child gets the size of the pane, and the pane gets its image.
    const want = try r.eval("list [winfo width .preview.box] [winfo height .preview.box]");
    var k: usize = 0;
    while (k < 250) : (k += 1) {
        _ = try r.eval("after 20 {set ::tick 1}; vwait ::tick");
        const got = try r.eval("if {[lsearch [image names] ::dockyard::preview::shot] < 0} {list} else {list [image width ::dockyard::preview::shot] [image height ::dockyard::preview::shot]}");
        if (std.mem.eql(u8, got, want)) break;
    }
    try std.testing.expectEqualStrings(want, try r.eval("list [image width ::dockyard::preview::shot] [image height ::dockyard::preview::shot]"));
    _ = try r.eval("event generate .preview.box.img <Motion> -x 20 -y 20; event generate .preview.box.img <ButtonPress-1> -x 20 -y 20; event generate .preview.box.img <ButtonRelease-1> -x 20 -y 20");
    try std.testing.expectEqualStrings("1", try r.eval("::dockyard::preview::call {set ::count}"));
    _ = try r.eval("::dockyard::preview::call {focus .e}; event generate .preview.box.img <KeyPress> -keysym h; event generate .preview.box.img <KeyPress> -keysym i");
    try std.testing.expectEqualStrings("hi", try r.eval("::dockyard::preview::call {.e get}"));
}

test "the Build button makes the program of this computer, and the app list shows it" {
    var r: Run = .{ .arena = .init(std.testing.allocator) };
    try r.start(test_shell, "label .l -text hi\npack .l\n");
    defer r.stop();
    try std.testing.expectEqualStrings("1", try r.eval("set ::dockyard::build::on([::dockyard::build::host])"));
    _ = try r.eval("::dockyard::build::start");
    const state = try r.eval(".bar.state cget -text");
    try std.testing.expect(std.mem.startsWith(u8, state, "Built: "));
    const a = r.arena.allocator();
    const folder = r.dir;
    const name = std.fs.path.basename(folder);
    const host_target = try r.eval("::dockyard::build::host");
    const file = try std.fmt.allocPrint(a, "{s}{s}", .{ name, if (on_win) ".exe" else "" });
    const program = try std.fs.path.join(a, &.{ folder, "build", host_target, file });
    const st = try Io.Dir.cwd().statFile(std.testing.io, program, .{});
    try std.testing.expect(st.size > 1 << 20);
    // The app list of the folder of the apps has the program.
    _ = try r.eval("::dockyard::apps::show");
    const rows = try r.eval("set ::dockyard::apps::rows");
    try std.testing.expect(std.mem.indexOf(u8, rows, program) != null);
}
