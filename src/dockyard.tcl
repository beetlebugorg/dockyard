# The window of dockyard. The terminal pane on the left runs the agent
# program in the folder of the project. The preview pane on the right
# runs main.tcl of the project in a child process (`dockyard --run`),
# and starts it again after each change in the project folder. The pane
# shows the image of the child, and sends the input of the pane to it.
# The root folder of `file` is the project folder, so `-cwd /` is the
# project.

namespace eval ::dockyard {}

wm title . "dockyard: [file tail $::dockyard::project]"
wm geometry . 1280x800

frame .bar -padx 8 -pady 6
label .bar.name -text "dockyard" -font {TkDefaultFont 13 bold}
label .bar.project -text $::dockyard::project
button .bar.build -text "Build" -command ::dockyard::build::start
button .bar.apps -text "Apps" -command ::dockyard::apps::show
label .bar.state -text ""
pack .bar.name -side left
pack .bar.project -side left -padx 12
pack .bar.apps .bar.build -side right -padx {6 0}

ztk::terminal .term -width 100 -height 36 -cwd / \
    -exitcommand ::dockyard::ended
frame .preview -padx 8 -pady 6
frame .preview.head
label .preview.head.state -text ""
button .preview.head.restart -text "Restart" -command ::dockyard::preview::restart
pack .preview.head.restart -side right
pack .preview.head.state -side left
# The image of the preview child fills .preview.box. The box keeps its
# size from the grid, so the size of the image does not change it.
frame .preview.box -width 480 -height 480
pack propagate .preview.box 0
ttk::label .preview.box.img -anchor nw -padding 0
place .preview.box.img -x 0 -y 0 -relwidth 1 -relheight 1
ztk::terminal .preview.log -width 60 -height 8 -cwd /
pack .preview.head -fill x -pady {0 6}
pack .preview.log -side bottom -fill x -pady {6 0}
pack .preview.box -fill both -expand 1

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

# The live preview. The child process runs main.tcl on the headless
# backend, and its output shows in .preview.log. A timer reads the
# changes of the file watcher.
# A change outside .git starts the child again after 150 ms with no
# other change.
namespace eval ::dockyard::preview {
    variable frames -1
    variable size ""
    variable sent ""
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
    variable frames -1
    variable sent ""
    set cmd [list $::dockyard::runner --run [file join $::dockyard::project main.tcl] --headless]
    if {$::dockyard::dark} {lappend cmd --dark}
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

# The pane. A timer asks the child for its count of frames over the
# control socket, and reads a new image (`ztk::snapshot .`) when the
# count changes. The child gets the size of the pane as the geometry of
# its ".". A child that does not answer gets a new try after 500 ms.
proc ::dockyard::preview::show {} {
    variable frames
    variable size
    variable sent
    set delay 33
    if {[catch {
        if {$size ne "" && $size ne $sent} {
            call [list wm geometry . $size]
            set sent $size
        }
        set n [call ::dockyard::bridge::frames]
        if {$n != $frames} {
            image create photo ::dockyard::preview::shot -data [call {ztk::snapshot .} 2000]
            .preview.box.img configure -image ::dockyard::preview::shot
            set frames $n
        }
    }]} {
        set delay 500
    }
    after $delay ::dockyard::preview::show
}

# Sends one input event of the pane to the child (`ztk::inject`).
proc ::dockyard::preview::send {args} {
    catch {call [list ztk::inject . {*}$args]}
}

bind .preview.box <Configure> {set ::dockyard::preview::size %wx%h}
bind .preview.box.img <Motion> {::dockyard::preview::send motion %x %y}
bind .preview.box.img <ButtonPress> {focus %W; ::dockyard::preview::send press %b %x %y}
bind .preview.box.img <ButtonRelease> {::dockyard::preview::send release %b %x %y}
bind .preview.box.img <MouseWheel> {::dockyard::preview::send wheel %x %y %D}
bind .preview.box.img <KeyPress> {::dockyard::preview::send key %K press -state %s}
bind .preview.box.img <KeyRelease> {::dockyard::preview::send key %K release -state %s}

# The Build button. One check button for each target of `ztk bundle`.
# A target with no ztk program next to dockyard is off, with the build
# flag that adds it. The host target is on by default.
namespace eval ::dockyard::build {}

proc ::dockyard::build::setup {} {
    set host [::dockyard::build::host]
    set i 0
    foreach {target ok} [::dockyard::build::targets] {
        set w .bar.t$i
        checkbutton $w -text $target -variable ::dockyard::build::on($target)
        if {!$ok} {
            $w configure -state disabled
        } elseif {$target eq $host} {
            set ::dockyard::build::on($target) 1
        }
        pack $w -side right
        incr i
    }
    pack .bar.state -side right -padx 12
}

# Builds the program of each selected target into build/TARGET/ of the
# project, and shows the result in the bar and in the app list.
proc ::dockyard::build::start {} {
    variable on
    if {![file exists /main.tcl]} {
        .bar.state configure -text "The project has no main.tcl yet."
        return
    }
    set done {}
    set failed {}
    foreach {target ok} [::dockyard::build::targets] {
        if {!$ok || ![info exists on($target)] || !$on($target)} continue
        .bar.state configure -text "Building $target"
        update idletasks
        if {[catch {::dockyard::build::run $target} res]} {
            lappend failed $target
            .preview.log write "Build of $target: $res\r\n"
        } else {
            lappend done $target
        }
    }
    if {$done eq "" && $failed eq ""} {
        .bar.state configure -text "Select a target."
    } elseif {$failed eq ""} {
        .bar.state configure -text "Built: [join $done {, }]"
    } else {
        .bar.state configure -text "Failed: [join $failed {, }]"
    }
    ::dockyard::apps::fill
}

# The app list: the apps next to the project, each with its programs.
# Launch starts the selected program. Open starts dockyard for the app.
namespace eval ::dockyard::apps {
    variable rows {}
}

proc ::dockyard::apps::show {} {
    if {![winfo exists .apps]} {
        toplevel .apps
        wm title .apps "dockyard: apps"
        listbox .apps.list -width 70 -height 16
        frame .apps.buttons
        button .apps.buttons.launch -text "Launch" -command ::dockyard::apps::launch
        button .apps.buttons.open -text "Open in dockyard" -command ::dockyard::apps::openApp
        label .apps.buttons.state -text ""
        pack .apps.buttons.launch .apps.buttons.open -side left -padx {0 6}
        pack .apps.buttons.state -side left -padx 6
        pack .apps.buttons -side bottom -fill x -padx 8 -pady 8
        pack .apps.list -fill both -expand 1 -padx 8 -pady {8 0}
    }
    fill
}

# Fills the list: a row for each app, and a row for each program of it.
proc ::dockyard::apps::fill {} {
    variable rows
    if {![winfo exists .apps]} return
    .apps.list delete 0 end
    set rows {}
    if {[catch {::dockyard::apps::scan} apps]} {
        .apps.buttons.state configure -text $apps
        return
    }
    foreach app $apps {
        lassign $app name path builds
        .apps.list insert end $name
        lappend rows [list app $path]
        foreach b $builds {
            lassign $b target file size
            .apps.list insert end [format "    %-16s %s KB" $target [expr {($size + 1023) / 1024}]]
            lappend rows [list program $file $path]
        }
    }
}

proc ::dockyard::apps::selected {} {
    variable rows
    set i [.apps.list curselection]
    if {$i eq ""} {return {}}
    return [lindex $rows $i]
}

proc ::dockyard::apps::launch {} {
    set row [selected]
    if {[lindex $row 0] ne "program"} {
        .apps.buttons.state configure -text "Select a program."
        return
    }
    if {[catch {::dockyard::apps::spawn [lindex $row 1]} err]} {
        .apps.buttons.state configure -text $err
    } else {
        .apps.buttons.state configure -text "Started [file tail [lindex $row 1]]"
    }
}

proc ::dockyard::apps::openApp {} {
    set row [selected]
    if {$row eq ""} {
        .apps.buttons.state configure -text "Select an app."
        return
    }
    set path [lindex $row end]
    if {[catch {::dockyard::apps::spawn $::dockyard::runner $path} err]} {
        .apps.buttons.state configure -text $err
    } else {
        .apps.buttons.state configure -text "Opened [file tail $path]"
    }
}

::dockyard::build::setup
::dockyard::bridgeFiles
::dockyard::start
::dockyard::preview::begin
::dockyard::preview::show
focus .term
