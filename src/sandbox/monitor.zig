//! The rules of the sandbox monitor (issue 15). The monitor
//! (`dockyard --monitor`) shows the audit log (`audit.zig`) and writes
//! the rules: allow or block a host. The dockyard window reads the rules
//! and gives them to the proxy.
//!
//! The rules file is a file of the user, next to the control socket of
//! the project (`host.controlPath`) and outside the project, with mode
//! 0600: the guest can write the project folder.
//!
//! Tcl commands:
//!   dockyard::monitor rule KIND HOST Adds a rule (allow or block) to the rules file.
//!   dockyard::monitor rules          Gives the rules as a list of {KIND HOST}.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const c = std.c;

var rules_buf: [1024]u8 = undefined;
var rules_path: [:0]const u8 = "";

/// Sets the path of the rules from the path of the control socket of the project.
pub fn register(it: *ztcl.Interp, control_path: []const u8) !void {
    const base = if (std.mem.endsWith(u8, control_path, ".sock")) control_path[0 .. control_path.len - 5] else control_path;
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
    if (argv.len < 2) return it.wrongArgs("dockyard::monitor rule|rules ?arg ...?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
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
    return it.fail("bad option \"{s}\": must be rule or rules", .{sub});
}

test "the monitor rules stay outside the project" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var it: ztcl.Interp = undefined;
    try it.init(std.heap.page_allocator);
    defer it.deinit();
    var name: [64]u8 = undefined;
    const sock = try std.fmt.bufPrint(&name, "/tmp/dockyard-test-monitor-{d}.sock", .{c.getpid()});
    try register(&it, sock);
    defer _ = c.unlink(rules_path.ptr);
    _ = c.unlink(rules_path.ptr);
    _ = try it.eval("dockyard::monitor rule allow evil.example");
    try std.testing.expectError(error.TclError, it.eval("dockyard::monitor rule allow {a b}"));
    try std.testing.expectEqualStrings("{allow evil.example}", try it.str(try it.eval("dockyard::monitor rules")));
}
