# The mockups of docs/dev/design.md. tools/mockups.sh runs this script
# in the preview child of dockyard (`dockyard --run`) on the headless
# backend, once for each view and each color scheme. The file view.txt
# next to the script names the view: main, build, apps, activity, or
# first. The widgets show sample data only. src/ui.tcl has the real
# window.

set f [open /view.txt]
set view [string trim [read $f]]
close $f
source /ui-icons.tcl
source /icon.tcl
source /theme.tcl

# The Activity view with sample events of two turns, and the detail of
# a blocked connection.
proc ui::activityMock {w} {
    frame $w -padx 16 -pady 12
    ztk::class $w add body
    frame $w.bar
    ztk::class $w.bar add body
    entry $w.bar.q -width 26 -placeholder "Search commands, files, hosts (Ctrl+F)"
    ztk::class $w.bar.q add search
    pack $w.bar.q -side left
    frame $w.bar.k
    ztk::class $w.bar.k add body
    set ::ui::kind all
    foreach {k t} {all "All 214" prompt "Prompts 3" tool "Tools 41" exec "Commands 23" file "Files 96" net "Network 48" blocked "Blocked 1" build "Builds 2"} {
        radiobutton $w.bar.k.$k -text $t -variable ::ui::kind -value $k -indicatoron 0
        ztk::class $w.bar.k.$k add segmented
        pack $w.bar.k.$k -side left
    }
    pack $w.bar.k -side left -padx 12
    ttk::button $w.bar.x -text "Export" -image [ui::icon export fg] -compound left -style Ghost.TButton
    ttk::combobox $w.bar.t -values {"This session" "Last hour" "Today" "All"} -width 14 -state readonly
    $w.bar.t set "This session"
    pack $w.bar.x $w.bar.t -side right -padx {8 0}
    grid $w.bar -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 12}

    ui::card $w.list
    ui::card $w.detail
    grid $w.list -row 1 -column 0 -sticky nsew
    grid $w.detail -row 1 -column 1 -sticky nsew -padx {12 0}
    grid columnconfigure $w 0 -weight 3 -uniform a
    grid columnconfigure $w 1 -weight 2 -uniform a
    grid rowconfigure $w 1 -weight 1

    set i 0
    foreach {type a b c d} {
        turn 3 "Make the total bigger, and fetch the exchange rates." "14:02:11" "9 actions"
        ev 14:02:12 tool "Read" "main.tcl"
        ev 14:02:14 file "Edit main.tcl" "+6 −2"
        ev 14:02:15 exec "tclsh check.tcl" "exit 0"
        ev 14:02:19 net "registry.npmjs.org:443" "4.4 KB"
        ev 14:02:20 dns "example.com" "A 93.184.215.14"
        sel 14:02:21 blocked "example.com:443" "blocked"
        ev 14:02:24 tool "screenshot" "380×260"
        ev 14:02:30 build "Build Linux x86-64" "1.9 MB"
        turn 2 "Make a tip calculator: the bill, a slider for the tip, and the total." "13:58:40" "6 actions"
        ev 13:58:44 file "Write main.tcl" "+38"
        ev 13:58:45 tool "errors" "no errors"
        ev 13:58:47 tool "type .bill" "84.00"
    } {
        set r $w.list.r$i
        if {$type eq "turn"} {
            frame $r -padx 10 -pady 8
            ztk::class $r add turn
            ttk::label $r.i -image [ui::icon prompt accent]
            label $r.t -text "You asked: $b" -anchor w
            label $r.n -text "Turn $a  ·  $c  ·  $d"
            ztk::class $r.n add faint
            ttk::label $r.c -image [ui::icon chevron muted]
            pack $r.i -side left -padx {0 8}
            pack $r.c -side right
            pack $r.n -side right -padx 8
            pack $r.t -side left -fill x -expand 1
            pack $r -fill x -padx 8 -pady {8 2}
        } else {
            frame $r -padx 10 -pady 5
            ztk::class $r add [expr {$type eq "sel" ? "selected" : "row"}]
            set kind $b
            set ic [dict get {tool bolt file file exec terminal net globe dns globe blocked blocked build build} $kind]
            set tone [expr {$kind eq "blocked" ? "danger" : "muted"}]
            label $r.time -text $a
            ztk::class $r.time add monomuted
            ttk::label $r.i -image [ui::icon $ic $tone]
            label $r.k -text [dict get {tool Tool file File exec Command net Network dns DNS blocked Blocked build Build} $kind] -width 9 -anchor w
            ztk::class $r.k add [expr {$kind eq "blocked" ? "danger" : "muted"}]
            label $r.t -text $c -anchor w
            ztk::class $r.t add mono
            label $r.b -text $d
            ztk::class $r.b add [dict get {tool badge file badgeaccent exec badgeok net badge dns badge blocked badgedanger build badgeok} $kind]
            pack $r.time -side left -padx {22 10}
            pack $r.i -side left -padx {0 8}
            pack $r.k -side left
            pack $r.b -side right
            pack $r.t -side left -fill x -expand 1
            pack $r -fill x -padx 8 -pady 1
        }
        incr i
    }
    frame $w.list.foot -padx 12 -pady 8
    ztk::class $w.list.foot add consolebar
    ttk::label $w.list.foot.i -image [ui::icon shieldcheck ok]
    label $w.list.foot.t -text "Log intact: 214 events, 214 signed records checked"
    ztk::class $w.list.foot.t add ok
    label $w.list.foot.n -text "Showing turns 2 and 3 of 3"
    ztk::class $w.list.foot.n add faint
    pack $w.list.foot.i -side left -padx {0 6}
    pack $w.list.foot.t -side left
    pack $w.list.foot.n -side right
    pack $w.list.foot -side bottom -fill x -padx 1 -pady {0 1}

    # The detail of the selected event.
    set d $w.detail
    $d configure -padx 16 -pady 14
    frame $d.h
    ztk::class $d.h add card
    $d.h configure -borderwidth 0
    ttk::label $d.h.i -image [ui::icon blocked danger]
    label $d.h.t -text "Blocked connection" -font {TkDefaultFont 15 bold}
    pack $d.h.i -side left -padx {0 8}
    pack $d.h.t -side left
    pack $d.h -fill x
    frame $d.ban -padx 12 -pady 10
    ztk::class $d.ban add banner
    label $d.ban.t -text "example.com is not on the allow list of the sandbox. The proxy closed the connection before any byte went out." -wraplength 380 -justify left -anchor w
    ztk::class $d.ban.t add danger
    pack $d.ban.t -fill x
    pack $d.ban -fill x -pady {12 12}
    frame $d.f
    ztk::class $d.f add card
    $d.f configure -borderwidth 0
    set r 0
    foreach {k v} {Time "14:02:21.408" Turn "3: Make the total bigger, and fetch…" Host "example.com" Port 443 "Asked by" "Command 244: wget -q https://example.com/upload" Bytes "0 up, 0 down" Record "Signed by ztcl::meter, checked"} {
        label $d.f.k$r -text $k -anchor w
        ztk::class $d.f.k$r add muted
        label $d.f.v$r -text $v -anchor w
        grid $d.f.k$r -row $r -column 0 -sticky w -pady 3
        grid $d.f.v$r -row $r -column 1 -sticky w -padx {16 0} -pady 3
        incr r
    }
    pack $d.f -fill x
    label $d.ol -text "Output of the command" -anchor w
    ztk::class $d.ol add muted
    pack $d.ol -fill x -pady {14 6}
    frame $d.code -padx 10 -pady 8
    ztk::class $d.code add code
    foreach l {"wget: can't connect to remote host: Connection refused" "exit 1"} {
        label $d.code.l[incr r] -text $l -anchor w
        ztk::class $d.code.l$r add mono
        pack $d.code.l$r -fill x
    }
    pack $d.code -fill x
    frame $d.act
    ztk::class $d.act add card
    $d.act configure -borderwidth 0
    ttk::button $d.act.allow -text "Allow example.com…" -style Ghost.TButton
    ttk::button $d.act.cmd -text "Show the command" -style Ghost.TButton
    pack $d.act.allow $d.act.cmd -side left -padx {0 8}
    pack $d.act -side bottom -fill x
}


wm title . "dockyard"
wm geometry . 1280x800
. configure -background [ui::color bg]

# The header: the logo, the project, the views, and Build.
ui::header .hd tip-calculator "~/Projects/apps/with/a/long/folder/name/for/the/wrap/test/tip-calculator" [expr {$view in {apps activity} ? $view : "workspace"}]
grid .hd -row 0 -column 0 -sticky ew

proc agentPane {w state} {
    ui::card $w
    ui::paneHead $w.head terminal "Agent" "claude" $state
    ui::iconButton $w.head.restart restart "Start the agent again"
    pack $w.head.restart -side right -in $w.head.right
    ztk::terminal $w.term -width 80 -height 30
    ztk::class $w.term add pane
    pack $w.head -fill x
    pack $w.term -fill both -expand 1 -padx {12 4} -pady {0 8}
}

proc writeSession {t} {
    $t write "\x1b\[1m> \x1b\[0mMake a tip calculator: the bill, a slider for the tip, and the total.\r\n\r\n"
    $t write "I write main.tcl with an entry for the bill, a scale for the tip\r\npercent, and two labels for the tip and the total.\r\n\r\n"
    foreach {a b} {Write main.tcl errors "no errors" screenshot "tip calculator, 380x260" type ".bill: 84.00" eval "set ::tip -> 15"} {
        $t write [format "  \x1b\[32m%-11s\x1b\[0m\x1b\[2m%s\x1b\[0m\r\n" $a $b]
    }
    $t write "\r\nThe app works: a bill of 84.00 with a tip of 15% gives 12.60 and\r\na total of 96.60.\r\n\r\n\x1b\[1m> \x1b\[0m"
}

# The preview pane with a sample app in the device frame.
proc previewPane {w mode} {
    ui::card $w
    if {$mode eq "first"} {
        ui::paneHead $w.head play "Preview" "" idle
    } else {
        ui::paneHead $w.head play "Preview" "main.tcl" running
        ui::iconButton $w.head.console console "Console (Ctrl+`)"
        ui::iconButton $w.head.restart restart "Restart (Ctrl+Shift+R)"
        pack $w.head.restart $w.head.console -side right -padx {4 0} -in $w.head.right
    }
    pack $w.head -fill x
    frame $w.stage
    ztk::class $w.stage add stage
    pack $w.stage -fill both -expand 1 -padx 1
    if {$mode eq "first"} {
        ui::emptyState $w.stage.empty logo "Nothing to preview yet" \
            "Ask the agent for an app. It writes main.tcl, and the app runs here after each change."
        frame $w.stage.empty.chips
        ztk::class $w.stage.empty.chips add stage
        foreach {n t} {a "A tip calculator" b "A pomodoro timer" c "A notes app with search"} {
            ttk::button $w.stage.empty.chips.$n -text $t -style Chip.TButton
            pack $w.stage.empty.chips.$n -side left -padx 4
        }
        pack $w.stage.empty.chips -pady {16 0}
        place $w.stage.empty -relx 0.5 -rely 0.45 -anchor center
    } else {
        frame $w.stage.dev
        ztk::class $w.stage.dev add device
        frame $w.stage.dev.bar
        ztk::class $w.stage.dev.bar add devicebar
        label $w.stage.dev.bar.t -text "Tip calculator"
        ztk::class $w.stage.dev.bar.t add devicetitle
        pack $w.stage.dev.bar.t -side left -padx 10 -pady 4
        label $w.stage.dev.bar.s -text "420 × 300"
        ztk::class $w.stage.dev.bar.s add devicesize
        pack $w.stage.dev.bar.s -side right -padx 10
        frame $w.stage.dev.app -padx 20 -pady 16
        ztk::class $w.stage.dev.app add deviceapp
        label $w.stage.dev.app.h -text "Tip calculator" -font {TkDefaultFont 18 bold}
        frame $w.stage.dev.app.r
        label $w.stage.dev.app.r.l -text "Bill" -width 10 -anchor w
        entry $w.stage.dev.app.r.e -width 12
        $w.stage.dev.app.r.e insert 0 84.00
        pack $w.stage.dev.app.r.l $w.stage.dev.app.r.e -side left
        set ::tip 15
        frame $w.stage.dev.app.s
        label $w.stage.dev.app.s.l -text "Tip percent" -width 10 -anchor w
        scale $w.stage.dev.app.s.s -from 0 -to 30 -orient horizontal -variable ::tip -length 220
        pack $w.stage.dev.app.s.l $w.stage.dev.app.s.s -side left
        label $w.stage.dev.app.t -text "Tip: 12.60" -font {TkDefaultFont 14}
        label $w.stage.dev.app.tt -text "Total: 96.60" -font {TkDefaultFont 18 bold}
        pack $w.stage.dev.app.h $w.stage.dev.app.r $w.stage.dev.app.s $w.stage.dev.app.t $w.stage.dev.app.tt -anchor w -pady 4
        pack $w.stage.dev.bar -fill x
        pack $w.stage.dev.app -fill both -expand 1
        place $w.stage.dev -relx 0.5 -rely 0.42 -anchor center
    }
    # The console: a strip with the count of lines. It opens to a log.
    frame $w.con
    ztk::class $w.con add consolebar
    ttk::label $w.con.i -image [ui::icon console muted] -style Muted.TLabel
    label $w.con.t -text "Console"
    ztk::class $w.con.t add muted
    label $w.con.n -text [expr {$mode eq "first" ? "no output" : "no output, no errors"}]
    ztk::class $w.con.n add faint
    pack $w.con.i -side left -padx {12 6} -pady 6
    pack $w.con.t $w.con.n -side left -padx {0 8}
    pack $w.con -fill x -side bottom -padx 1 -pady {0 1}
}

proc workspace {mode} {
    frame .main -padx 12 -pady 12
    ztk::class .main add body
    agentPane .main.agent [expr {$mode eq "first" ? "ready" : "working"}]
    if {$mode ne "first"} {writeSession .main.agent.term} else {
        .main.agent.term write "\x1b\[2mclaude is ready in ~/Projects/tip-calculator\x1b\[0m\r\n\r\n\x1b\[1m> \x1b\[0m"
    }
    previewPane .main.preview $mode
    grid .main.agent -row 0 -column 0 -sticky nsew
    grid .main.preview -row 0 -column 1 -sticky nsew -padx {12 0}
    grid columnconfigure .main 0 -weight 1 -uniform p
    grid columnconfigure .main 1 -weight 1 -uniform p
    grid rowconfigure .main 0 -weight 1
    grid .main -row 1 -column 0 -sticky nsew
}

switch -- $view {
    main - build - first {workspace [expr {$view eq "first" ? "first" : "main"}]}
    apps {
        frame .main -padx 24 -pady 20
        ztk::class .main add body
        ui::pageHead .main.h "Apps" "4 apps next to ~/Projects/tip-calculator"
        ttk::button .main.h.new -text "New app" -image [ui::icon plus fg] -compound left -style Ghost.TButton
        pack .main.h.new -side right -in .main.h.right
        pack .main.h -fill x -pady {0 16}
        frame .main.grid
        ztk::class .main.grid add body
        set i 0
        foreach {name path built when} {
            tip-calculator ~/Projects/tip-calculator {{linux "Linux x86-64" "1.9 MB" {}} {windows "Windows x86-64" "2.3 MB" {}}} "Built 2 minutes ago"
            pomodoro ~/Projects/pomodoro {{linux "Linux x86-64" "1.8 MB" {}} {macos "macOS Apple silicon" "2.1 MB" {}} {linux "Linux arm64" "1.8 MB" {}}} "Built yesterday"
            notes ~/Projects/notes {} "Not built"
            unit-converter ~/Projects/unit-converter {{linux "Linux x86-64" "1.9 MB" {}}} "Built 3 days ago"
        } {
            ui::appCard .main.grid.c$i $name $path $built $when [expr {$i == 0}] {}
            grid .main.grid.c$i -row [expr {$i / 3}] -column [expr {$i % 3}] -sticky nsew -padx {0 12} -pady {0 12}
            incr i
        }
        grid columnconfigure .main.grid {0 1 2} -weight 1 -uniform c
        pack .main.grid -fill both -expand 1 -anchor n
        grid .main -row 1 -column 0 -sticky nsew
    }
    activity {ui::activityMock .main; grid .main -row 1 -column 0 -sticky nsew}
}

ui::statusbar .sb [expr {$view eq "first" ? "first" : "main"}]
grid .sb -row 2 -column 0 -sticky ew
grid columnconfigure . 0 -weight 1
grid rowconfigure . 1 -weight 1

proc showPicker {} {
    array set ::target {x86_64-linux 1 x86_64-windows 1}
    ui::buildPicker .picker .hd.targets {
        linux {{x86_64-linux x86-64 1 "This computer"} {aarch64-linux arm64 1 ""}}
        macos {{aarch64-macos "Apple silicon" 1 "Headless off a Mac"} {x86_64-macos Intel 0 "No ztk program"}}
        windows {{x86_64-windows x86-64 1 ""} {aarch64-windows arm64 0 "No ztk program"}}
    } ::target {}
    .picker.foot.go configure -text "Build 2 targets"
}
if {$view eq "build"} {after 300 showPicker}

# ztk::snapshot renders a new frame of the window. tools/mockups.sh
# copies shot.png to the image of the view.
after 1500 {
    update
    set f [open /shot.png wb]
    puts -nonewline $f [binary decode base64 [ztk::snapshot .]]
    close $f
    exit
}
