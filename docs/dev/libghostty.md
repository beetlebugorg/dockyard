# libghostty: the state of the VT library

Checked on 2026-11-25 from the Ghostty source at commit `69023b81` (main, 2026-11-26 UTC), from its file `PACKAGING-LIBGHOSTTY.md`, and from the tags of the repository. I read the source and the docs as data. I did not build the library.

## Facts

| Question | Answer | Source |
|---|---|---|
| Is the VT core a library? | Yes. The name is `libghostty-vt`. It is a C library with a static and a shared form, an XCFramework, and a WebAssembly module. | `PACKAGING-LIBGHOSTTY.md`, `include/ghostty/vt.h` |
| Releases | Tags `vt-1.0.0`, `vt-1.0.1`, and `vt-1.0.2`. Main has `lib_version = "1.0.3-dev"`. The releases are separate from the Ghostty app. | `git ls-remote --tags`, `build.zig` |
| API stability | Semantic versions. A 1.x release only adds to the ABI. The SONAME is `libghostty-vt.so.1`, and the symbols have versions such as `GHOSTTY_VT_1.0`. A CI check fails on an ABI change that is not an addition. | "Versioning and ABI" in `PACKAGING-LIBGHOSTTY.md` |
| API surface | 209 public functions (`src/terminal/c/abi/symbols.txt`): a terminal object with `ghostty_terminal_new`, a write of bytes, resize, and a render state with row and cell iterators and dirty rows. Key and mouse encoders, the formatter, search, and selection are also in the API. | `include/ghostty/vt/*.h` |
| License | MIT (copyright Mitchell Hashimoto and the Ghostty contributors). | `LICENSE` |
| Zig version | Each release needs one Zig version. libghostty-vt 1.0.0 needs Zig 0.17.0, and Zig 0.16 does not work. Main has `minimum_zig_version = "0.17.0"`. | `build.zig.zon`, "Zig Version" in `PACKAGING-LIBGHOSTTY.md` |
| Dependencies | The build fetches `aro`, `translate_c`, `uucode`, `wuffs`, and `highway`. With `-Dsimd` (the default on native targets) it also has simdutf and Highway, in C++. `-Dsimd=false` removes both and makes the parser slower. | `deps/libghostty-vt.txt`, `PACKAGING-LIBGHOSTTY.md` |
| Platforms | Built and tested in CI: Linux x86_64 and aarch64, macOS 13 and later, Windows x86_64 (gnu ABI), wasm32-freestanding, and others. | "Platforms" table in `PACKAGING-LIBGHOSTTY.md` |

## Can ztk use it now?

The library is usable and stable for a C or Zig 0.17 program. It is not usable in ztk today, for these reasons:

1. ztk and ztcl use Zig 0.16.0. The libghostty-vt build stops with an error on Zig 0.16. ztk can only use a prebuilt library, made by a second Zig toolchain.
2. The ztk plan (section 6) allows only the platform interfaces, ztcl, and the Zig standard library. A prebuilt C library on each platform is a new dependency, and it needs the decision of the user.
3. The web build of ztk is one WebAssembly file with no library. libghostty-vt has its own WebAssembly module, and a link of the two into one file is not documented.

## Decision: plan B

ztk gets its own VT parser and terminal state in Zig, written for ztk (`src/term/` in ztk). It follows the public specifications: ECMA-48, the DEC VT100 and VT220 manuals, and the xterm control sequences document. It has the parts that a shell and a full-screen agent program use: the parser state machine, the CSI, OSC, and DCS sequences, SGR with 256 colors and 24-bit colors, the alternate screen, scroll regions, wide characters, bracketed paste, the mouse reports, and the focus reports.

The widget code uses the terminal state through one small interface: write bytes, resize, read the rows and the cells, and the dirty rows. When ztk moves to Zig 0.17 and the user approves the dependency, a second form of this interface can use libghostty-vt. The widget does not change.

No code is copied from Ghostty. If a later change uses an idea from the Ghostty source, it gets an entry in `docs/references/` of ztk.
