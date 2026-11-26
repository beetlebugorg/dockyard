# Zig 0.17.0

dockyard builds with Zig 0.17.0 and with the ztk and ztcl commits that build with it. `docs/dev/zig-0.17.md` of ztcl and of ztk list the changes of the language, the standard library, and the build system. This page lists the changes of dockyard.

- `build.zig.zon` has `.minimum_zig_version = "0.17.0"`, and CI sets Zig 0.17.0.
- `b.args` is gone. The run step uses `run.addPassthruArgs()`.
- `b.getInstallPath` is gone, because the build script runs before the install prefix is known. The tests get the path of the dockyard program from the option `dockyard_exe` of the module `test_options`, which `addOptionPath` makes from `exe.getEmittedBin()`. The path can be relative to the build root, so the tests make it a full path with `realpath`. `DOCKYARD_EXE` still overrides it, for the program of `zig build test-bin`.
- `Allocator.dupeZ(u8, s)` is `dupeSentinel(u8, s, 0)`.

On 2026-11-26, `zig build test` passed 14 of 14 tests on an x86_64 Linux machine.
