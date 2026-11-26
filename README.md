# dockyard

dockyard is a desktop app for ztcl and ztk apps. Its terminal pane runs an agent program (`claude` from the `PATH`) in the folder of a project. Later steps add a live preview of the app, a Build button for static binaries, and a list of the apps. The plan is in [docs/dev/spec.md](docs/dev/spec.md), and the state of each step is in [docs/dev/status.md](docs/dev/status.md).

## Build and run

Use Zig 0.16.0.

```sh
zig build
zig-out/bin/dockyard ~/dockyard/my-app
```

When `claude` is not on the `PATH`, the pane runs your shell and shows how to install it. `--agent PROGRAM` runs another program in the pane.

The terminal pane has the full power of your user. It is not a sandbox.
