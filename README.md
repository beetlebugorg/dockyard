# dockyard

dockyard is a desktop app for ztcl and ztk apps. Its terminal pane runs an agent program (`claude` from the `PATH`) in the folder of a project. Later steps add a live preview of the app, a Build button for static binaries, and a list of the apps. The plan is in [docs/dev/spec.md](docs/dev/spec.md), and the state of each step is in [docs/dev/status.md](docs/dev/status.md).

## Build and run

Use Zig 0.17.0.

```sh
zig build
zig-out/bin/dockyard ~/dockyard/my-app
```

When `claude` is not on the `PATH`, the pane runs your shell and shows how to install it. `--agent PROGRAM` runs another program in the pane.

The terminal pane has the full power of your user. It is not a sandbox.

The preview pane runs `main.tcl` of the project and runs it again after each change. dockyard writes `.mcp.json` and `CLAUDE.md` into a project that has none. With them, the agent program starts `dockyard --mcp`, an MCP server with tools that take screenshots of the preview, list its widgets, run Tcl in it, send clicks and keys to it, and give its errors and its output.

## Contact

Write to [opensource@beetlebug.org](mailto:opensource@beetlebug.org) about dockyard, or open an [issue](https://github.com/beetlebugorg/dockyard/issues).

## License

dockyard is under the GNU Affero General Public License, version 3 (`LICENSE`), with an output exception (`LICENSE-EXCEPTION.md`). The apps that you make with dockyard are yours: license them under any terms that you choose. The project templates in `src/project/` are under 0BSD.
