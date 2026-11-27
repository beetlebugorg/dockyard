# CI times

This file records the wall times of the CI workflow (`.github/workflows/ci.yml`) for pull requests, before and after each change of ztcl issue #270. The wall time of a pull request is the time from the start of the run to the end of its last job. The slowest job sets it.

## Before (2026-11-26)

Runs of two pull requests, in minutes:

| Job | gitattributes-lf | proxy |
|---|---|---|
| Skill (Linux) | 19.4 | 21.0 |
| Test (Linux) | 6.8 | 3.4 |
| Run wall time | 20.3 | 21.2 |

Facts from the logs of these runs:

- `tools/skill.sh` ran `zig build runtimes` six times in sequence, once for each target of the skill zip.
- `mlugg/setup-zig` caches the Zig toolchain and the Zig cache. The Actions cache of the repository is at its limit of 10 GB, so GitHub deletes the oldest caches first.
- The concurrency group cancelled old runs for each event, so a push to main cancelled the run of the push before it, and that run saved no cache.

## Changes

1. `tools/skill.sh` builds the six targets with one `zig build`, so that Zig compiles them in parallel. The Test job builds the program and the tests with one `zig build`. Runs on main are no longer cancelled by a later push.
