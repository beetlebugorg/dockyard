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
image create photo ::dockyard::icon -data $::dockyard::icon64
wm iconphoto . -default ::dockyard::icon
image create photo ::dockyard::logo -data $::dockyard::icon20

frame .bar -padx 8 -pady 6
ttk::label .bar.logo -image ::dockyard::logo -padding {0 0 6 0}
label .bar.name -text "dockyard" -font {TkDefaultFont 13 bold}
label .bar.project -text $::dockyard::project
button .bar.build -text "Build" -command ::dockyard::build::start
button .bar.apps -text "Apps" -command ::dockyard::apps::show
label .bar.state -text ""
pack .bar.logo .bar.name -side left
pack .bar.project -side left -padx 12
pack .bar.apps .bar.build -side right -padx {6 0}
if {[info exists ::dockyard::sandbox] && $::dockyard::sandbox ne ""} {
    button .bar.shares -text "Shares" -command ::dockyard::vm::shares
    pack .bar.shares -side right -padx {6 0}
}

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
    if {[info exists ::dockyard::sandbox] && $::dockyard::sandbox ne ""} {after 0 ::dockyard::vm::start; return}
    variable agent
    variable agent_name
    variable shell
    if {$agent ne ""} {
        set cmd [list $agent]
        # npm puts a program on Windows as a batch file, which only the
        # shell runs.
        if {[string match -nocase *.cmd $agent]} {set cmd [list $shell /c $agent]}
    } elseif {$::dockyard::windows} {
        # The console of Windows clears the pane when the shell starts,
        # so the shell writes the advice.
        set lines [list "$agent_name is not on the PATH. This pane runs $shell." \
            "Install it with: npm install -g @anthropic-ai/claude-code" \
            "Then type exit to start it."]
        set cmd [list $shell /k [join [lmap l $lines {string cat "echo " $l}] " & "]]
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
    variable tries 0
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
        if {[info exists ::dockyard::sandbox] && $::dockyard::sandbox ne ""} {::dockyard::vm::fileChange $change}
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
    variable tries
    set delay 33
    if {[catch {
        if {$size ne "" && $size ne $sent} {
            call [list wm geometry . $size]
            set sent $size
            set tries 30
        }
        set n [call ::dockyard::bridge::frames]
        # The child can draw its next frame before the new size is in
        # its layout. So the pane also reads the image again while its
        # size is not the size that the pane sent, 30 times at most.
        set wrong [expr {$sent ne "" && $tries > 0 && [lsearch [image names] ::dockyard::preview::shot] >= 0 &&
            "[image width ::dockyard::preview::shot]x[image height ::dockyard::preview::shot]" ne $sent}]
        if {$wrong} {incr tries -1}
        if {$n != $frames || $wrong} {
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

# The terminal pane in the sandbox (`dockyard --sandbox DIR`, issue 13):
# the program runs on a PTY of a guest of ztcl::vm, over vsock, with the
# project folder at /work. The guest reaches the network only through
# the egress proxy. `sandbox.tcl` has the commands.
namespace eval ::dockyard::vm {
    variable guest ""
    variable session ""
    variable size ""
}

proc ::dockyard::vm::write {text} {.term write $text}

proc ::dockyard::vm::start {} {
    variable guest
    variable session
    set dir $::dockyard::sandbox
    if {$guest eq ""} {
        .term write "\x1b\[2m\[the sandbox starts\]\x1b\[0m\r\n"
        set boot [list -kernel $dir/$::dockyard::sandbox_kernel -initrd $dir/agent.cpio -helper $dir/dockyard-guest -memory 512]
        if {$::dockyard::sandbox_image ne ""} {
            # A signed release: install it when the current release of the
            # store has a different counter, then boot it.
            set current {}
            foreach i [ztcl::vm image list] {
                if {[dict get $i name] eq $::dockyard::sandbox_image} {set current [dict get $i current]}
            }
            if {$current ne $::dockyard::sandbox_counter && [catch {ztcl::vm image install $dir} msg]} {
                .term write "sandbox: $msg\r\n"
                return
            }
            set boot [list -image $::dockyard::sandbox_image -memory 512]
        }
        if {[catch {set guest [::dockyard::sandbox::boot {*}$boot -share {/ /work rw}]} msg opts]} {
            if {[dict get $opts -errorcode] ne "ZTCL VM SHARE"} {
                .term write "sandbox: $msg\r\n"
                return
            }
            # The shares of KVM wait for ztcl (virtio-9p).
            .term write "\x1b\[2m\[this ztcl has no share on this platform: the project folder is not in the guest\]\x1b\[0m\r\n"
            if {[catch {set guest [::dockyard::sandbox::boot {*}$boot]} msg]} {
                .term write "sandbox: $msg\r\n"
                return
            }
        }
        if {[catch {::dockyard::proxy start}]} {}
        ::dockyard::proxy allow $::dockyard::sandbox_allow
        ::dockyard::sandbox::relay $guest
        ::dockyard::sandbox::events $guest ::dockyard::vm::event
        if {[catch {::dockyard::sandbox::hooks $guest /root} msg]} {.term write "sandbox: $msg\r\n"}
        tick
    }
    lassign [.term size] cols rows
    set cwd [expr {[catch {ztcl::vm exec $guest /bin/busybox test -d [::dockyard::sandbox::path $guest /work]} r] || [dict get $r exit] ? "/" : "/work"}]
    set session [::dockyard::sandbox::session $guest -argv $::dockyard::sandbox_argv -cwd $cwd -rows $rows -cols $cols \
        -env [list TERM=xterm-256color HOME=/root PATH=/tools/bin:/bin:/sbin:/usr/bin \
            HTTPS_PROXY=http://127.0.0.1:3128 HTTP_PROXY=http://127.0.0.1:3128] \
        -output ::dockyard::vm::write -exit ::dockyard::vm::ended]
    .term configure -command {} -inputcommand [list ::dockyard::sandbox::input $session]
}

# The size of the grid follows the pane, and the program gets it.
proc ::dockyard::vm::resize {} {
    variable session
    variable size
    if {$session eq ""} return
    set now [.term size]
    if {$now eq $size} return
    set size $now
    lassign $now cols rows
    ::dockyard::sandbox::resize $session $rows $cols
}
bind .term <Configure> {after idle ::dockyard::vm::resize}

proc ::dockyard::vm::ended {code} {
    variable session
    set session ""
    ::dockyard::ended $code
}

# The events of the guest go to the log of the monitor (issue 15,
# `monitor.tcl`), as the calls of the proxy and the file changes do.
proc ::dockyard::vm::event {d} {
    set k [dict get $d type]
    dict unset d type
    log $k $d
}

proc ::dockyard::vm::log {kind d} {
    if {![dict exists $d time]} {dict set d time [clock milliseconds]}
    catch {::dockyard::monitor log [dict merge [list kind $kind] $d]}
}

# Every 250 ms: the events of the proxy go to the log, and the rules of
# the monitor go to the allow list of the proxy.
namespace eval ::dockyard::vm {variable rules {}}
proc ::dockyard::vm::tick {} {
    variable rules
    foreach e [::dockyard::proxy events] {log net $e}
    set now [::dockyard::monitor rules]
    if {$now ne $rules} {
        set rules $now
        set allow $::dockyard::sandbox_allow
        foreach r $rules {
            lassign $r kind host
            set allow [lsearch -all -inline -not -exact $allow $host]
            if {$kind eq "allow"} {lappend allow $host}
            log rule [list rule $kind host $host]
        }
        ::dockyard::proxy allow $allow
    }
    after 250 ::dockyard::vm::tick
}

proc ::dockyard::vm::fileChange {change} {
    variable guest
    if {$guest eq ""} return
    lassign $change op path
    if {[string match /.dockyard* $path]} return
    log file [list op $op path $path]
}

# The sharing panel: a file of the project goes into /inbox of the
# guest with mode 0444, and Revoke removes it. Export copies a file of
# the guest into exports/ of the project. Each step is an event.
proc ::dockyard::vm::shares {} {
    if {[winfo exists .shares]} {raise .shares; return}
    toplevel .shares
    wm title .shares "Sandbox shares"
    frame .shares.add -padx 8 -pady 6
    label .shares.add.l -text "File of the project"
    entry .shares.add.path -width 40 -textvariable ::dockyard::vm::share_path
    button .shares.add.go -text "Share" -command {::dockyard::vm::share $::dockyard::vm::share_path}
    pack .shares.add.l .shares.add.path .shares.add.go -side left -padx {0 6}
    listbox .shares.list -height 10
    frame .shares.ops -padx 8 -pady 6
    button .shares.ops.revoke -text "Revoke" -command ::dockyard::vm::revokeSelected
    label .shares.ops.l -text "File of the guest"
    entry .shares.ops.path -width 30 -textvariable ::dockyard::vm::export_path
    button .shares.ops.export -text "Export" -command {::dockyard::vm::export $::dockyard::vm::export_path}
    pack .shares.ops.revoke .shares.ops.l .shares.ops.path .shares.ops.export -side left -padx {0 6}
    label .shares.state -text "" -anchor w
    pack .shares.add -fill x
    pack .shares.list -fill both -expand 1 -padx 8
    pack .shares.ops -fill x
    pack .shares.state -fill x -padx 8 -pady {0 6}
    foreach n [lsort [array names ::dockyard::vm::shared]] {.shares.list insert end $n}
}

proc ::dockyard::vm::note {text} {
    if {[winfo exists .shares]} {.shares.state configure -text $text}
}

proc ::dockyard::vm::share {path} {
    variable guest
    if {$guest eq ""} {return [note "The sandbox does not run."]}
    if {[catch {
        set f [open $path rb]
        fconfigure $f -translation binary
        set data [read $f]
        close $f
    } msg]} {return [note $msg]}
    set name [file tail $path]
    set r [ztcl::vm exec $guest -binary 1 -stdin $data -- /bin/busybox sh -c \
        {/bin/busybox mkdir -p "$1" && /bin/busybox cat > "$1/$2" && /bin/busybox chmod 444 "$1/$2"} sh [::dockyard::sandbox::path $guest /inbox] $name]
    if {[dict get $r exit] != 0} {return [note "The share failed: [dict get $r stderr]"]}
    if {![info exists ::dockyard::vm::shared($name)] && [winfo exists .shares]} {.shares.list insert end $name}
    set ::dockyard::vm::shared($name) $path
    log share [list op share name $name]
    note "/inbox/$name is in the guest."
}

proc ::dockyard::vm::revokeSelected {} {
    set i [.shares.list curselection]
    if {$i eq ""} return
    revoke [.shares.list get $i]
}

proc ::dockyard::vm::revoke {name} {
    variable guest
    if {$guest ne ""} {ztcl::vm exec $guest -- /bin/busybox rm -f [::dockyard::sandbox::path $guest /inbox]/$name}
    unset -nocomplain ::dockyard::vm::shared($name)
    if {[winfo exists .shares]} {
        set i [lsearch -exact [.shares.list get 0 end] $name]
        if {$i >= 0} {.shares.list delete $i}
    }
    log share [list op revoke name $name]
    note "/inbox/$name is not in the guest."
}

proc ::dockyard::vm::export {gpath} {
    variable guest
    if {$guest eq ""} {return [note "The sandbox does not run."]}
    set r [ztcl::vm exec $guest -binary 1 -- /bin/busybox cat [::dockyard::sandbox::path $guest $gpath]]
    if {[dict get $r exit] != 0} {return [note "The export failed: [string trim [dict get $r stderr]]"]}
    file mkdir /exports
    set out /exports/[file tail $gpath]
    set f [open $out wb]
    fconfigure $f -translation binary
    puts -nonewline $f [dict get $r stdout]
    close $f
    log share [list op export name $gpath]
    note "$out has the file."
    return $out
}
