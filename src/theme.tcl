# The look of the dockyard window: the colors, the stylesheet, the
# icons, and the parts that the views share (the header, the cards, the
# pane heads, the status bar, the build picker, the app cards, and the
# empty states). The stylesheet sets CSS variables on the root for the
# light and the dark scheme, and each rule uses the variables. The icons
# are PNG images of src/ui-icons.tcl, one set for each scheme. A part is
# a proc that makes the widgets of one path. The views (ui.tcl,
# activity.tcl) fill the parts with state.

namespace eval ::ui {
    variable dark [expr {[ztk::style scheme] eq "dark"}]
    variable colors
    # The spacing steps are 4, 8, 12, 16, and 24 logical pixels. The
    # type steps are 11 (faint), 12 (secondary), 13 (body), 15 (pane
    # titles), and 20 (page titles).
    array set colors {
        light,bg #f3f4f6 light,surface #ffffff light,sunken #eceef1 light,stage #e8eaee
        light,fg #1f2329 light,muted #5f6672 light,faint #8a909b light,border #dfe2e7
        light,accent #2563eb light,ok #15803d light,warn #b45309 light,danger #dc2626
        light,okbg #dcfce7 light,warnbg #fef3c7 light,dangerbg #fee2e2 light,accentbg #dbeafe
        dark,bg #141519 dark,surface #1c1d22 dark,sunken #17181c dark,stage #111215
        dark,fg #e6e8ec dark,muted #a1a7b3 dark,faint #6f7580 dark,border #2b2d34
        dark,accent #3b82f6 dark,ok #4ade80 dark,warn #fbbf24 dark,danger #f87171
        dark,okbg #14301f dark,warnbg #3a2c0b dark,dangerbg #3b1717 dark,accentbg #172554
    }
}

proc ::ui::scheme {} {
    variable dark
    expr {$dark ? "dark" : "light"}
}

proc ::ui::color {name} {
    variable colors
    return $colors([scheme],$name)
}

# The image of one icon in a tone (muted, fg, white, accent, ok, warn,
# or danger), made once.
proc ::ui::icon {name tone} {
    set img ::ui::icon-$name-$tone
    if {[lsearch -exact [image names] $img] < 0} {
        image create photo $img -data [dict get $::dockyard::ui::icondata [list $name $tone [scheme] 16]]
    }
    return $img
}

proc ::ui::stylesheet {} {
    set vars ""
    foreach n {bg surface sunken stage fg muted faint border accent ok warn danger okbg warnbg dangerbg accentbg} {
        append vars "--d-$n: [color $n]; "
    }
    ztk::style add [string map [list @VARS@ $vars] {
        :root { @VARS@ --bg: var(--d-bg); --fg: var(--d-fg); --muted: var(--d-muted); --border: var(--d-border); --accent: var(--d-accent); }
        Frame.body, Frame.header, Frame.statusbar { background: var(--d-bg); }
        Frame.header { border-bottom: 1px solid var(--d-border); }
        Frame.statusbar { border-top: 1px solid var(--d-border); background: var(--d-surface); }
        Frame.card { background: var(--d-surface); border: 1px solid var(--d-border); border-radius: 10px; }
        Frame.panehead { background: var(--d-surface); border-radius: 10px; }
        Frame.stage { background: var(--d-stage); }
        Frame.consolebar { background: var(--d-surface); border-top: 1px solid var(--d-border); border-radius: 0 0 10px 10px; }
        Frame.device { background: var(--d-surface); border: 1px solid var(--d-border); border-radius: 10px; box-shadow: 0 8px 24px rgba(0,0,0,0.18); }
        Frame.devicebar { background: var(--d-sunken); border-bottom: 1px solid var(--d-border); border-radius: 10px 10px 0 0; }
        Frame.deviceapp { background: var(--d-surface); border-radius: 0 0 10px 10px; }
        Frame.popover { background: var(--d-surface); border: 1px solid var(--d-border); border-radius: 10px; box-shadow: 0 12px 32px rgba(0,0,0,0.28); }
        Frame.plain { background: var(--d-surface); }
        Checkbutton, Radiobutton { background: transparent; }
        Frame.row { background: var(--d-surface); border-radius: 6px; }
        Frame.row:hover { background: var(--d-sunken); }
        Frame.selected { background: var(--d-accentbg); border-radius: 6px; }
        Frame.turn { background: var(--d-sunken); border-radius: 6px; }
        Frame.banner { background: var(--d-dangerbg); border: 1px solid var(--d-dangerbg); border-radius: 8px; }
        Frame.code { background: var(--d-sunken); border: 1px solid var(--d-border); border-radius: 6px; }
        Frame.chip { background: var(--d-sunken); border-radius: 6px; }
        Frame.divider { background: var(--d-border); }
        Frame.okdot { background: var(--d-ok); border-radius: 4px; }
        Frame.idledot { background: var(--d-faint); border-radius: 4px; }
        Frame.warndot { background: var(--d-warn); border-radius: 4px; }
        Frame.dangerdot { background: var(--d-danger); border-radius: 4px; }
        Label { color: var(--d-fg); background: transparent; }
        Label.muted { color: var(--d-muted); font-size: 12px; }
        Label.faint { color: var(--d-faint); font-size: 12px; }
        Label.panetitle { font-size: 14px; }
        Label.pagetitle { font-size: 20px; }
        Label.mono { font-family: "JetBrains Mono"; font-size: 12px; }
        Label.monomuted { font-family: "JetBrains Mono"; font-size: 12px; color: var(--d-faint); }
        Label.ok { color: var(--d-ok); font-size: 12px; }
        Label.warn { color: var(--d-warn); font-size: 12px; }
        Label.danger { color: var(--d-danger); font-size: 12px; }
        Label.accent { color: var(--d-accent); font-size: 12px; }
        Label.pill { color: var(--d-muted); font-size: 12px; background: var(--d-sunken); border-radius: 9px; padding: 1px 8px; }
        Label.badge { color: var(--d-muted); font-size: 11px; background: var(--d-sunken); border-radius: 4px; padding: 0px 6px; }
        Label.badgeok { color: var(--d-ok); font-size: 11px; background: var(--d-okbg); border-radius: 4px; padding: 0px 6px; }
        Label.badgedanger { color: var(--d-danger); font-size: 11px; background: var(--d-dangerbg); border-radius: 4px; padding: 0px 6px; }
        Label.badgeaccent { color: var(--d-accent); font-size: 11px; background: var(--d-accentbg); border-radius: 4px; padding: 0px 6px; }
        Label.tile { color: white; font-size: 16px; background: var(--d-accent); border-radius: 8px; }
        Label.kbd { color: var(--d-muted); font-size: 11px; background: var(--d-sunken); border: 1px solid var(--d-border); border-radius: 4px; padding: 0px 5px; }
        TLabel { background: transparent; }
        TLabel.Muted { color: var(--d-muted); }
        TButton.Accent { background: var(--d-accent); color: white; border-color: var(--d-accent); padding: 5px 12px; }
        TButton.AccentEnd { background: var(--d-accent); color: white; border-color: var(--d-accent); padding: 5px 6px; }
        TButton.Ghost { background: transparent; border-color: transparent; padding: 4px 8px; color: var(--d-fg); }
        TButton.Ghost:hover { background: var(--d-sunken); }
        TButton.Icon { background: transparent; border-color: transparent; padding: 4px; }
        TButton.Icon:hover { background: var(--d-sunken); }
        TButton.Chip { background: var(--d-surface); border-color: var(--d-border); border-radius: 14px; padding: 4px 12px; color: var(--d-fg); }
        TButton.Project { background: transparent; border-color: transparent; padding: 2px 6px; font-size: 14px; color: var(--d-fg); }
        TButton.Project:hover { background: var(--d-sunken); }
        TButton.Danger { background: var(--d-danger); color: white; border-color: var(--d-danger); padding: 4px 12px; }
        Terminal.pane { background: var(--d-surface); }
    }]
}

# A card: a frame with a border and round corners.
proc ::ui::card {w} {
    frame $w
    ztk::class $w add card
    return $w
}

# A dot of 8 pixels in the color of a state.
proc ::ui::dot {w state} {
    frame $w -width 8 -height 8
    ztk::class $w add [dict get {ok okdot running okdot working okdot ready okdot idle idledot warn warndot danger dangerdot ended dangerdot} $state]
    return $w
}

proc ::ui::iconButton {w name tip {tone muted}} {
    ttk::button $w -image [icon $name $tone] -style Icon.TButton
    ztk::tooltip $w $tip
    return $w
}

# The header: the logo, the project button with its folder, the view
# switch, and the split Build button.
proc ::ui::header {w name folder view} {
    frame $w -padx 12 -pady 8
    ztk::class $w add header
    ttk::label $w.logo -image ::dockyard::ui::logo
    ttk::button $w.project -text $name -image [icon chevron muted] -compound right -style Project.TButton
    ztk::tooltip $w.project "Switch the project (Ctrl+O)"
    label $w.folder -text $folder
    ztk::class $w.folder add faint
    frame $w.views
    ztk::class $w.views add header
    foreach {v t i} {workspace Workspace terminal activity Activity activity apps Apps apps} {
        radiobutton $w.views.$v -text $t -variable ::ui::view -value $v -indicatoron 0
        ztk::class $w.views.$v add segmented
        pack $w.views.$v -side left
    }
    set ::ui::view $view
    ttk::button $w.build -text "Build" -image [icon build white] -compound left -style Accent.TButton
    ztk::tooltip $w.build "Build the selected targets (Ctrl+Shift+B)"
    ttk::button $w.targets -image [icon chevron white] -style AccentEnd.TButton
    ztk::tooltip $w.targets "Choose the targets"
    label $w.count -text "2 targets"
    ztk::class $w.count add muted
    pack $w.logo -side left -padx {0 8}
    pack $w.project -side left
    pack $w.folder -side left -padx {4 0}
    pack $w.targets -side right
    pack $w.build -side right -padx {0 1}
    pack $w.count -side right -padx {0 10}
    place $w.views -relx 0.5 -rely 0.5 -anchor center
    return $w
}

# The head row of a pane: an icon, a title, a detail, a state pill, and
# a frame on the right for buttons.
proc ::ui::paneHead {w iconName title detail state} {
    frame $w -padx 12 -height 40
    pack propagate $w 0
    ztk::class $w add panehead
    ttk::label $w.i -image [icon $iconName muted]
    label $w.t -text $title -font {TkDefaultFont 13 bold}
    ztk::class $w.t add panetitle
    label $w.d -text $detail
    ztk::class $w.d add faint
    frame $w.right
    ztk::class $w.right add panehead
    pack $w.i -side left -padx {0 8}
    pack $w.t -side left
    pack $w.d -side left -padx {8 0}
    pack $w.right -side right
    foreach c [list $w.i $w.t $w.d $w.right] {pack configure $c -pady 0}
    stateLabel $w.state $state
    pack $w.state -side right -padx {0 8}
    return $w
}

# A pill with a dot and the text of a state.
proc ::ui::stateLabel {w state} {
    frame $w
    ztk::class $w add panehead
    set text [dict get {working "Working" ready "Ready" running "Running" idle "Waiting for main.tcl" ended "Ended" error "Error" building "Building"} $state]
    dot $w.dot [expr {$state eq "error" ? "danger" : $state eq "building" ? "warn" : $state}]
    label $w.t -text $text
    ztk::class $w.t add muted
    pack $w.dot -side left -padx {0 6}
    pack $w.t -side left
    return $w
}

proc ::ui::emptyState {w image title text} {
    frame $w
    ztk::class $w add stage
    if {$image eq "logo"} {
        ttk::label $w.i -image ::dockyard::ui::logo64
    } else {
        ttk::label $w.i -image [icon $image muted]
    }
    label $w.t -text $title -font {TkDefaultFont 15 bold}
    label $w.x -text $text -wraplength 340 -justify center
    ztk::class $w.x add muted
    pack $w.i -pady {0 12}
    pack $w.t
    pack $w.x -pady {6 0}
    return $w
}

proc ::ui::pageHead {w title detail} {
    frame $w
    ztk::class $w add body
    label $w.t -text $title -font {TkDefaultFont 20 bold}
    ztk::class $w.t add pagetitle
    label $w.d -text $detail
    ztk::class $w.d add muted
    frame $w.right
    ztk::class $w.right add body
    pack $w.t -side left
    pack $w.d -side left -padx {12 0} -pady {6 0}
    pack $w.right -side right
    return $w
}

# The status bar: the sandbox, the network policy, the build, and the
# agent. Each item is an icon and a text, and a click opens its view.
proc ::ui::statusItem {w iconName tone text {class muted}} {
    frame $w
    ztk::class $w add statusbar
    ttk::label $w.i -image [icon $iconName $tone]
    label $w.t -text $text
    ztk::class $w.t add $class
    pack $w.i -side left -padx {0 6}
    pack $w.t -side left
    return $w
}

proc ::ui::statusbar {w mode} {
    frame $w -padx 12 -pady 4
    ztk::class $w add statusbar
    if {$mode eq "sandbox"} {
        statusItem $w.sandbox shieldcheck ok "Sandbox on" ok
        statusItem $w.net globe muted "Network: 4 hosts allowed"
    } else {
        statusItem $w.sandbox shield warn "Sandbox off: the agent runs on this computer" warn
        statusItem $w.net globe muted "Network: open"
    }
    if {$mode eq "first"} {
        statusItem $w.build build muted "Not built"
        statusItem $w.agent bolt muted "Agent: ready"
        statusItem $w.blocked check muted "Activity: 0 events"
    } else {
        statusItem $w.build check ok "Built Linux x86-64, 2 minutes ago"
        statusItem $w.agent bolt accent "Agent: Write main.tcl" accent
        statusItem $w.blocked blocked danger "1 blocked" danger
    }
    foreach i {sandbox net build} {pack $w.$i -side left -padx {0 18}}
    pack $w.blocked $w.agent -side right -padx {18 0}
    return $w
}

# The targets of Build, in groups by system: a dict of the system (linux,
# macos, windows) and its rows {target name ok note}. Each row is a check
# button of the array element var(target), with a note. A change runs
# the command.
proc ::ui::buildPicker {w anchor groups var command} {
    frame $w -padx 6 -pady 6
    ztk::class $w add popover
    label $w.title -text "Build targets" -font {TkDefaultFont 13 bold}
    label $w.sub -text "Each target is one program file in build/." -anchor w
    ztk::class $w.sub add muted
    pack $w.title -anchor w -padx 8 -pady {4 0}
    pack $w.sub -anchor w -padx 8 -pady {2 8}
    set i 0
    foreach {os targets} $groups {
        if {$targets eq ""} continue
        frame $w.g$i -padx 8 -pady 4
        ztk::class $w.g$i add plain
        ttk::label $w.g$i.i -image [icon $os fg]
        label $w.g$i.t -text [dict get {linux Linux macos macOS windows Windows} $os] -font {TkDefaultFont 12 bold}
        grid $w.g$i.i -row 0 -column 0 -sticky w -padx {0 8}
        grid $w.g$i.t -row 0 -column 1 -columnspan 2 -sticky w
        set r 1
        foreach t $targets {
            lassign $t id name ok note
            checkbutton $w.g$i.c$r -text $name -variable ${var}($id) -command $command
            if {!$ok} {$w.g$i.c$r configure -state disabled}
            label $w.g$i.n$r -text $note
            ztk::class $w.g$i.n$r add faint
            grid $w.g$i.c$r -row $r -column 1 -sticky w
            grid $w.g$i.n$r -row $r -column 2 -sticky e -padx {16 0}
            incr r
        }
        grid columnconfigure $w.g$i 2 -weight 1
        pack $w.g$i -fill x
        incr i
    }
    frame $w.div -height 1
    ztk::class $w.div add divider
    pack $w.div -fill x -pady 6
    frame $w.foot -padx 8 -pady 2
    ztk::class $w.foot add plain
    label $w.foot.k -text "Ctrl+Shift+B"
    ztk::class $w.foot.k add kbd
    ttk::button $w.foot.go -text "Build" -style Accent.TButton
    pack $w.foot.k -side left
    pack $w.foot.go -side right
    pack $w.foot -fill x -pady {0 4}
    update idletasks
    set x [expr {[winfo rootx $anchor] - [winfo rootx .] + [winfo width $anchor] - 340}]
    set y [expr {[winfo rooty $anchor] - [winfo rooty .] + [winfo height $anchor] + 6}]
    # raise of ztk keeps the place of the widget among its siblings, so
    # the other children of the toplevel go below it.
    foreach c [winfo children [winfo parent $w]] {if {$c ne $w && [string first $c. $anchor.] != 0} {lower $c}}
    place $w -x $x -y $y -width 340
}

# One app of the Apps view: a tile, the name, the folder, the programs,
# and the buttons.
proc ::ui::appCard {w name path builds when current open} {
    card $w
    $w configure -padx 16 -pady 14
    label $w.tile -text [string toupper [string index $name 0]] -width 2
    ztk::class $w.tile add tile
    label $w.n -text $name -font {TkDefaultFont 14 bold}
    label $w.p -text $path
    ztk::class $w.p add faint
    grid $w.tile -row 0 -column 0 -rowspan 2 -sticky nw -padx {0 12} -ipady 6
    grid $w.n -row 0 -column 1 -sticky w
    grid $w.p -row 1 -column 1 -sticky w
    if {$current} {
        label $w.cur -text "Open now"
        ztk::class $w.cur add badgeaccent
        grid $w.cur -row 0 -column 2 -sticky ne
    }
    frame $w.b
    ztk::class $w.b add card
    $w.b configure -borderwidth 0
    set r 0
    if {$builds eq ""} {
        label $w.b.none -text "No programs yet. Build makes them."
        ztk::class $w.b.none add faint
        grid $w.b.none -row 0 -column 0 -sticky w
    }
    foreach b $builds {
        lassign $b os target size launch
        ttk::label $w.b.i$r -image [icon $os muted]
        label $w.b.t$r -text $target
        label $w.b.s$r -text $size
        ztk::class $w.b.s$r add faint
        ttk::button $w.b.l$r -text "Launch" -image [icon play ok] -compound left -style Ghost.TButton -command $launch
        grid $w.b.i$r -row $r -column 0 -sticky w -padx {0 8}
        grid $w.b.t$r -row $r -column 1 -sticky w
        grid $w.b.s$r -row $r -column 2 -sticky e -padx 8
        grid $w.b.l$r -row $r -column 3 -sticky e
        incr r
    }
    grid columnconfigure $w.b 1 -weight 1
    grid $w.b -row 2 -column 0 -columnspan 3 -sticky ew -pady {14 10}
    label $w.w -text $when
    ztk::class $w.w add muted
    frame $w.act
    ztk::class $w.act add card
    $w.act configure -borderwidth 0
    ttk::button $w.o -text [expr {$current ? "Show" : "Open"}] -style Ghost.TButton -command $open
    pack $w.o -side right -in $w.act
    grid $w.w -row 3 -column 0 -columnspan 2 -sticky w
    grid $w.act -row 3 -column 2 -sticky e
    grid columnconfigure $w 1 -weight 1
    grid rowconfigure $w 2 -weight 1
    return $w
}

image create photo ::dockyard::ui::logo -data $::dockyard::icon20
image create photo ::dockyard::ui::logo64 -data $::dockyard::icon64
::ui::stylesheet
