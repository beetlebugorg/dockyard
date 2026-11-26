# The window of dockyard. The terminal pane on the left runs the agent
# program in the folder of the project. The preview pane on the right
# runs main.tcl of the project in a child process (`dockyard --run`),
# and starts it again after each change in the project folder. The root
# folder of `file` is the project folder, so `-cwd /` is the project.

namespace eval ::dockyard {}

wm title . "dockyard: [file tail $::dockyard::project]"
wm geometry . 1280x800

frame .bar -padx 8 -pady 6
label .bar.name -text "dockyard" -font {TkDefaultFont 13 bold}
label .bar.project -text $::dockyard::project
pack .bar.name -side left
pack .bar.project -side left -padx 12

ztk::terminal .term -width 100 -height 36 -cwd / \
    -exitcommand ::dockyard::ended
frame .preview -padx 8 -pady 6
frame .preview.head
label .preview.head.state -text ""
button .preview.head.restart -text "Restart" -command ::dockyard::preview::restart
pack .preview.head.restart -side right
pack .preview.head.state -side left
ztk::terminal .preview.log -width 60 -height 12 -cwd /
pack .preview.head -fill x -pady {0 6}
pack .preview.log -fill both -expand 1

grid .bar -row 0 -column 0 -columnspan 2 -sticky ew
grid .term -row 1 -column 0 -sticky nsew
grid .preview -row 1 -column 1 -sticky nsew
grid columnconfigure . 0 -weight 3
grid columnconfigure . 1 -weight 2
grid rowconfigure . 1 -weight 1

# Starts the agent program, or a shell with the install advice.
proc ::dockyard::start {} {
    variable agent
    variable agent_name
    variable shell
    if {$agent ne ""} {
        set cmd [list $agent]
    } else {
        .term write "\x1b\[1m$agent_name\x1b\[0m is not on the PATH. This pane runs $shell.\r\n"
        .term write "Install it with: npm install -g @anthropic-ai/claude-code\r\n"
        .term write "Then type \x1b\[1mexit\x1b\[0m to start it.\r\n\r\n"
        set cmd [list $shell]
    }
    .term configure -inputcommand {} -command {}
    .term configure -command $cmd
}

# The program ended. Return starts it again.
proc ::dockyard::ended {status} {
    .term write "\r\n\x1b\[2m\[the program ended: $status. Press Return to start it again.\]\x1b\[0m\r\n"
    .term configure -inputcommand ::dockyard::restartKey
}

proc ::dockyard::restartKey {data} {
    if {[string first \r $data] < 0} return
    variable agent
    variable agent_name
    # The agent program can be installed now.
    if {$agent eq ""} {
        set agent [findProgram $agent_name $::dockyard::path]
    }
    start
}

# The live preview. The child process runs main.tcl, and its output
# shows in .preview.log. A timer reads the changes of the file watcher.
# A change outside .git starts the child again after 150 ms with no
# other change.
namespace eval ::dockyard::preview {
    variable run 0
    variable pending ""
    variable watch ""
}

proc ::dockyard::preview::state {text} {
    .preview.head.state configure -text $text
}

proc ::dockyard::preview::restart {} {
    variable run
    incr run
    .preview.log configure -command {} -exitcommand {}
    .preview.log write "\x1b\[2J\x1b\[3J\x1b\[H"
    if {![file exists /main.tcl]} {
        state "The project has no main.tcl yet."
        return
    }
    set cmd [list $::dockyard::runner --run [file join $::dockyard::project main.tcl]]
    if {$::dockyard::headless} {lappend cmd --headless}
    .preview.log configure -exitcommand [list ::dockyard::preview::ended $run] -command $cmd
    state "Run $run of main.tcl"
}

# The child of run `n` ended. An older run is ignored. Status 75 is the
# `restart` tool of the MCP bridge, and starts a new run.
proc ::dockyard::preview::ended {n status} {
    variable run
    if {$n != $run} return
    if {$status eq "exit 75"} {
        after 0 ::dockyard::preview::restart
        return
    }
    state "Run $run of main.tcl ended: $status"
}

proc ::dockyard::preview::poll {} {
    variable watch
    variable pending
    set changed 0
    foreach change [ztcl::watch changes $watch] {
        set path [lindex $change 1]
        if {$path eq "/.git" || [string match /.git/* $path]} continue
        set changed 1
    }
    if {$changed} {
        after cancel $pending
        set pending [after 150 ::dockyard::preview::restart]
    }
    after 100 ::dockyard::preview::poll
}

proc ::dockyard::preview::begin {} {
    variable watch
    restart
    if {[catch {ztcl::watch add -recursive /} watch]} {
        .preview.log write "No file watcher: $watch\r\nUse Restart after a change.\r\n"
        return
    }
    after 100 ::dockyard::preview::poll
}

# The files that connect the agent program to the MCP bridge: .mcp.json
# runs `dockyard --mcp` in the project folder, and CLAUDE.md teaches ztk
# and the tools. A file that exists stays as it is.
proc ::dockyard::bridgeFiles {} {
    if {![file exists /.mcp.json]} {
        set exe [string map {\\ \\\\ \" \\\"} $::dockyard::runner]
        set f [open /.mcp.json w]
        puts $f "\{\"mcpServers\": \{\"dockyard\": \{\"type\": \"stdio\", \"command\": \"$exe\", \"args\": \[\"--mcp\"\]\}\}\}"
        close $f
    }
    if {![file exists /CLAUDE.md]} {
        set f [open /CLAUDE.md w]
        puts -nonewline $f $::dockyard::claude_md
        close $f
    }
}

::dockyard::bridgeFiles
::dockyard::start
::dockyard::preview::begin
focus .term
