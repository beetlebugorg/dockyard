//! The log of the sandbox monitor (issue 15). The dockyard window writes
//! one line for each event: a Tcl dict with `kind` (`net`, `exec`,
//! `exit`, `file`, `share`, or `rule`) and the fields of that kind. The
//! monitor (`dockyard --monitor`) reads the lines and writes the rules.
//!
//! The log and the rules are files of the user, next to the control
//! socket of the project (`host.controlPath`) and outside the project:
//! the guest can write the project folder, and a guest program must not
//! change the log. The files have mode 0600.
//!
//! Tcl commands:
//!   dockyard::monitor log DICT       Adds a line to the log.
//!   dockyard::monitor read OFFSET    Gives {NEXT LINES}: the lines from the byte OFFSET.
//!   dockyard::monitor rule KIND HOST Adds a rule (allow or block) to the rules file.
//!   dockyard::monitor rules          Gives the rules as a list of {KIND HOST}.
//!   dockyard::monitor path           Gives the path of the log.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const c = std.c;

var log_buf: [1024]u8 = undefined;
var rules_buf: [1024]u8 = undefined;
var log_path: [:0]const u8 = "";
var rules_path: [:0]const u8 = "";

/// Sets the paths from the path of the control socket of the project.
pub fn register(it: *ztcl.Interp, control_path: []const u8) !void {
    const base = if (std.mem.endsWith(u8, control_path, ".sock")) control_path[0 .. control_path.len - 5] else control_path;
    log_path = try std.fmt.bufPrintSentinel(&log_buf, "{s}.monitor", .{base}, 0);
    rules_path = try std.fmt.bufPrintSentinel(&rules_buf, "{s}.rules", .{base}, 0);
    try it.register("dockyard::monitor", cmdMonitor);
}

fn append(path: [:0]const u8, line: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return false;
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.write(fd, line.ptr, line.len) == @as(isize, @intCast(line.len));
}

/// The bytes of `path` from `offset`, up to 1 MB.
fn readFrom(a: std.mem.Allocator, path: [:0]const u8, offset: u64) ![]u8 {
    if (comptime builtin.os.tag == .windows) return &.{};
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (fd < 0) return &.{};
    defer _ = c.close(fd);
    const buf = try a.alloc(u8, 1 << 20);
    const n = c.pread(fd, buf.ptr, buf.len, @intCast(offset));
    return if (n > 0) buf[0..@intCast(n)] else &.{};
}

fn lines(it: *ztcl.Interp, data: []const u8) !struct { used: usize, list: ztcl.Value } {
    const a = it.alloc();
    var out: std.ArrayList(ztcl.Value) = .empty;
    var used: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, used, '\n')) |end| {
        if (end > used) try out.append(a, .{ .str = try a.dupe(u8, data[used..end]) });
        used = end + 1;
    }
    return .{ .used = used, .list = try ztcl.value.newList(a, out.items) };
}

fn cmdMonitor(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    if (argv.len < 2) return it.wrongArgs("dockyard::monitor log|read|rule|rules|path ?arg ...?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "path")) return .{ .str = log_path };
    if (std.mem.eql(u8, sub, "log")) {
        if (argv.len != 3) return it.wrongArgs("dockyard::monitor log dict");
        const text = try it.str(argv[2]);
        if (std.mem.indexOfAny(u8, text, "\r\n") != null) return it.fail("monitor: an event is one line", .{});
        if (!append(log_path, try std.fmt.allocPrint(a, "{s}\n", .{text}))) return it.fail("monitor: no write to {s}", .{log_path});
        return .empty;
    }
    if (std.mem.eql(u8, sub, "read")) {
        if (argv.len != 3) return it.wrongArgs("dockyard::monitor read offset");
        const off: u64 = @intCast(@max(0, try it.int(argv[2])));
        const r = try lines(it, try readFrom(a, log_path, off));
        return ztcl.value.newList(a, &.{ .{ .int = @intCast(off + r.used) }, r.list });
    }
    if (std.mem.eql(u8, sub, "rule")) {
        if (argv.len != 4) return it.wrongArgs("dockyard::monitor rule allow|block host");
        const kind = try it.str(argv[2]);
        const host = try it.str(argv[3]);
        if (!std.mem.eql(u8, kind, "allow") and !std.mem.eql(u8, kind, "block")) return it.fail("monitor: a rule is allow or block", .{});
        for (host) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '*' or ch == ':'))
            return it.fail("monitor: bad host \"{s}\"", .{host});
        if (!append(rules_path, try std.fmt.allocPrint(a, "{s} {s}\n", .{ kind, host }))) return it.fail("monitor: no write to {s}", .{rules_path});
        return .empty;
    }
    if (std.mem.eql(u8, sub, "rules")) return (try lines(it, try readFrom(a, rules_path, 0))).list;
    return it.fail("bad option \"{s}\": must be log, read, rule, rules, or path", .{sub});
}

fn testTicks(_: ?*anyopaque) i64 {
    return 0;
}

fn testSleep(_: ?*anyopaque, _: i64) void {}

test "the monitor log keeps the events and the rules outside the project" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var it: ztcl.Interp = undefined;
    try it.init(std.heap.page_allocator);
    defer it.deinit();
    try it.allow(@backingInt(ztcl.interp.Capability.event) | @backingInt(ztcl.interp.Capability.clock));
    it.event_host = .{ .now = testTicks, .sleep = testSleep };
    var name: [64]u8 = undefined;
    const sock = try std.fmt.bufPrint(&name, "/tmp/dockyard-test-monitor-{d}.sock", .{c.getpid()});
    try register(&it, sock);
    defer _ = c.unlink(log_path.ptr);
    defer _ = c.unlink(rules_path.ptr);
    _ = c.unlink(log_path.ptr);
    _ = c.unlink(rules_path.ptr);
    _ = try it.eval("dockyard::monitor log {kind net time 0 host evil.example port 443 result blocked up 0 down 0 ms 0}");
    _ = try it.eval("dockyard::monitor log {kind exec time 0 pid 7 ppid 1 argv {/bin/busybox ls -l}}");
    _ = try it.eval("dockyard::monitor rule allow evil.example");
    try std.testing.expectError(error.TclError, it.eval("dockyard::monitor rule allow {a b}"));
    try std.testing.expectEqualStrings("{allow evil.example}", try it.str(try it.eval("dockyard::monitor rules")));
    // The terminal view of monitor.tcl reads the log and gives each line a color.
    _ = try it.eval("set ::dockyard::project /p; set ::dockyard::tui 1");
    _ = try it.eval(@embedFile("monitor.tcl"));
    const r = try it.eval(
        \\lassign [dockyard::monitor read 0] next lines
        \\list [llength $lines] [lindex [::dockyard::monitor::describe [lindex $lines 0]] 1] [string match "*exec  7  /bin/busybox ls -l" [lindex [::dockyard::monitor::describe [lindex $lines 1]] 0]] [expr {$next > 0}] \
        \\    [string match "*  hook  PostToolUse Edit  /work/a.tcl" [lindex [::dockyard::monitor::describe {kind hook time 0 event PostToolUse tool Edit path /work/a.tcl}] 0]]
    );
    try std.testing.expectEqualStrings("2 blocked 1 1 1", try it.str(r));
}
