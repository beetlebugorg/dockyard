# The sandbox monitor (issue 15): `dockyard --monitor PROJECT` shows
# the log of the sandbox of the project as a live timeline. With
# `--tui` it writes the timeline to the terminal, with colors. The
# dockyard window writes the log (`dockyard::monitor log`): the calls
# of the egress proxy, allowed and blocked, the programs of the guest,
# the changes of the project folder, and the shares. A rule (allow or
# block a host) goes to the rules file, and the dockyard window gives
# it to the proxy.

namespace eval ::dockyard::monitor {
    variable offset 0
    variable shown {net 1 exec 1 exit 0 hook 1 file 1 share 1 rule 1}
    variable filter ""
    variable blocked {}
    variable events {}
}

# The text of one event, and its tag: blocked, allowed, exec, hook, file, or note.
proc ::dockyard::monitor::describe {e} {
    set t [clock format [expr {[dict get $e time] / 1000}] -format %H:%M:%S]
    switch -- [dict get $e kind] {
        net {
            set r [dict get $e result]
            set what "[dict get $e host]:[dict get $e port]"
            if {$r eq "allowed"} {
                append what "  up [dict get $e up] B, down [dict get $e down] B, [dict get $e ms] ms"
            }
            return [list "$t  net   [format %-8s $r] $what" [expr {$r eq "allowed" ? "allowed" : "blocked"}]]
        }
        exec {return [list "$t  exec  [dict get $e pid]  [join [dict get $e argv]]" exec]}
        exit {return [list "$t  exit  [dict get $e pid]" note]}
        hook {
            # The event, the tool, and the first field of the tool input.
            set what [dict get $e event]
            if {[dict exists $e tool]} {append what " [dict get $e tool]"}
            foreach f {path command pattern url prompt} {
                if {[dict exists $e $f]} {
                    append what "  [dict get $e $f]"
                    break
                }
            }
            return [list "$t  hook  $what" hook]
        }
        file {return [list "$t  file  [dict get $e op] [dict get $e path]" file]}
        share {return [list "$t  share [dict get $e op] [dict get $e name]" note]}
        rule {return [list "$t  rule  [dict get $e rule] [dict get $e host]" note]}
    }
    return [list "$t  $e" note]
}

proc ::dockyard::monitor::visible {e} {
    variable shown
    variable filter
    set k [dict get $e kind]
    if {[dict exists $shown $k] && ![dict get $shown $k]} {return 0}
    if {$filter ne "" && [string first [string tolower $filter] [string tolower [lindex [describe $e] 0]]] < 0} {return 0}
    return 1
}

# Reads the new lines of the log every 250 ms.
proc ::dockyard::monitor::poll {} {
    variable offset
    variable events
    lassign [::dockyard::monitor read $offset] offset lines
    foreach l $lines {
        if {[catch {dict size $l}] || ![dict exists $l kind] || ![dict exists $l time]} continue
        lappend events $l
        show $l
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
    foreach k {net exec exit hook file share} {
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
    if {[dict get $e kind] eq "net" && [dict get $e result] eq "blocked"} {
        set h [dict get $e host]
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
    puts "dockyard monitor: [::dockyard::monitor path]"
} else {
    proc ::dockyard::monitor::show {e} {guiShow $e}
    ::dockyard::monitor::gui
}
::dockyard::monitor::poll
