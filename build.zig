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

    // The ztk programs that the Build button copies (`ztk bundle`):
    // zig-out/lib/ztk/runtime/TARGET/ztk, next to zig-out/bin. The
    // default is the target of this build, with the backends of this
    // build. A Linux program of another target has the direct and the
    // headless backends of the release builds of ztk, with musl, so the
    // file is static. A macOS program from another system has only the
    // headless backend, because the AppKit backend links the frameworks
    // of the macOS SDK.
    const runtimes = b.option([]const u8, "runtimes", "The targets of the ztk programs for the Build button, separated by commas, or \"all\" or \"none\" (default: the target of this build)") orelse "";
    // The skill (tools/skill.sh) needs a static Linux program also for
    // the target of the build.
    const static_runtimes = b.option(bool, "static-runtimes", "Build the ztk program of the target of this build as for another target: static on Linux") orelse false;
    const runtimes_step = b.step("runtimes", "Install only the ztk programs of -Druntimes");
    var names: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, runtimes, "all")) {
        names.appendSlice(b.allocator, &all_targets) catch @panic("OOM");
    } else if (runtimes.len == 0) {
        if (targetName(target.result)) |n| names.append(b.allocator, n) catch @panic("OOM");
    } else if (!std.mem.eql(u8, runtimes, "none")) {
        var it = std.mem.tokenizeScalar(u8, runtimes, ',');
        while (it.next()) |n| names.append(b.allocator, n) catch @panic("OOM");
    }
    for (names.items) |n| {
        const triple = runtimeTriple(n) orelse std.debug.panic("unknown runtime target {s}", .{n});
        const rt_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("bad target"));
        const rt_dep = if (!static_runtimes and std.mem.eql(u8, n, targetName(target.result) orelse ""))
            b.dependency("ztk", .{ .target = target, .optimize = .ReleaseFast, .strip = true })
        else if (std.mem.endsWith(u8, n, "linux"))
            b.dependency("ztk", .{ .target = rt_target, .optimize = .ReleaseFast, .strip = true, .backends = @as([]const u8, "direct,headless") })
        else if (std.mem.endsWith(u8, n, "macos"))
            b.dependency("ztk", .{ .target = rt_target, .optimize = .ReleaseFast, .strip = true, .backends = @as([]const u8, "headless") })
        else
            b.dependency("ztk", .{ .target = rt_target, .optimize = .ReleaseFast, .strip = true });
        const install = b.addInstallArtifact(rt_dep.artifact("ztk"), .{ .dest_dir = .{ .override = .{ .custom = b.fmt("lib/ztk/runtime/{s}", .{n}) } } });
        b.getInstallStep().dependOn(&install.step);
        runtimes_step.dependOn(&install.step);
    }

    // The helper of the sandbox guest (src/guest/main.zig), static and
    // with no libc, for each Linux architecture of a guest:
    // zig-out/lib/dockyard/guest/ARCH/dockyard-guest.
    const guest_step = b.step("guest", "Install only the helpers of the sandbox guest");
    for ([_][]const u8{ "x86_64", "aarch64" }) |arch| {
        const gt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = b.fmt("{s}-linux-musl", .{arch}) }) catch @panic("bad target"));
        const guest = b.addExecutable(.{ .name = "dockyard-guest", .root_module = b.createModule(.{
            .root_source_file = b.path("src/guest/main.zig"),
            .target = gt,
            .optimize = .ReleaseSmall,
            .strip = true,
            .single_threaded = true,
        }) });
        const install = b.addInstallArtifact(guest, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("lib/dockyard/guest/{s}", .{arch}) } } });
        b.getInstallStep().dependOn(&install.step);
        guest_step.dependOn(&install.step);
    }

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run dockyard").dependOn(&run.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    // The preview test runs the dockyard program of this build as the child.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("dockyard_exe", exe.getEmittedBin());
    // The Build test copies the ztk program of this build.
    const host_rt = b.dependency("ztk", .{ .target = target, .optimize = .ReleaseFast, .strip = true }).artifact("ztk");
    test_opts.addOptionPath("host_runtime", host_rt.getEmittedBin());
    // The guest helper test runs the helper of this machine on the host.
    const host_guest = b.addExecutable(.{ .name = "dockyard-guest", .root_module = b.createModule(.{
        .root_source_file = b.path("src/guest/main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .linux, .abi = .musl }),
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    }) });
    test_opts.addOptionPath("guest_helper", host_guest.getEmittedBin());
    test_module.addOptions("test_options", test_opts);
    const tests = b.addTest(.{ .root_module = test_module, .use_llvm = true, .use_lld = use_lld });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());
    b.step("test", "Run the tests").dependOn(&run_tests.step);
    b.step("test-bin", "Install the test program as zig-out/bin/test").dependOn(&b.addInstallArtifact(tests, .{}).step);
}

/// The targets of `ztk bundle`.
const all_targets = [_][]const u8{ "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows" };

/// The Zig triple of the ztk program of a target of `ztk bundle`.
fn runtimeTriple(name: []const u8) ?[]const u8 {
    const triples = [_][]const u8{ "x86_64-linux-musl", "aarch64-linux-musl", "x86_64-macos", "aarch64-macos", "x86_64-windows-gnu", "aarch64-windows-gnu" };
    for (all_targets, triples) |n, t| if (std.mem.eql(u8, n, name)) return t;
    return null;
}

/// The name of `ztk bundle` for a target, or null for another target.
fn targetName(t: std.Target) ?[]const u8 {
    const arch = switch (t.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    const os = switch (t.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => return null,
    };
    for (all_targets) |n| if (std.mem.startsWith(u8, n, arch) and std.mem.endsWith(u8, n, os)) return n;
    return null;
}
