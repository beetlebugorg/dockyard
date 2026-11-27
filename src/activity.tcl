# The Activity view (docs/dev/design.md): each action of the agent
# program, for an audit. The events come from the log of the monitor
# (`dockyard::monitor read`, the same file that `dockyard --monitor`
# reads), every 250 ms. A UserPromptSubmit hook starts a turn, and the
# events after it go into that turn.
#
# The timeline is a canvas that renders only the rows in view. The
# events stay in lists: `events` (the dicts), `kinds` (the kind of each
# event), `turns` (its turn), and `texts` (a lowercase text for the
# search). A change of the filter, the search, or a fold makes `rows`,
# a list of row entries ({turn N} or {event I}), and no widgets. A
# scroll or a change deletes the canvas items and makes the items of
# the rows in view again.

namespace eval ::dockyard::activity {
    variable offset 0
    variable events {}
    variable kinds {}
    variable turns {}
    variable texts {}
    variable prompts {}
    variable rows {}
    variable top 0
    variable selected -1
    variable kind all
    variable query ""
    variable range "All"
    variable folded {}
    variable counts
    variable pending ""
    variable start [clock milliseconds]
    variable rowh 30
}

# The kind of an event for the filter: prompt, tool, exec, file, net,
# blocked, dns, build, or other.
proc ::dockyard::activity::kindOf {e} {
    switch -- [dict get $e kind] {
        hook {
            set ev [expr {[dict exists $e event] ? [dict get $e event] : ""}]
            if {$ev eq "UserPromptSubmit"} {return prompt}
            if {$ev in {PreToolUse PostToolUse}} {
                if {[dict exists $e tool] && [dict get $e tool] eq "Bash"} {return exec}
                if {[dict exists $e tool] && [dict get $e tool] in {Read Write Edit MultiEdit NotebookEdit}} {return file}
                return tool
            }
            return other
        }
        exec {return exec}
        file {return file}
        net {return [expr {[dict exists $e result] && [dict get $e result] eq "blocked" ? "blocked" : "net"}]}
        dns {return dns}
        build {return build}
    }
    return other
}

# The text of a row: the kind name, the summary, and the badge.
proc ::dockyard::activity::summary {e k} {
    set f [dict create {*}$e]
    set get {apply {{f n} {expr {[dict exists $f $n] ? [dict get $f $n] : ""}}}}
    switch -- [dict get $f kind] {
        hook {
            # A tool of an MCP server has the name mcp__SERVER__TOOL.
            regsub {^mcp__[^_]+__} [{*}$get $f tool] "" tool
            set arg ""
            foreach n {path command pattern url prompt} {
                if {[{*}$get $f $n] ne ""} {set arg [{*}$get $f $n]; break}
            }
            set badge [expr {[{*}$get $f event] eq "PostToolUse" ? "done" : [{*}$get $f event] eq "PreToolUse" ? "" : [{*}$get $f event]}]
            if {[dict exists $f exit]} {set badge "exit [dict get $f exit]"}
            return [list [string trim "$tool [string map {/work/ {}} $arg]"] $badge]
        }
        exec {
            set badge [expr {[dict exists $f exit] ? "exit [dict get $f exit]" : "pid [{*}$get $f pid]"}]
            return [list [join [{*}$get $f argv]] $badge]
        }
        exit {return [list "end of [{*}$get $f pid]" ""]}
        file {return [list "[{*}$get $f op] [{*}$get $f path]" ""]}
        net {
            set badge [expr {$k eq "blocked" ? "blocked" : [format "%.1f KB" [expr {([{*}$get $f up] + 0 + [{*}$get $f down] + 0) / 1024.0}]]}]
            return [list "[{*}$get $f host]:[{*}$get $f port]" $badge]
        }
        dns {return [list [{*}$get $f name] [{*}$get $f answer]]}
        build {return [list [{*}$get $f status] ""]}
        share {return [list "[{*}$get $f op] [{*}$get $f name]" ""]}
        rule {return [list "[{*}$get $f rule] [{*}$get $f host]" ""]}
    }
    return [list [string range $e 0 120] ""]
}

# Reads the events of the log since the last read, every 250 ms.
proc ::dockyard::activity::poll {} {
    variable offset
    if {![catch {::dockyard::monitor read $offset} r]} {
        lassign $r offset lines
        add $lines
    }
    after 250 ::dockyard::activity::poll
}

# Adds events (dicts) to the lists, and makes the rows again.
proc ::dockyard::activity::add {lines} {
    variable events
    variable kinds
    variable turns
    variable texts
    variable prompts
    variable counts
    set added 0
    foreach e $lines {
        if {[catch {dict size $e}] || ![dict exists $e kind] || ![dict exists $e time]} continue
        set k [kindOf $e]
        if {$k eq "prompt"} {
            lappend prompts [list [llength $events] [expr {[dict exists $e prompt] ? [dict get $e prompt] : ""}] [dict get $e time]]
        }
        lappend events $e
        lappend kinds $k
        lappend turns [llength $prompts]
        lappend texts [string tolower [join [summary $e $k]]]
        incr counts($k)
        incr counts(all)
        status $e $k
        incr added
    }
    if {$added} refilter
}

# The status bar shows the last tool of the agent and the count of the
# blocked attempts.
proc ::dockyard::activity::status {e k} {
    variable counts
    if {[dict get $e kind] eq "hook" && [dict exists $e event] && [dict get $e event] eq "PreToolUse"} {
        ::dockyard::ui::status agent bolt accent "Agent: [lindex [summary $e $k] 0]" accent
    }
    if {$k eq "blocked"} {
        if {![winfo exists .sb.blocked]} {
            ::ui::statusItem .sb.blocked blocked danger "" danger
            pack .sb.blocked -side right -padx {18 0}
            foreach w {.sb.blocked .sb.blocked.t .sb.blocked.i} {
                bind $w <ButtonPress-1> {::dockyard::activity::filter blocked; ::dockyard::ui::go activity}
            }
        }
        .sb.blocked.t configure -text "$counts(blocked) blocked"
    }
}

proc ::dockyard::activity::note {kind d} {
    catch {::dockyard::monitor log [dict merge [list kind $kind time [clock milliseconds]] $d]}
}

# Makes the list of rows from the filter, the search, the time range,
# and the folds.
proc ::dockyard::activity::refilter {} {
    variable events
    variable kinds
    variable turns
    variable texts
    variable rows
    variable kind
    variable query
    variable range
    variable folded
    variable start
    variable prompts
    set q [string tolower [string trim $query]]
    set since [dict get [list "This session" $start "Last hour" [expr {[clock milliseconds] - 3600000}] \
        "Today" [expr {[clock scan [clock format [clock seconds] -format %Y-%m-%d] -format %Y-%m-%d] * 1000}] "All" 0] $range]
    set rows {}
    set last -1
    set i 0
    foreach e $events k $kinds t $turns x $texts {
        if {($kind eq "all" || $k eq $kind) && ($q eq "" || [string first $q $x] >= 0) && [dict get $e time] >= $since} {
            if {$t != $last} {
                lappend rows [list turn $t]
                set last $t
            }
            if {$k ne "prompt" && $t ni $folded} {lappend rows [list event $i]}
        }
        incr i
    }
    counts
    render
}

proc ::dockyard::activity::counts {} {
    variable counts
    foreach {k t} {all All prompt Prompts tool Tools exec Commands file Files net Network blocked Blocked build Builds} {
        set n [expr {[info exists counts($k)] ? $counts($k) : 0}]
        .activity.bar.k.$k configure -text "$t $n"
    }
    set n [expr {[info exists counts(all)] ? $counts(all) : 0}]
    .activity.list.foot.t configure -text "[fmt $n] events in the log. The log has no signed records on this system."
}

# 37413 gives 37,413.
proc ::dockyard::activity::fmt {n} {
    regsub -all {\d(?=(\d{3})+$)} $n {&,}
}

proc ::dockyard::activity::filter {k} {
    variable kind $k
    refilter
}

# Renders the rows in view, from row `top`.
proc ::dockyard::activity::render {} {
    variable rows
    variable top
    variable rowh
    variable events
    variable kinds
    variable selected
    variable prompts
    set c .activity.list.c
    $c delete all
    set h [winfo height $c]
    set w [winfo width $c]
    set n [expr {$h / $rowh + 2}]
    set max [expr {max(0, [llength $rows] - $h / $rowh)}]
    if {$top > $max} {set top $max}
    if {$top < 0} {set top 0}
    if {[llength $rows] == 0} {
        place .activity.list.empty -relx 0.5 -rely 0.4 -anchor center
    } else {
        place forget .activity.list.empty
    }
    set fg [::ui::color fg]
    set muted [::ui::color muted]
    set faint [::ui::color faint]
    for {set r $top} {$r < min([llength $rows], $top + $n)} {incr r} {
        set y [expr {($r - $top) * $rowh}]
        lassign [lindex $rows $r] type id
        if {$type eq "turn"} {
            $c create rectangle 6 [expr {$y + 2}] [expr {$w - 6}] [expr {$y + $rowh - 2}] -fill [::ui::color sunken] -outline "" -tags [list row r$r]
            set p [expr {$id > 0 ? [lindex $prompts [expr {$id - 1}]] : {}}]
            set text [expr {$id > 0 ? "You asked: [lindex $p 1]" : "Before the first prompt"}]
            $c create image 18 [expr {$y + $rowh / 2}] -image [::ui::icon prompt accent] -anchor w -tags [list row r$r]
            $c create text 40 [expr {$y + $rowh / 2}] -text [string range [string map {\n " "} $text] 0 110] -anchor w -fill $fg -font {TkDefaultFont 10} -tags [list row r$r]
            if {$id > 0} {
                $c create text [expr {$w - 40}] [expr {$y + $rowh / 2}] -text "Turn $id  ·  [clock format [expr {[lindex $p 2] / 1000}] -format %H:%M:%S]" -anchor e -fill $faint -font {TkDefaultFont 9} -tags [list row r$r]
            }
            $c create image [expr {$w - 18}] [expr {$y + $rowh / 2}] -image [::ui::icon chevron muted] -tags [list row r$r]
        } else {
            set e [lindex $events $id]
            set k [lindex $kinds $id]
            if {$id == $selected} {
                $c create rectangle 6 [expr {$y + 1}] [expr {$w - 6}] [expr {$y + $rowh - 1}] -fill [::ui::color accentbg] -outline "" -tags [list row r$r]
            }
            lassign [summary $e $k] text badge
            set ic [dict get {tool bolt file file exec terminal net globe dns globe blocked blocked build build prompt prompt other activity} $k]
            set tone [expr {$k eq "blocked" ? "danger" : "muted"}]
            set my [expr {$y + $rowh / 2}]
            $c create text 30 $my -text [clock format [expr {[dict get $e time] / 1000}] -format %H:%M:%S] -anchor w -fill $faint -font {TkFixedFont 9} -tags [list row r$r]
            $c create image 112 $my -image [::ui::icon $ic $tone] -tags [list row r$r]
            $c create text 128 $my -text [dict get {tool Tool file File exec Command net Network dns DNS blocked Blocked build Build other Other prompt Prompt} $k] -anchor w \
                -fill [expr {$k eq "blocked" ? [::ui::color danger] : $muted}] -font {TkDefaultFont 9} -tags [list row r$r]
            $c create text 210 $my -text [string range $text 0 [expr {max(10, ($w - 330) / 7)}]] -anchor w -fill $fg -font {TkFixedFont 9} -tags [list row r$r]
            if {$badge ne ""} {
                $c create text [expr {$w - 16}] $my -text $badge -anchor e -font {TkDefaultFont 9} -tags [list row r$r] \
                    -fill [expr {$badge eq "blocked" || [string match {exit [1-9]*} $badge] ? [::ui::color danger] : [string match {exit 0} $badge] ? [::ui::color ok] : $muted}]
            }
        }
    }
    set total [llength $rows]
    if {$total == 0} {
        .activity.list.sb set 0 1
    } else {
        .activity.list.sb set [expr {double($top) / $total}] [expr {min(1.0, double($top + $h / $rowh) / $total)}]
    }
}

proc ::dockyard::activity::yview {args} {
    variable top
    variable rows
    variable rowh
    set page [expr {max(1, [winfo height .activity.list.c] / $rowh - 1)}]
    switch -- [lindex $args 0] {
        moveto {set top [expr {int([lindex $args 1] * [llength $rows])}]}
        scroll {
            lassign $args - n unit
            set top [expr {$top + ($unit eq "pages" ? int($n) * $page : int($n))}]
        }
    }
    render
}

proc ::dockyard::activity::click {y} {
    variable rows
    variable top
    variable rowh
    variable folded
    variable selected
    set r [expr {$top + int($y) / $rowh}]
    if {$r >= [llength $rows]} return
    lassign [lindex $rows $r] type id
    if {$type eq "turn"} {
        if {$id in $folded} {
            set folded [lsearch -all -inline -not -exact $folded $id]
        } else {
            lappend folded $id
        }
        refilter
        return
    }
    set selected $id
    render
    detail $id
}

# The detail card of event i: the title, a banner for a blocked event,
# the fields, and Allow.
proc ::dockyard::activity::detail {i} {
    variable events
    variable kinds
    variable turns
    variable prompts
    set e [lindex $events $i]
    set k [lindex $kinds $i]
    set d .activity.detail
    foreach c [winfo children $d] {destroy $c}
    frame $d.h
    ztk::class $d.h add plain
    set ic [dict get {tool bolt file file exec terminal net globe dns globe blocked blocked build build prompt prompt other activity} $k]
    ttk::label $d.h.i -image [::ui::icon $ic [expr {$k eq "blocked" ? "danger" : "fg"}]]
    label $d.h.t -text [dict get {tool "Tool call" file "File" exec "Command" net "Connection" dns "DNS query" blocked "Blocked connection" build "Build" prompt "Prompt" other "Event"} $k] -font {TkDefaultFont 15 bold}
    pack $d.h.i -side left -padx {0 8}
    pack $d.h.t -side left
    pack $d.h -fill x
    if {$k eq "blocked"} {
        frame $d.ban -padx 12 -pady 10
        ztk::class $d.ban add banner
        label $d.ban.t -text "[dict get $e host] is not on the allow list of the sandbox. The proxy closed the connection." -wraplength 380 -justify left -anchor w
        ztk::class $d.ban.t add danger
        pack $d.ban.t -fill x
        pack $d.ban -fill x -pady {12 0}
    }
    frame $d.f
    ztk::class $d.f add plain
    set t [lindex $turns $i]
    set fields [list Time [clock format [expr {[dict get $e time] / 1000}] -format "%Y-%m-%d %H:%M:%S"].[format %03d [expr {[dict get $e time] % 1000}]]]
    if {$t > 0} {lappend fields Turn "$t: [string range [lindex $prompts [expr {$t - 1}] 1] 0 60]"}
    dict for {key v} $e {
        if {$key in {kind time type}} continue
        lappend fields [string totitle $key] [string range [expr {$key eq "argv" ? [join $v] : $v}] 0 300]
    }
    if {![dict exists $e exit] && $k eq "exec"} {lappend fields "Exit code" "not recorded"}
    if {$k eq "file" && ![dict exists $e diff]} {lappend fields Diff "not recorded"}
    lappend fields Record "not signed"
    set r 0
    foreach {key v} $fields {
        label $d.f.k$r -text $key -anchor nw
        ztk::class $d.f.k$r add muted
        label $d.f.v$r -text $v -anchor w -justify left -wraplength 300
        grid $d.f.k$r -row $r -column 0 -sticky nw -pady 3
        grid $d.f.v$r -row $r -column 1 -sticky w -padx {16 0} -pady 3
        incr r
    }
    pack $d.f -fill x -pady {12 0}
    if {[dict exists $e output] || [dict exists $e diff]} {
        set out [expr {[dict exists $e diff] ? [dict get $e diff] : [dict get $e output]}]
        text $d.out -height 10 -wrap none -font TkFixedFont
        ztk::class $d.out add code
        $d.out insert end $out
        $d.out configure -state disabled
        pack $d.out -fill both -expand 1 -pady {12 0}
    }
    if {$k eq "blocked" && [info exists ::dockyard::sandbox] && $::dockyard::sandbox ne ""} {
        ttk::button $d.allow -text "Allow [dict get $e host]" -style Ghost.TButton -command [list ::dockyard::activity::allow [dict get $e host]]
        pack $d.allow -side bottom -anchor w
    }
}

proc ::dockyard::activity::allow {host} {
    set ok [tk_messageBox -parent . -type okcancel -icon warning -title "Allow $host" \
        -message "Allow connections to $host?" \
        -detail "The guest can then send data to $host. The rule goes to the rules file of the project, and the log records it."]
    if {$ok ne "ok"} return
    ::dockyard::monitor rule allow $host
}

# Export: JSON lines or a Markdown report of the rows of the filter, in
# .dockyard/ of the project.
proc ::dockyard::activity::json {v} {
    if {[string is double -strict $v]} {return $v}
    return "\"[string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $v]\""
}

proc ::dockyard::activity::export {format} {
    variable rows
    variable events
    variable kinds
    variable prompts
    set stamp [clock format [clock seconds] -format %Y%m%d-%H%M%S]
    file mkdir /.dockyard
    set name /.dockyard/activity-$stamp.[expr {$format eq "jsonl" ? "jsonl" : "md"}]
    set f [open $name w]
    if {$format ne "jsonl"} {puts $f "# Activity of [file tail $::dockyard::project]\n"}
    foreach row $rows {
        lassign $row type id
        if {$type eq "turn"} {
            if {$format ne "jsonl"} {
                puts $f "\n## Turn $id\n"
                if {$id > 0} {puts $f "> [lindex $prompts [expr {$id - 1}] 1]\n"}
                puts $f "| Time | Kind | Action | Result |\n|---|---|---|---|"
            }
            continue
        }
        set e [lindex $events $id]
        if {$format eq "jsonl"} {
            puts $f "\{[join [lmap {k v} $e {string cat [json $k] : [json $v]}] ,]\}"
        } else {
            lassign [summary $e [lindex $kinds $id]] text badge
            puts $f "| [clock format [expr {[dict get $e time] / 1000}] -format %H:%M:%S] | [lindex $kinds $id] | `[string map {| \\|} $text]` | $badge |"
        }
    }
    close $f
    ::dockyard::ui::status build export muted "Exported .dockyard/[file tail $name]"
}

# The view.
proc ::dockyard::activity::build {} {
    set w .activity
    frame $w.bar
    ztk::class $w.bar add body
    entry $w.bar.q -width 26 -placeholder "Search commands, files, hosts (Ctrl+F)" -textvariable ::dockyard::activity::query
    ztk::class $w.bar.q add search
    bind $w.bar.q <KeyRelease> {
        after cancel $::dockyard::activity::pending
        set ::dockyard::activity::pending [after 120 ::dockyard::activity::refilter]
    }
    pack $w.bar.q -side left
    frame $w.bar.k
    ztk::class $w.bar.k add body
    foreach k {all prompt tool exec file net blocked build} {
        radiobutton $w.bar.k.$k -text $k -variable ::dockyard::activity::kind -value $k -indicatoron 0 -command ::dockyard::activity::refilter
        ztk::class $w.bar.k.$k add segmented
        pack $w.bar.k.$k -side left
    }
    pack $w.bar.k -side left -padx 12
    ttk::menubutton $w.bar.x -text "Export" -image [::ui::icon export fg] -compound left
    menu $w.bar.x.m -tearoff 0
    $w.bar.x.m add command -label "JSON lines" -command {::dockyard::activity::export jsonl}
    $w.bar.x.m add command -label "Report (Markdown)" -command {::dockyard::activity::export md}
    $w.bar.x configure -menu $w.bar.x.m
    ttk::combobox $w.bar.t -values {"This session" "Last hour" "Today" "All"} -width 14 -state readonly \
        -textvariable ::dockyard::activity::range
    bind $w.bar.t <<ComboboxSelected>> ::dockyard::activity::refilter
    pack $w.bar.x $w.bar.t -side right -padx {8 0}
    grid $w.bar -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 12}

    ::ui::card $w.list
    ::ui::card $w.detail
    $w.detail configure -padx 16 -pady 14
    grid $w.list -row 1 -column 0 -sticky nsew
    grid $w.detail -row 1 -column 1 -sticky nsew -padx {12 0}
    grid columnconfigure $w 0 -weight 3 -uniform a
    grid columnconfigure $w 1 -weight 2 -uniform a
    grid rowconfigure $w 1 -weight 1

    frame $w.list.foot -padx 12 -pady 8
    ztk::class $w.list.foot add consolebar
    ttk::label $w.list.foot.i -image [::ui::icon shield muted]
    label $w.list.foot.t -text ""
    ztk::class $w.list.foot.t add muted
    pack $w.list.foot.i -side left -padx {0 6}
    pack $w.list.foot.t -side left
    pack $w.list.foot -side bottom -fill x -padx 1 -pady {0 1}
    canvas $w.list.c -highlightthickness 0 -background [::ui::color surface] -yscrollcommand {}
    ttk::scrollbar $w.list.sb -orient vertical -command ::dockyard::activity::yview
    pack $w.list.sb -side right -fill y -pady 6
    pack $w.list.c -fill both -expand 1 -pady {6 0}
    ::ui::emptyState $w.list.empty activity "No activity yet" \
        "Each prompt, tool call, command, file change, connection, and build of the agent shows here."
    $w.list.empty configure -background [::ui::color surface]
    bind $w.list.c <Configure> ::dockyard::activity::render
    bind $w.list.c <MouseWheel> {::dockyard::activity::yview scroll [expr {%D > 0 ? -3 : 3}] units}
    bind $w.list.c <ButtonPress-1> {::dockyard::activity::click %y}
    ::ui::emptyState $w.detail.empty activity "Select an event" "The detail of an event shows here: its fields, its output, and its turn."
    $w.detail.empty configure -background [::ui::color surface]
    pack $w.detail.empty -expand 1
    bind all <Control-Key-f> {if {$::dockyard::ui::view eq "activity"} {focus .activity.bar.q}}
}

proc ::dockyard::activity::shown {} {
    after idle ::dockyard::activity::render
}

::dockyard::activity::build
::dockyard::activity::refilter
::dockyard::activity::poll
# `--view NAME` opens a view at the start.
if {[info exists ::dockyard::view] && $::dockyard::view in {activity apps}} {
    after idle [list ::dockyard::ui::go $::dockyard::view]
}
