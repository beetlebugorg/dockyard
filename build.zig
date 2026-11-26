// The build of dockyard: the program and its tests.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ztk_dep = b.dependency("ztk", .{ .target = target, .optimize = optimize });
    const ztcl_dep = ztk_dep.builder.dependency("ztcl", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "ztk", .module = ztk_dep.module("ztk") },
        .{ .name = "ztcl", .module = ztcl_dep.module("ztcl") },
    };
    const use_lld = target.result.ofmt != .macho;
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    // LLVM and LLD link the system start files, as in the build of ztk.
    const exe = b.addExecutable(.{ .name = "dockyard", .root_module = root, .use_llvm = true, .use_lld = use_lld });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run dockyard").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }), .use_llvm = true, .use_lld = use_lld });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-bin", "Install the test program as zig-out/bin/test").dependOn(&b.addInstallArtifact(tests, .{}).step);
}
