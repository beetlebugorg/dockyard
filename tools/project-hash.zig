//! Prints the hash of a project path, as `host.controlPath` makes it:
//! the Wyhash of the path with the seed 0, in 16 hex digits. The log of
//! the monitor is `dockyard-HASH.monitor`. tools/screenshots.sh uses it
//! to write a sample log for the screenshot of the monitor.
//!
//! usage: zig run tools/project-hash.zig -- PATH
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const path = it.next() orelse return error.NoPath;
    var buf: [32]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{x:0>16}\n", .{std.hash.Wyhash.hash(0, path)});
    try w.interface.flush();
}
