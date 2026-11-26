# The window of dockyard. The terminal pane on the left runs the agent
# program in the folder of the project. The preview pane on the right is
# empty until the live preview exists (step 2 of the spec). The root
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
frame .preview -padx 16 -pady 16
label .preview.note -text "The live preview of the app shows here."
pack .preview.note -anchor nw

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

::dockyard::start
focus .term
