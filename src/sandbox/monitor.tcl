# The sandbox monitor (issue 15): `dockyard --monitor PROJECT` shows
# the audit log of the project (`docs/dev/audit.md`) as a live
# timeline. With `--tui` it writes the timeline to the terminal, with
# colors. The dockyard window writes the log (`dockyard::audit`): the
# sessions and the turns of the agent program, its tool calls, the
# programs of the guest, the calls of the egress proxy, the changes of
# the project folder, and the shares. A rule (allow or block a host)
# goes to the rules file, and the dockyard window gives it to the proxy.

namespace eval ::dockyard::monitor {
    variable last 0
    variable shown {net 1 dns 1 blocked 1 exec 1 exit 0 turn 1 tool 1 file 1 share 1 rule 1 session 1 build 1 note 1}
    variable filter ""
    variable blocked {}
    variable events {}
}

proc ::dockyard::monitor::Get {d key} {
    return [expr {[dict exists $d $key] ? [dict get $d $key] : ""}]
}

# The text of one record, and its tag: blocked, allowed, exec, hook, file, or note.
proc ::dockyard::monitor::describe {e} {
    set t [clock format [expr {[dict get $e time] / 1000}] -format %H:%M:%S]
    set d [dict get $e data]
    set k [dict get $e kind]
    switch -- $k {
        net {
            set r [Get $d result]
            set what "[Get $d host]:[Get $d port]"
            if {$r eq "allowed"} {
                append what "  up [Get $d up] B, down [Get $d down] B, [Get $d ms] ms"
            }
            return [list "$t  net   [format %-8s $r] $what" [expr {$r eq "allowed" ? "allowed" : "blocked"}]]
        }
        dns {
            set r [Get $d result]
            return [list "$t  dns   [format %-8s $r] [Get $d name] [Get $d type]" [expr {$r eq "allowed" ? "allowed" : "blocked"}]]
        }
        blocked {return [list "$t  block [Get $d what] [Get $d target]" blocked]}
        exec {return [list "$t  exec  [Get $d pid]  [join [Get $d argv]]" exec]}
        exit {return [list "$t  exit  [Get $d pid]  [Get $d code]" note]}
        turn {
            set what "turn  [Get $d op]"
            if {[Get $d op] eq "start"} {append what "  [string range [Get $d prompt] 0 200]"}
            return [list "$t  $what" hook]
        }
        tool {
            # The tool and the first field of the tool input.
            set what "tool  [Get $d op] [Get $d tool]"
            set in [Get $d input]
            if {[dict size $in] > 0} {append what "  [lindex $in 1]"}
            return [list "$t  $what" hook]
        }
        file {return [list "$t  file  [Get $d op] [Get $d path]" file]}
        share {return [list "$t  share [Get $d op] [Get $d name]" note]}
        rule {return [list "$t  rule  [Get $d op] [Get $d host]" note]}
        session {return [list "$t  session [Get $d op] [join [Get $d argv]][Get $d exit]" note]}
        build {return [list "$t  build [Get $d op] [Get $d targets] [Get $d ok]" note]}
        note {return [list "$t  note  [Get $d text]" note]}
    }
    return [list "$t  $k $d" note]
}

proc ::dockyard::monitor::visible {e} {
    variable shown
    variable filter
    set k [dict get $e kind]
    if {[dict exists $shown $k] && ![dict get $shown $k]} {return 0}
    if {$filter ne "" && [string first [string tolower $filter] [string tolower [lindex [describe $e] 0]]] < 0} {return 0}
    return 1
}

# Reads the new records of the log every 250 ms: at the start the last
# 10,000, then the records after the last seq.
proc ::dockyard::monitor::poll {} {
    variable last
    variable events
    if {$last == 0} {
        set recs [::dockyard::audit query -last 10000]
    } else {
        set recs [::dockyard::audit query -after $last]
    }
    foreach r $recs {
        set last [dict get $r seq]
        lappend events $r
        show $r
    }
    if {[llength $events] > 20000} {set events [lrange $events end-9999 end]}
    after 250 ::dockyard::monitor::poll
}

# The terminal view: one colored line for each event.
proc ::dockyard::monitor::tuiShow {e} {
    if {![visible $e]} return
    lassign [describe $e] text tag
    set color [dict get {blocked 31 allowed 32 exec 36 hook 35 file 33 note 2} $tag]
    puts "\x1b\[${color}m$text\x1b\[0m"
}

# The window: a filter, the kinds, the timeline, and the tray of the
# blocked hosts with Allow.
proc ::dockyard::monitor::gui {} {
    variable shown
    wm title . "dockyard monitor: [file tail $::dockyard::project]"
    wm geometry . 1000x640
    wm iconphoto . -default [image create photo -data $::dockyard::icon64]
    frame .bar -padx 8 -pady 6
    label .bar.l -text "Filter"
    entry .bar.filter -textvariable ::dockyard::monitor::filter -width 30
    bind .bar.filter <KeyRelease> ::dockyard::monitor::redraw
    pack .bar.l .bar.filter -side left -padx {0 6}
    foreach k {net dns exec exit turn tool file share} {
        set ::dockyard::monitor::on($k) [dict get $shown $k]
        checkbutton .bar.$k -text $k -variable ::dockyard::monitor::on($k) \
            -command [list ::dockyard::monitor::toggle $k]
        pack .bar.$k -side left
    }
    text .log -wrap none -font TkFixedFont -yscrollcommand {.sb set}
    scrollbar .sb -command {.log yview}
    .log tag configure blocked -foreground #c62828
    .log tag configure allowed -foreground #2e7d32
    .log tag configure exec -foreground #00838f
    .log tag configure hook -foreground #6a1b9a
    .log tag configure file -foreground #8d6e00
    .log tag configure note -foreground #777777
    frame .tray -padx 8 -pady 6
    label .tray.title -text "Blocked hosts"
    listbox .tray.hosts -height 12 -width 32
    button .tray.allow -text "Allow" -command ::dockyard::monitor::allowSelected
    pack .tray.title -anchor w
    pack .tray.hosts -fill both -expand 1
    pack .tray.allow -fill x -pady {6 0}
    grid .bar -row 0 -column 0 -columnspan 3 -sticky ew
    grid .log -row 1 -column 0 -sticky nsew
    grid .sb -row 1 -column 1 -sticky ns
    grid .tray -row 1 -column 2 -sticky ns
    grid columnconfigure . 0 -weight 1
    grid rowconfigure . 1 -weight 1
}

proc ::dockyard::monitor::guiShow {e} {
    variable blocked
    if {[dict get $e kind] eq "net" && [Get [dict get $e data] result] eq "blocked"} {
        set h [Get [dict get $e data] host]
        if {$h ni $blocked} {
            lappend blocked $h
            .tray.hosts insert end $h
        }
    }
    if {![visible $e]} return
    lassign [describe $e] text tag
    .log insert end "$text\n" $tag
    .log see end
}

proc ::dockyard::monitor::toggle {k} {
    variable shown
    dict set shown $k $::dockyard::monitor::on($k)
    redraw
}

proc ::dockyard::monitor::redraw {} {
    variable events
    .log delete 1.0 end
    foreach e $events {
        if {![visible $e]} continue
        lassign [describe $e] text tag
        .log insert end "$text\n" $tag
    }
    .log see end
}

proc ::dockyard::monitor::allowSelected {} {
    variable blocked
    set i [.tray.hosts curselection]
    if {$i eq ""} return
    set h [.tray.hosts get $i]
    ::dockyard::monitor rule allow $h
    .tray.hosts delete $i
    set blocked [lsearch -all -inline -not -exact $blocked $h]
}

if {$::dockyard::tui} {
    proc ::dockyard::monitor::show {e} {tuiShow $e}
    puts "dockyard monitor: [::dockyard::audit path]"
} else {
    proc ::dockyard::monitor::show {e} {guiShow $e}
    ::dockyard::monitor::gui
}
::dockyard::monitor::poll
