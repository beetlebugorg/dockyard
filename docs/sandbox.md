# The sandbox

With `--sandbox`, the terminal pane runs the agent program in a small Linux virtual machine. The agent program then sees only the project folder, and it reaches only the hosts that you allow. Use it when you let the agent program run commands without a prompt for each one.

```sh
dockyard --sandbox ~/dockyard/guest ~/dockyard/my-app
```

> [!NOTE]
> The sandbox is a first form. It runs on x86-64 Linux with KVM. The Windows port is in progress, and macOS is not checked yet. The pane runs a BusyBox shell (`/bin/busybox sh -l`) by default. `--sandbox-command LIST` runs another program of the guest. A guest release has the tools disk, with node, npm, git, and Zig in `/tools/bin`.

## What it needs

- x86-64 Linux, with read and write access to `/dev/kvm` and `/dev/vhost-vsock`. Add your user to the `kvm` group.
- A guest folder, in one of two forms:
  - A signed guest release: a folder with a `manifest.json`, the kernel, the root disk, and the tools disk (`os/tools/build.sh` and `os/tools/manifest.sh`). dockyard copies it into `.dockyard/guest/` of the project, installs it in the image store of ztcl when the store has another counter, and boots it with `ztcl::vm create -image`. The store is `ZTCL_VM_IMAGES`, or the folder of the `ztcl` runner. A Debug build of dockyard trusts the test key of `os/tools/testkey`. A release key comes later.
  - A plain folder: the kernel (`bzImage`) and the agent of ztcl (`agent.cpio`). The `vm-guest` workflow of ztcl builds them. dockyard copies them into `.dockyard/guest/` of the project at each start, with a `.gitignore`. This guest has BusyBox only.

## What the guest can reach

| | In the sandbox | In a normal run |
|---|---|---|
| The project folder | Read and write, at `/work` | Read and write |
| Other files of your user | No | Yes |
| The network | Only the hosts of the allow list, through the proxy of dockyard | Each host |
| Your keychain, SSH keys, and home folder | No | Yes |
| Programs of the host | No: the programs of the guest only | Each program |

The guest has its own kernel on the hypervisor of the host (`ztcl::vm`). It has no network device. The helper of dockyard in the guest (`dockyard-guest`, about 17 KB) gives the pane a terminal, and it listens on `127.0.0.1:3128` in the guest. Each connection to that port goes over vsock to the egress proxy of dockyard, and `HTTPS_PROXY` points the programs of the guest at it.

## The allow list

The proxy accepts `CONNECT host:port` for the hosts of the allow list, and answers 403 for each other host. The default list:

- `api.anthropic.com` and `statsig.anthropic.com`, for Claude Code
- `registry.npmjs.org`, for npm

Each connection and each blocked attempt is an event: the host, the port, the result, the bytes in each direction, and the time. The [monitor](monitor.md) shows them, and its Allow button adds a host to the list.

The proxy sees the host names of HTTPS connections, and not the content. The bodies of the requests stay encrypted.

## Hooks

dockyard writes the hook settings of Claude Code in the home folder of the guest. Each hook of Claude Code, such as a tool call with its command or its path, goes through the helper to the log, and the [monitor](monitor.md) shows it.

## Shares

In a sandbox run the status bar has a Shares button. The panel moves single files in and out of the guest:

- **Share** puts a file of the project in `/inbox/NAME` of the guest.
- **Revoke** takes it out of `/inbox`.
- **Export** puts a file of the guest in `exports/` of the project.

Each step is an event of the monitor.

## Limits of this form

- The programs of the guest run as root in the guest, so mode 0444 in `/inbox` does not stop a write in the guest.
- The project folder is a share of the guest, so a program of the guest can change each file of the project, `.git` too. Commit your work before a long run.
- The guest folder comes from a path that you give. dockyard does not fetch a release yet.
- Only a Debug build boots a release of `os/tools`, because only the test key signs these releases today.
- The monitor does not list the files that the guest reads, and it can miss a program that runs for less than 50 ms.
