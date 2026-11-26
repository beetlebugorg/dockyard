# dockyard output exception

dockyard is free software under the GNU Affero General Public License, version 3 (the file `LICENSE`). As an additional permission under section 7 of that license, the copyright holders of dockyard give this exception:

1. The output of dockyard is not covered by the AGPL. Output is each file that dockyard writes into a project of a user (for example `CLAUDE.md`, `.mcp.json`, and other starter files), each file that the user or an agent writes, and each program, bundle, or binary that dockyard builds.
2. A user may license their projects and the programs that dockyard builds from them under any terms that the user chooses.
3. The files in `src/project/` are the templates that dockyard copies into projects. They are under the BSD Zero Clause License (0BSD), in `src/project/LICENSE`, so that their copies impose no terms.
4. A built program contains the runtimes of ztcl and ztk. Their own licenses (BSD-2-Clause) apply to those runtimes. dockyard adds none of its own code to a built program.

This exception does not change the terms of dockyard itself. A modified copy of dockyard, and a network service that runs one, remain under the AGPL.
