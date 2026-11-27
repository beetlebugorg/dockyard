# Security model

dockyard runs two kinds of programs: the agent program in the terminal pane, and the app in the preview pane. They have different powers.

## The terminal pane is not a sandbox

The terminal pane runs the agent program (or your shell) on a pseudo-terminal, as your user. The program can read and write each file that your user can, run each program, and use the network. dockyard does not limit it.

The agent program has its own permission prompts. Read them before you approve a command.

`dockyard --sandbox` runs the program of the terminal pane in a small Linux virtual machine, with a network proxy and an allow list. It is a first form on x86-64 Linux: [the sandbox](sandbox.md) has what it can reach and what is not done. Without `--sandbox`, treat the pane as your own shell.

## The sandbox and the monitor

In a sandbox run:

- The guest has its own kernel on the hypervisor (`ztcl::vm`). It has no network device.
- A program of the guest reaches the network only through the egress proxy of dockyard, and only the hosts of the allow list: `api.anthropic.com`, `statsig.anthropic.com`, and `registry.npmjs.org` by default.
- The proxy sees the host name of each HTTPS connection, and not its content.
- The log of the [monitor](monitor.md) is outside the project folder, with mode 0600, so a program of the guest cannot change it.
- The programs of the guest run as root in the guest, and the project folder is writable for them.

## The preview is a sandbox

The preview child (`dockyard --run main.tcl`) runs the app in a ztcl interpreter with only these capabilities:

| Capability | What the app can do |
|---|---|
| `file` | Read and write files in the project folder. `/` in the app is the project folder. |
| `channels` | Open files in the project folder, and `source` other scripts of the project. |
| `clock` | Read the clock. |

The preview has no `exec` and no `socket`. An app in the preview cannot run a program, open a network connection, or read a file outside the project folder.

The capabilities that a project declares, and the compute limit and the memory limit of `ztk::limit`, are not in dockyard yet.

## The MCP bridge

The MCP server (`dockyard --mcp`) talks to the preview child over a Unix socket. The socket is in `$XDG_RUNTIME_DIR`, or in `/tmp` with your user id in its name. The `eval` tool runs Tcl in the preview interpreter, with the capabilities of the preview only.

`.mcp.json` has the full path of the dockyard program. The agent program asks you to approve this server before it uses it.

## The apps that you build

dockyard does not send your projects anywhere. The project folder and its git repository stay on your computer.
