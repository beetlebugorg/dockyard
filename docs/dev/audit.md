# The audit log of the agent program

This page is the plan and the schema of the audit log. The Activity view of dockyard shows it. The log records each action of the agent program in each session: with the sandbox and without it. The monitor log of `monitor.md` is the first form of it. The audit log replaces it.

State (2026-11-27): `src/audit/audit.zig` writes the log, the chain, and the index, and `src/audit/audit.tcl` makes the records of the window: the sessions, the turns and the tool calls of the hooks, the programs of the guest, the calls of the proxy, the changes of the file watcher, the shares, and the rules. The monitor (`monitor.md`) reads it. Steps 3 to 7 of the order below are open. Windows has no audit log yet: the writer uses POSIX files.

## Requirements

- One stream of events for each project, with one schema for each kind.
- A record of each session, sandbox or not.
- Storage outside the project folder, since the agent program can write the project folder.
- An index for a fast filter and a fast search over tens of thousands of events.
- An export as JSON lines.
- Tamper evidence: a hash chain over the records, then signed records of `ztcl::meter` (ztcl issue 446) when they exist.

## A record

Each record is one JSON object on one line (JSON lines). The fields of each record:

| Field | Type | Meaning |
|---|---|---|
| `v` | integer | The version of the schema. This page is version 1. |
| `seq` | integer | The number of the record in the log, from 1, with no gaps. |
| `time` | integer | Milliseconds since 1970 (UTC), from the clock of the host. |
| `kind` | string | One of the kinds below. |
| `session` | string | The id of the dockyard session: one start of the agent program in the terminal pane. |
| `turn` | string or null | The id of the turn of the agent program: from a `UserPromptSubmit` hook to the next `Stop` hook. null outside a turn. |
| `call` | string or null | The id of the tool call of the agent program (`tool_use_id` of the hook), when the record comes from a tool call. |
| `source` | string | The source: `hook`, `helper`, `proxy`, `nat`, `watch`, `app`. |
| `data` | object | The fields of the kind. |
| `prev` | string | The SHA-256 (hex) of the line of the previous record, without its newline. The first record has 64 zeros. |

A reader checks the chain: the SHA-256 of line N is `prev` of line N+1. The last hash also goes into the index file, so a cut of the end of the log shows.

## The kinds

| `kind` | `data` | Source |
|---|---|---|
| `session` | `op` (`start`, `end`), `sandbox` (true or false), `argv`, `project`, `exit` (with `end`) | the dockyard window |
| `turn` | `op` (`start`, `end`), `prompt` (the first 2,000 bytes), `agent_session` (the `session_id` of the hook) | the hooks `UserPromptSubmit` and `Stop` |
| `tool` | `op` (`start`, `end`), `tool`, `input` (the tool input, each string cut at 2,000 bytes), `ok` (with `end`) | the hooks `PreToolUse` and `PostToolUse` |
| `exec` | `pid`, `ppid`, `argv`, `cwd` | the helper (port 7103), or the host for a session without the sandbox |
| `exit` | `pid`, `code` (the exit code, or minus the signal), `ms`, `output` (see below) | the same |
| `file` | `op` (`read`, `write`, `create`, `remove`, `rename`), `path`, `before` and `after` (SHA-256 hex of the content, or null), `diff` (see below) | the file watcher of `/work`, and the `Read`, `Write`, and `Edit` tools of the hooks |
| `net` | `host`, `port`, `result` (`allowed`, `blocked`, `failed`, `refused`), `rule` (the rule that decided), `up`, `down`, `ms` | the proxy, and the netlog of `-net nat` |
| `dns` | `name`, `type`, `result` (`allowed`, `blocked`), `rule`, `answers` | the DNS relay of `-net nat` (netlog of ztcl) |
| `blocked` | `what` (`net`, `dns`, `file`, `exec`), `target`, `rule` | each source that refuses an action. The `net` or `dns` record has the same `call` |
| `build` | `op` (`start`, `end`), `targets`, `ok`, `files` (the paths and their SHA-256) | the Build of the app |
| `share` | `op` (`share`, `revoke`, `export`), `name`, `sha256` | the sharing panel |
| `rule` | `op` (`allow`, `block`), `host` | the rules of the monitor |
| `note` | `text` | dockyard itself: a start of the log, a gap in a source, an error of a source, a repair of the log, another hook (`hook EVENT`, `tool`) |

A record of a kind keeps its fields when a later version adds fields. A reader skips the fields that it does not know.

## Large values

- `output` of `exit` is the first 4,096 bytes and the last 4,096 bytes of stdout and stderr, and the SHA-256 and the size of each whole stream.
- `diff` of `file` is a unified diff with 3 lines of context, up to 64 KiB. A larger diff or a binary file has `diff` null.
- The full content of each version of a file goes into a content store next to the log, by SHA-256 (`objects/AB/CDEF...`), up to 1 MiB for each file. The view shows a diff of any two hashes from it.

## Storage

The folder of the log is outside the project: `$XDG_STATE_HOME/dockyard/audit/HASH/` on Linux (`~/.local/state/...`), `~/Library/Application Support/dockyard/audit/HASH/` on macOS, and `%LOCALAPPDATA%\dockyard\audit\HASH\` on Windows. HASH is the hash of the project path of `host.zig`. The folder has mode 0700.

- `log-NNNNNN.jsonl`: the records, in files of up to 64 MiB, from `log-000001.jsonl`. The chain goes on from one file to the next.
- `index`: the index (below).

The ids: a session is the time of its start in ms, the process id of dockyard, and a count, in hex (`19ac1f3e2a1-3f0c-1`). A turn is the session id, a dot, and the number of the turn in the session (`19ac1f3e2a1-3f0c-1.4`).

The writer takes an `flock` on `index` for each record, so two dockyard windows of one project write one chain. It writes the line, then the index record, then the header. Before each record it compares the three, and it repairs the files after a crash between two writes:

- A complete line after the last index record that fits the chain goes into the index.
- A partial last line is cut, and a `note` record gives its size.
- A line that does not fit the chain stays as it is. The next records go into a new log file, after a `note` record. `--audit-export` then shows the break.
- `objects/`: the content store.

## The index

The index is a header of 64 bytes, then a file of fixed records of 40 bytes, one for each record of the log. All integers are little endian.

- The header: `DYAUDIT1`, the `seq` of the last record (u64), the number of its log file (u32), 4 zero bytes, the SHA-256 of its line (32 bytes), and 8 zero bytes.
- A record: `seq` (u64), `time` (i64), the offset and the length of the line in its log file (u32 each), the session, the turn, and the call (u32 each: the low 32 bits of a Wyhash of the id, 0 for null), the number of the log file (u16), the kind (u8, the order of the table of kinds), and the source (u8, the order of the list of sources).

Record N is at byte 64 + 40 × (N - 1). A filter by kind, source, or time reads the index only. A filter by session, turn, or call compares the hashes in the index, then the id in the line, so a collision of two hashes gives no wrong match. A search for text reads the lines of the matched records from a memory map of the log files (ASCII case is ignored). The index of 50,000 events is 2,000,064 bytes, so the reader keeps it in memory and reads only the new records at each query.

## The Tcl commands

`src/audit/audit.zig` registers `dockyard::audit` in the dockyard window and in the monitor:

| Command | Result |
|---|---|
| `log KIND DICT ?OPTIONS?` | Adds a record and gives its `seq`. DICT has the fields of `data`. The fields `pid`, `ppid`, `code`, `ms`, `port`, `up`, `down`, `exit`, and `size` are integers; `sandbox` and `ok` are booleans; `argv`, `targets`, and `answers` are lists of strings; `input` is a dict of strings; `before`, `after`, and `diff` are null when empty; `output`, `files`, and `response` are JSON text. Each other field is a string, up to 64 KiB (`prompt` and the values of `input` up to 2,000 bytes). |
| `json KIND JSON ?OPTIONS?` | The same, with `data` as a JSON object. |
| `session` | Starts a new session id for the next records, with no turn, and gives it. |
| `context ?-session ID? ?-turn ID?` | Sets the session and the turn of the next records. Gives the two as a dict. |
| `query ?FILTERS?` | Gives the records that match, oldest first. A record is a dict with the fields of the line; `data` is a dict, a JSON array a list, null the empty string. |
| `count ?FILTERS?` | Gives the number of records that match. |
| `last` | Gives the `seq` of the last record. |
| `verify` | Checks the chain: a dict with `ok`, `records`, `last` (the hash), and with `ok` 0, `bad` (the first bad `seq`) and `reason`. |
| `path` | Gives the folder of the log. |

OPTIONS: `-session ID`, `-turn ID`, `-call ID` (the empty string is null), `-source NAME` (default `app`), `-time MS` (default the clock of the host).

FILTERS: `-kind LIST`, `-source LIST`, `-session ID`, `-turn ID`, `-call ID`, `-since MS`, `-until MS` (both inclusive), `-after SEQ`, `-before SEQ`, `-text TEXT`, `-limit N` (the first N), `-last N` (the last N), `-format dict|json` (`json` gives the lines).

## The export

`dockyard --audit-export PROJECT` writes the records as JSON lines on stdout, with the chain check at the end (`{"kind":"note","data":{"text":"chain ok","records":N,"last":"HASH"}}`). With a broken chain, it writes the records up to the break, then `{"kind":"note","data":{"text":"chain broken","records":N,"bad":SEQ,"reason":"..."}}`, and its exit code is 1.

## Order of the work

1. This schema, and the agreement of the Activity view (questions.md).
2. The writer in `src/audit/audit.zig`: JSON lines, the chain, the index. The monitor window reads the new format. (Done.)
3. The ids of turn and tool call from the hooks (`tool_use_id`, `session_id`), and the hooks `PreToolUse` with the tool input.
4. The output of `exit`: the helper sends the bytes of each program that it starts. A program that the agent program starts has its output in the PTY or in the tool result of the hook.
5. `file` with hashes and diffs, from the watcher and the content store.
6. `dns` and `net` from the netlog of `-net nat`, when dockyard uses it.
7. Signed records with `ztcl::meter` (ztcl issue 446).
