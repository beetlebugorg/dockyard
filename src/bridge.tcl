# The Tcl side of the MCP bridge in the preview child. The MCP server
# (`dockyard --mcp`) sends calls of these procs over the control socket.
# The events go through the dispatcher of ztk with `ztk::inject`.

namespace eval ::dockyard::bridge {}

# The widgets below `top` as lines: the path, the class, x y width
# height in the toplevel, the mapped flag, and the -text option when the
# widget has one.
proc ::dockyard::bridge::widgets {{top .}} {
    set lines {}
    foreach w [ztk::tree $top] {
        lassign $w path class x y width height mapped
        set line "$path $class $x $y $width $height $mapped"
        if {![catch {$path cget -text} text] && $text ne ""} {
            append line " text=[list $text]"
        }
        lappend lines $line
    }
    join $lines \n
}

# The widget at x y of the toplevel `top`: the last mapped widget of the
# walk of `ztk::tree` whose rectangle has the point. Other toplevels
# below `top` are left out.
proc ::dockyard::bridge::at {top x y} {
    set hit $top
    set skip ""
    foreach w [lrange [ztk::tree $top] 1 end] {
        lassign $w path class wx wy width height mapped
        if {$skip ne "" && [string match $skip.* $path]} continue
        if {$class eq "Toplevel"} {
            set skip $path
            continue
        }
        if {!$mapped} continue
        if {$x >= $wx && $y >= $wy && $x < $wx + $width && $y < $wy + $height} {
            set hit $path
        }
    }
    return $hit
}

# A press and a release of `button` at x y of the toplevel `top`, after
# a motion to the point. Gives the path of the widget at the point.
proc ::dockyard::bridge::click {x y {button 1} {top .}} {
    ztk::inject $top motion $x $y
    ztk::inject $top press $button $x $y
    ztk::inject $top release $button $x $y
    update
    return [at $top $x $y]
}

# The toplevel for keys. A widget `w` that is not empty gets the focus
# first. Gives the widget with the focus.
proc ::dockyard::bridge::target {w} {
    if {$w ne ""} {focus $w}
    set f [focus]
    if {$f eq ""} {return .}
    return $f
}

# Types `text` into the widget with the focus, or into `w`.
proc ::dockyard::bridge::type {text {w ""}} {
    set f [target $w]
    ztk::inject [winfo toplevel $f] text $text
    update
    return $f
}

# One key with modifiers, for example "Return" or "Control-a".
proc ::dockyard::bridge::key {key {w ""}} {
    set f [target $w]
    set parts [split $key -]
    set sym [lindex $parts end]
    set state 0
    foreach m [lrange $parts 0 end-1] {
        switch -- $m {
            Shift {set state [expr {$state | 1}]}
            Control {set state [expr {$state | 4}]}
            Alt - Mod1 {set state [expr {$state | 8}]}
            Super - Mod4 {set state [expr {$state | 64}]}
            default {error "bad modifier \"$m\": must be Shift, Control, Alt, or Super"}
        }
    }
    ztk::inject [winfo toplevel $f] key $sym -state $state
    update
    return $f
}

# A wheel turn of `delta` at x y of the toplevel `top`. A negative delta
# scrolls down, as in Tk. Gives the path of the widget at the point.
proc ::dockyard::bridge::scroll {x y delta {top .}} {
    ztk::inject $top motion $x $y
    ztk::inject $top wheel $x $y $delta
    update
    return [at $top $x $y]
}
