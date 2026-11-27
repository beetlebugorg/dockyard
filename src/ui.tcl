# The layout of the dockyard window (docs/dev/design.md). The header
# has the project button, the view switch, and the split Build button.
# The body has one frame for each view: Workspace (the agent card with
# the terminal and the preview card with the device frame and the
# console), Activity, and Apps. The status bar shows the sandbox, the
# network policy, the build, and the agent. A view switch puts the frame
# of the view in the grid cell of the body and removes the other frame.
# The parts come from theme.tcl. dockyard.tcl starts the programs.

namespace eval ::dockyard {}
namespace eval ::dockyard::ui {
    variable view workspace
}

# The folder of the project, with ~ for the home folder.
proc ::dockyard::ui::folder {} {
    set p $::dockyard::project
    if {[info exists ::env(HOME)] && $::env(HOME) ne "" && [string first $::env(HOME)/ $p] == 0} {
        set p ~[string range $p [string length $::env(HOME)] end]
    }
    return $p
}

# The folder for the header: a long path shows its last two folders.
proc ::dockyard::ui::shortFolder {} {
    set p [folder]
    set parts [file split $p]
    if {[string length $p] > 40 && [llength $parts] > 2} {
        set p [file join ... {*}[lrange $parts end-1 end]]
    }
    return $p
}

wm title . "[file tail $::dockyard::project] - dockyard"
wm geometry . 1280x800
wm minsize . 760 480
image create photo ::dockyard::icon -data $::dockyard::icon64
wm iconphoto . -default ::dockyard::icon
. configure -background [::ui::color bg]

::ui::header .hd [file tail $::dockyard::project] [::dockyard::ui::shortFolder] workspace
ztk::tooltip .hd.folder $::dockyard::project
.hd.project configure -command ::dockyard::ui::projectMenu
.hd.build configure -command ::dockyard::build::start
.hd.targets configure -command ::dockyard::build::picker
foreach v {workspace activity apps} {.hd.views.$v configure -variable ::dockyard::ui::view -command ::dockyard::ui::show}
set ::dockyard::ui::view workspace

# The Workspace view. .term and the preview widgets keep their paths for
# the tests and the bridge: .term is packed into the agent card.
frame .ws -padx 12 -pady 12
ztk::class .ws add body
::ui::card .agent
::ui::paneHead .agent.head terminal "Agent" $::dockyard::agent_name ready
::ui::iconButton .agent.head.restart restart "Start the agent program again"
.agent.head.restart configure -command ::dockyard::ui::restartAgent
pack .agent.head.restart -side right -in .agent.head.right
pack .agent.head -fill x

::ui::card .preview
::ui::paneHead .preview.head play "Preview" "main.tcl" idle
::ui::iconButton .preview.head.console console "Console (Ctrl+`)"
::ui::iconButton .preview.head.restart restart "Restart the preview (Ctrl+Shift+R)"
.preview.head.console configure -command ::dockyard::ui::toggleConsole
.preview.head.restart configure -command ::dockyard::preview::restart
pack .preview.head.restart .preview.head.console -side right -padx {4 0} -in .preview.head.right
pack .preview.head -fill x
frame .preview.stage
ztk::class .preview.stage add stage
# The device frame: a title strip and the image of the child. The image
# fills .preview.box, and the box keeps its size from the frame, so the
# size of the image does not change it.
frame .preview.dev
ztk::class .preview.dev add device
frame .preview.devbar
ztk::class .preview.devbar add devicebar
label .preview.devbar.t -text "main.tcl"
ztk::class .preview.devbar.t add devicetitle
label .preview.devbar.s -text ""
ztk::class .preview.devbar.s add devicesize
pack .preview.devbar.t -side left -padx 10 -pady 4
pack .preview.devbar.s -side right -padx 10
frame .preview.box -width 400 -height 300
ztk::class .preview.box add deviceapp
pack propagate .preview.box 0
ttk::label .preview.box.img -anchor nw -padding 0
place .preview.box.img -x 0 -y 0 -relwidth 1 -relheight 1
pack .preview.devbar -fill x -in .preview.dev
pack .preview.box -fill both -expand 1 -in .preview.dev -padx 1 -pady {0 1}
place .preview.dev -in .preview.stage -x 16 -y 16 -relwidth 1 -relheight 1 -width -32 -height -32

# The empty state of the stage, for a project with no main.tcl.
::ui::emptyState .preview.empty logo "Nothing to preview yet" \
    "Ask the agent for an app. It writes main.tcl, and the app runs here after each change."
frame .preview.empty.chips
ztk::class .preview.empty.chips add stage
foreach {n label text} {
    a "A tip calculator" "Make a tip calculator: the bill, a slider for the tip, and the total."
    b "A pomodoro timer" "Make a pomodoro timer with a start button and a count of rounds."
    c "A notes app" "Make a notes app with a list of notes and a search field."
} {
    ttk::button .preview.empty.chips.$n -text $label -style Chip.TButton -command [list ::dockyard::ui::suggest $text]
    pack .preview.empty.chips.$n -side left -padx 4
}
pack .preview.empty.chips -pady {16 0}

# The console: a strip with the state of the run. It opens to the log.
frame .preview.con
ztk::class .preview.con add consolebar
ttk::label .preview.con.i -image [::ui::icon console muted]
label .preview.con.t -text "Console"
ztk::class .preview.con.t add muted
label .preview.con.n -text ""
ztk::class .preview.con.n add faint
label .preview.con.k -text "Ctrl+`"
ztk::class .preview.con.k add kbd
pack .preview.con.i -side left -padx {12 6} -pady 6
pack .preview.con.t .preview.con.n -side left -padx {0 8}
pack .preview.con.k -side right -padx 12
bind .preview.con <ButtonPress-1> ::dockyard::ui::toggleConsole
bind .preview.con.t <ButtonPress-1> ::dockyard::ui::toggleConsole
ztk::terminal .preview.log -width 60 -height 8 -cwd /
ztk::class .preview.log add pane
pack .preview.con -side bottom -fill x -padx 1 -pady {0 1}
pack .preview.stage -fill both -expand 1 -padx 1

ztk::terminal .term -width 100 -height 36 -cwd / -exitcommand ::dockyard::ended
ztk::class .term add pane
pack .term -in .agent -fill both -expand 1 -padx {12 4} -pady {0 8}

grid .agent -in .ws -row 0 -column 0 -sticky nsew
grid .preview -in .ws -row 0 -column 1 -sticky nsew -padx {12 0}
grid columnconfigure .ws {0 1} -weight 1 -uniform p
grid rowconfigure .ws 0 -weight 1

# The Apps view. apps.tcl fills it.
frame .appsview -padx 24 -pady 20
ztk::class .appsview add body
::ui::pageHead .appsview.h "Apps" ""
pack .appsview.h -fill x -pady {0 16}
frame .appsview.grid
ztk::class .appsview.grid add body
pack .appsview.grid -fill both -expand 1 -anchor n

# The Activity view. activity.tcl fills it.
frame .activity -padx 16 -pady 12
ztk::class .activity add body

# The status bar.
frame .sb -padx 12 -pady 4
ztk::class .sb add statusbar
if {[info exists ::dockyard::sandbox] && $::dockyard::sandbox ne ""} {
    ::ui::statusItem .sb.sandbox shieldcheck ok "Sandbox on" ok
    ::ui::statusItem .sb.net globe muted "Network: allow list"
    ttk::button .sb.shares -text "Shares" -style Ghost.TButton -command ::dockyard::vm::shares
} else {
    ::ui::statusItem .sb.sandbox shield warn "Sandbox off: the agent runs on this computer" warn
    ::ui::statusItem .sb.net globe muted "Network: open"
    ztk::tooltip .sb.sandbox "Start dockyard with --sandbox to run the agent in a virtual machine."
}
::ui::statusItem .sb.build build muted "Not built"
::ui::statusItem .sb.agent bolt muted "Agent: starting"
pack .sb.sandbox .sb.net .sb.build -side left -padx {0 18}
if {[winfo exists .sb.shares]} {pack .sb.shares -side left}
pack .sb.agent -side right

grid .hd -row 0 -column 0 -sticky ew
grid .ws -row 1 -column 0 -sticky nsew
grid .sb -row 2 -column 0 -sticky ew
grid columnconfigure . 0 -weight 1
grid rowconfigure . 1 -weight 1

# Sets the text and the tone of one item of the status bar.
proc ::dockyard::ui::status {item iconName tone text {class muted}} {
    .sb.$item.i configure -image [::ui::icon $iconName $tone]
    .sb.$item.t configure -text $text
    foreach c {muted ok warn danger accent} {ztk::class .sb.$item.t remove $c}
    ztk::class .sb.$item.t add $class
}

# Sets the state pill of a pane head: agent or preview.
proc ::dockyard::ui::paneState {pane state} {
    set w .$pane.head.state
    set text [dict get {working "Working" ready "Ready" running "Running" idle "Waiting for main.tcl" ended "Ended" error "Error" building "Building"} $state]
    foreach c {okdot idledot warndot dangerdot} {ztk::class $w.dot remove $c}
    ztk::class $w.dot add [dict get {working okdot ready okdot running okdot idle idledot ended idledot error dangerdot building warndot} $state]
    $w.t configure -text $text
}

proc ::dockyard::ui::show {} {
    variable view
    set frames {workspace .ws activity .activity apps .appsview}
    foreach {v f} $frames {
        if {$v ne $view} {grid forget $f}
    }
    grid [dict get $frames $view] -row 1 -column 0 -sticky nsew
    if {$view eq "apps"} {::dockyard::apps::fill}
    if {$view eq "activity" && [info commands ::dockyard::activity::shown] ne ""} {::dockyard::activity::shown}
    if {$view eq "workspace"} {focus .term}
}

proc ::dockyard::ui::go {v} {
    set ::dockyard::ui::view $v
    show
}

variable ::dockyard::ui::console 0
proc ::dockyard::ui::toggleConsole {{open ""}} {
    variable console
    if {$open eq ""} {set open [expr {!$console}]}
    if {$open == $console} return
    set console $open
    if {$open} {
        pack .preview.log -in .preview -side bottom -fill x -padx {12 4} -pady {0 8} -before .preview.con
        .preview.con.i configure -image [::ui::icon console fg]
    } else {
        pack forget .preview.log
        .preview.con.i configure -image [::ui::icon console muted]
    }
}

# The stage shows the device frame, or the empty state with no main.tcl.
proc ::dockyard::ui::stage {empty} {
    if {$empty} {
        place forget .preview.dev
        place .preview.empty -in .preview.stage -relx 0.5 -rely 0.45 -anchor center
    } else {
        place forget .preview.empty
        place .preview.dev -in .preview.stage -x 16 -y 16 -relwidth 1 -relheight 1 -width -32 -height -32
    }
}

proc ::dockyard::ui::suggest {text} {
    .term paste $text
    focus .term
}

proc ::dockyard::ui::restartAgent {} {
    if {[.term channel] ne ""} {
        .term send "\x03"
        return
    }
    ::dockyard::start
    ::dockyard::ui::paneState agent working
}

# The project button: a menu of the other apps next to the project.
proc ::dockyard::ui::projectMenu {} {
    set m .hd.project.menu
    destroy $m
    menu $m -tearoff 0
    if {[catch {::dockyard::apps::scan} apps]} {set apps {}}
    foreach app $apps {
        lassign $app name path
        if {$path eq $::dockyard::project} {
            $m add command -label "$name (open)" -state disabled
        } else {
            $m add command -label $name -command [list ::dockyard::apps::openApp $path]
        }
    }
    if {$apps ne ""} {$m add separator}
    $m add command -label "All apps" -accelerator Ctrl+3 -command {::dockyard::ui::go apps}
    tk_popup $m [winfo rootx .hd.project] [expr {[winfo rooty .hd.project] + [winfo height .hd.project]}]
}

# The preview: the state of a run goes to the pane head and the console.
namespace eval ::dockyard::preview {variable status ""}

proc ::dockyard::preview::state {text {kind ""}} {
    variable status $text
    .preview.con.n configure -text $text
    if {$kind ne ""} {::dockyard::ui::paneState preview $kind}
    ::dockyard::ui::stage [expr {$kind eq "idle"}]
    if {$kind eq "error"} {::dockyard::ui::toggleConsole 1}
}

# The Build button. The targets of `ztk bundle` with a ztk program next
# to dockyard can be selected. The choice is in .dockyard/settings of the
# project. The first choice is the target of this computer.
namespace eval ::dockyard::build {
    variable status ""
}

proc ::dockyard::build::settings {} {
    set s {}
    catch {
        set f [open /.dockyard/settings]
        set s [read $f]
        close $f
        dict size $s
    }
    return $s
}

proc ::dockyard::build::save {} {
    variable on
    set s [settings]
    dict set s targets [lsort [lmap t [array names on] {if {$on($t)} {set t} else continue}]]
    catch {
        file mkdir /.dockyard
        if {![file exists /.dockyard/.gitignore]} {
            set f [open /.dockyard/.gitignore w]
            puts $f *
            close $f
        }
        set f [open /.dockyard/settings w]
        puts -nonewline $f $s
        close $f
    }
    count
}

proc ::dockyard::build::setup {} {
    variable on
    set host [host]
    set s [settings]
    set chosen [expr {[dict exists $s targets] ? [dict get $s targets] : [list $host]}]
    foreach {target ok} [targets] {
        set on($target) [expr {$ok && $target in $chosen}]
    }
    count
}

proc ::dockyard::build::count {} {
    variable on
    set n 0
    foreach t [array names on] {incr n $on($t)}
    .hd.count configure -text [expr {$n == 1 ? "1 target" : "$n targets"}]
    if {[winfo exists .picker.foot.go]} {
        .picker.foot.go configure -text [expr {$n == 1 ? "Build 1 target" : "Build $n targets"}]
    }
    return $n
}

# The name of a target in the picker and in the status bar.
proc ::dockyard::build::targetName {target} {
    lassign [split $target -] arch os
    set a [dict get {x86_64 x86-64 aarch64 arm64} $arch]
    if {$os eq "macos" && $arch eq "aarch64"} {set a "Apple silicon"}
    if {$os eq "macos" && $arch eq "x86_64"} {set a "Intel"}
    return "[dict get {linux Linux macos macOS windows Windows} $os] $a"
}

# The target picker under the Build button. Escape closes it.
proc ::dockyard::build::picker {} {
    variable on
    if {[winfo exists .picker]} {
        destroy .picker
        return
    }
    set host [host]
    set groups {linux {} macos {} windows {}}
    foreach {target ok} [targets] {
        lassign [split $target -] arch os
        set note [expr {$target eq $host ? "This computer" : !$ok ? "No ztk program" : ($os eq "macos" && ![string match *macos $host]) ? "Headless off a Mac" : ""}]
        dict lappend groups $os [list $target [lindex [targetName $target] 1] $ok $note]
    }
    ::ui::buildPicker .picker .hd.targets $groups ::dockyard::build::on ::dockyard::build::save
    .picker.foot.go configure -command {destroy .picker; ::dockyard::build::start}
    count
    focus .picker
    bind .picker <Escape> {destroy .picker}
}

# Builds the program of each selected target into build/TARGET/ of the
# project, and shows the result in the status bar and in the app list.
proc ::dockyard::build::start {} {
    variable on
    variable status
    if {![file exists /main.tcl]} {
        set status "The project has no main.tcl yet."
        ::dockyard::ui::status build error danger $status danger
        return
    }
    set done {}
    set failed {}
    set todo {}
    foreach {target ok} [targets] {
        if {$ok && [info exists on($target)] && $on($target)} {lappend todo $target}
    }
    set i 0
    foreach target $todo {
        incr i
        set status "Building $target"
        ::dockyard::ui::status build build warn "Building [targetName $target] ($i of [llength $todo])" warn
        .hd.build configure -text "Building" -state disabled
        update idletasks
        if {[catch {run $target} res]} {
            lappend failed $target
            .preview.log write "Build of $target: $res\r\n"
        } else {
            lappend done $target
        }
    }
    .hd.build configure -text "Build" -state normal
    if {$done eq "" && $failed eq ""} {
        set status "Select a target."
        ::dockyard::ui::status build build muted "Select a target"
        picker
    } elseif {$failed eq ""} {
        set status "Built: [join $done {, }]"
        ::dockyard::ui::status build check ok "Built [join [lmap t $done {targetName $t}] {, }] at [clock format [clock seconds] -format %H:%M]"
    } else {
        set status "Failed: [join $failed {, }]"
        ::dockyard::ui::status build error danger "Build failed: [join [lmap t $failed {targetName $t}] {, }]" danger
        ::dockyard::ui::toggleConsole 1
    }
    catch {::dockyard::activity::note build [list status $status]}
    ::dockyard::apps::fill
}

# The Apps view: a card for each app next to the project, with its
# programs. `rows` has an entry for each app and each program.
namespace eval ::dockyard::apps {
    variable rows {}
}

proc ::dockyard::apps::show {} {
    ::dockyard::ui::go apps
}

proc ::dockyard::apps::openApp {path} {
    if {$path eq $::dockyard::project} {
        ::dockyard::ui::go workspace
        return
    }
    ::dockyard::apps::spawn $::dockyard::runner $path
}

proc ::dockyard::apps::fill {} {
    variable rows
    if {[winfo ismapped .appsview] == 0 && $::dockyard::ui::view ne "apps"} return
    foreach c [winfo children .appsview.grid] {destroy $c}
    set rows {}
    if {[catch {::dockyard::apps::scan} apps]} {
        .appsview.h.d configure -text $apps
        return
    }
    .appsview.h.d configure -text "[llength $apps] [expr {[llength $apps] == 1 ? "app" : "apps"}] in [file dirname [::dockyard::ui::folder]]"
    set i 0
    foreach app $apps {
        lassign $app name path builds
        lappend rows [list app $path]
        set progs {}
        foreach b $builds {
            lassign $b target file size
            lappend rows [list program $file $path]
            set os [lindex [split $target -] 1]
            lappend progs [list $os [::dockyard::build::targetName $target] [format "%.1f MB" [expr {$size / 1048576.0}]] \
                [list ::dockyard::apps::launch $file]]
        }
        set w .appsview.grid.c$i
        ::ui::appCard $w $name $path $progs [expr {$builds eq "" ? "Not built" : "[llength $builds] [expr {[llength $builds] == 1 ? "program" : "programs"}]"}] \
            [expr {$path eq $::dockyard::project}] [list ::dockyard::apps::openApp $path]
        grid $w -row [expr {$i / 3}] -column [expr {$i % 3}] -sticky nsew -padx {0 12} -pady {0 12}
        incr i
    }
    if {$i == 0} {
        ::ui::emptyState .appsview.grid.empty apps "No apps yet" "An app is a folder with main.tcl next to this project. Build makes its programs."
        grid .appsview.grid.empty -row 0 -column 0 -columnspan 3 -pady 60
    }
    grid columnconfigure .appsview.grid {0 1 2} -weight 1 -uniform c
}

proc ::dockyard::apps::launch {file} {
    if {[catch {::dockyard::apps::spawn $file} err]} {
        ::dockyard::ui::status build error danger $err danger
    } else {
        ::dockyard::ui::status build play ok "Started [file tail $file]" ok
    }
}

# The shortcuts. The terminal gets the keys first, so each binding on
# .term ends with break, and the same binding on all serves the other
# widgets.
foreach {seq cmd} {
    <Control-Key-1> {::dockyard::ui::go workspace}
    <Control-Key-2> {::dockyard::ui::go activity}
    <Control-Key-3> {::dockyard::ui::go apps}
    <Control-Shift-Key-B> ::dockyard::build::start
    <Control-Shift-Key-T> ::dockyard::build::picker
    <Control-Shift-Key-R> ::dockyard::preview::restart
    <Control-Key-grave> ::dockyard::ui::toggleConsole
} {
    bind .term $seq "$cmd; break"
    bind all $seq $cmd
}
bind all <Escape> {+if {[winfo exists .picker]} {destroy .picker}}
