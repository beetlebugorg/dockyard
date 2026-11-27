# The sandbox of dockyard (issue 13): a guest of ztcl::vm with the
# helper of dockyard in it (src/guest/main.zig). The terminal pane runs
# its program on a PTY of the guest, over vsock. The proxy port of the
# guest goes over vsock to the egress proxy of dockyard. The protocol
# of the helper is in docs/dev/guest.md.
#
# The commands:
#   sandbox::boot ?-option value ...?   Starts a guest and its helper. Gives the guest.
#   sandbox::session VM ?-option value ...?   Starts a program on a PTY. Gives the session.
#   sandbox::input S BYTES      Sends the keys to the program.
#   sandbox::resize S ROWS COLS Gives the program a new size.
#   sandbox::signal S NUMBER    Sends a signal to the process group.
#   sandbox::end S              Ends the session and the program.
#   sandbox::relay VM           Sends each connection of the proxy port to dockyard::proxy.
#   sandbox::events VM SCRIPT   Calls SCRIPT with a dict for each program that starts or ends,
#                               and for each hook call of the agent program.
#   sandbox::hooks VM HOME      Writes the hook settings of the agent program in HOME of the guest.

namespace eval ::dockyard::sandbox {
    variable port_session 7100
    variable port_control 7101
    variable port_data 7102
    variable port_events 7103
    # The state of each session: the channel, the bytes that wait, and
    # the scripts.
    variable sessions
    array set sessions {}
    variable next 0
}

proc ::dockyard::sandbox::Frame {ch type payload} {
    puts -nonewline $ch [binary format icu [expr {[string length $payload] + 1}] $type]$payload
    flush $ch
}

proc ::dockyard::sandbox::Str {s} {
    set b [encoding convertto utf-8 $s]
    return [binary format i [string length $b]]$b
}

proc ::dockyard::sandbox::List {l} {
    set out [binary format i [llength $l]]
    foreach s $l {append out [Str $s]}
    return $out
}

# Starts a guest and the helper in it. The options:
#   -kernel F -initrd F -cmdline TEXT  The guest (paths below the root folder).
#   -helper F       The helper program of the architecture of the guest.
#   -memory MB -cpus N
#   -share {HOST GUEST ?rw?}   A folder for the guest, mounted at GUEST.
proc ::dockyard::sandbox::boot {args} {
    set o [dict merge {-cmdline {rdinit=/sbin/agent quiet} -memory 256 -cpus 1 -share {} -initrd {}} $args]
    set create [list -kernel [dict get $o -kernel] -cmdline [dict get $o -cmdline] \
        -memory [dict get $o -memory] -cpus [dict get $o -cpus]]
    if {[dict get $o -initrd] ne ""} {lappend create -initrd [dict get $o -initrd]}
    set share [dict get $o -share]
    if {$share ne ""} {lappend create -share $share}
    set vm [ztcl::vm create {*}$create]
    if {[catch {
        ztcl::vm start $vm
        # The agent of ztcl mounts share0 at /mnt/share when the guest
        # starts, with the mode of -share. A second mount of the same tag
        # fails with EBUSY, so a bind mount puts it at GUEST.
        if {$share ne ""} {
            Check [ztcl::vm exec $vm -- /bin/busybox sh -c \
                {/bin/busybox mkdir -p "$1" && /bin/busybox mount -o bind /mnt/share "$1"} sh [lindex $share 1]] "the mount of the share"
        }
        set f [open [dict get $o -helper] rb]
        fconfigure $f -translation binary
        set data [read $f]
        close $f
        # The input of exec goes as UTF-8 text, so the bytes go as base64.
        Check [ztcl::vm exec $vm -stdin [binary encode base64 $data] -- /bin/busybox sh -c \
            {/bin/busybox base64 -d > /tmp/dockyard-guest && /bin/busybox chmod 755 /tmp/dockyard-guest}] "the copy of the helper"
        Check [ztcl::vm exec $vm -- /tmp/dockyard-guest serve] "the start of the helper"
    } msg opts]} {
        catch {ztcl::vm delete $vm}
        return -options $opts $msg
    }
    return $vm
}

proc ::dockyard::sandbox::Check {r what} {
    if {[dict get $r exit] != 0} {
        error "$what failed ([dict get $r exit]): [string trim [dict get $r stderr]]"
    }
}

# The events of the hooks of the agent program that go to the monitor.
# Each hook runs `dockyard-guest hook`, which gives the events stream
# one line of type hook (`docs/dev/guest.md`).
namespace eval ::dockyard::sandbox {
    variable hook_events {SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SubagentStop}
}

# Writes HOME/.claude/settings.json in the guest with a hook for each
# event of hook_events. HOME is a folder of the guest, outside /work, so
# the settings of the project stay as they are.
proc ::dockyard::sandbox::hooks {vm home} {
    variable hook_events
    set cmd {[{"hooks":[{"type":"command","command":"/tmp/dockyard-guest hook"}]}]}
    set parts {}
    foreach e $hook_events {lappend parts "\"$e\":$cmd"}
    set json "{\"hooks\":{[join $parts ,]}}"
    Check [ztcl::vm exec $vm -stdin $json -- /bin/busybox sh -c \
        "/bin/busybox mkdir -p '$home/.claude' && /bin/busybox cat > '$home/.claude/settings.json'"] "the hook settings"
}

# Starts a program on a PTY of the guest. The options:
#   -argv LIST (default /bin/busybox sh -l), -env LIST, -cwd DIR,
#   -rows N, -cols N, -output SCRIPT (gets the text), -exit SCRIPT (gets the code).
proc ::dockyard::sandbox::session {vm args} {
    variable port_session
    variable sessions
    variable next
    set o [dict merge {-argv {/bin/busybox sh -l} -env {TERM=xterm-256color HOME=/root PATH=/bin:/sbin:/usr/bin}
        -cwd / -rows 24 -cols 80 -output {} -exit {}} $args]
    set ch [ztcl::vm vsock $vm $port_session]
    fconfigure $ch -translation binary -blocking 0
    set s session[incr next]
    set sessions($s) [dict create ch $ch buf {} text {} output [dict get $o -output] exit [dict get $o -exit] pid 0]
    Frame $ch 1 [binary format ss [dict get $o -rows] [dict get $o -cols]][List [dict get $o -argv]][List [dict get $o -env]][Str [dict get $o -cwd]]
    fileevent $ch readable [list ::dockyard::sandbox::Readable $s]
    return $s
}

# The frames of a session: started (0x10), output (0x11), exit (0x12),
# and error (0x3f).
proc ::dockyard::sandbox::Readable {s} {
    variable sessions
    if {![info exists sessions($s)]} return
    set st $sessions($s)
    set ch [dict get $st ch]
    set data [read $ch]
    set buf [dict get $st buf]$data
    while {[string length $buf] >= 5} {
        binary scan $buf icu len type
        if {[string length $buf] < 4 + $len} break
        set payload [string range $buf 5 [expr {3 + $len}]]
        set buf [string range $buf [expr {4 + $len}] end]
        switch -- $type {
            16 {binary scan $payload iu pid; dict set st pid $pid}
            17 {
                # Keep an incomplete UTF-8 sequence for the next frame.
                set text [dict get $st text]$payload
                set cut [Whole $text]
                dict set st text [string range $text $cut end]
                set out [dict get $st output]
                if {$out ne "" && $cut > 0} {
                    {*}$out [encoding convertfrom utf-8 [string range $text 0 [expr {$cut - 1}]]]
                }
            }
            18 {binary scan $payload i code; dict set st code $code}
            63 {
                binary scan $payload iui errno n
                dict set st code -1
                dict set st error "[string range $payload 8 end] (errno $errno)"
            }
        }
    }
    dict set st buf $buf
    set sessions($s) $st
    if {[eof $ch]} {
        close $ch
        unset sessions($s)
        set code [expr {[dict exists $st code] ? [dict get $st code] : -1}]
        if {[dict exists $st error]} {
            set out [dict get $st output]
            if {$out ne ""} {{*}$out "sandbox: [dict get $st error]\r\n"}
        }
        set ex [dict get $st exit]
        if {$ex ne ""} {{*}$ex $code}
    }
}

# The count of the bytes of `b` before an incomplete UTF-8 sequence at
# its end.
proc ::dockyard::sandbox::Whole {b} {
    set n [string length $b]
    for {set k 1} {$k <= 3 && $k <= $n} {incr k} {
        binary scan [string index $b end-[expr {$k - 1}]] cu c
        if {($c & 0xC0) == 0x80} continue
        if {$c >= 0xF0} {set need 4} elseif {$c >= 0xE0} {set need 3} elseif {$c >= 0xC0} {set need 2} else {set need 1}
        return [expr {$need > $k ? $n - $k : $n}]
    }
    return $n
}

proc ::dockyard::sandbox::input {s bytes} {
    variable sessions
    if {![info exists sessions($s)]} return
    Frame [dict get $sessions($s) ch] 2 [encoding convertto utf-8 $bytes]
}

proc ::dockyard::sandbox::resize {s rows cols} {
    variable sessions
    if {![info exists sessions($s)]} return
    Frame [dict get $sessions($s) ch] 3 [binary format ss $rows $cols]
}

proc ::dockyard::sandbox::signal {s number} {
    variable sessions
    if {![info exists sessions($s)]} return
    Frame [dict get $sessions($s) ch] 4 [binary format cu $number]
}

proc ::dockyard::sandbox::end {s} {
    variable sessions
    if {![info exists sessions($s)]} return
    close [dict get $sessions($s) ch]
    unset sessions($s)
}

# The proxy port of the guest: the helper sends an id for each new TCP
# client on the control connection. Each id gets a data connection,
# which goes to the egress proxy of dockyard.
proc ::dockyard::sandbox::relay {vm} {
    variable port_control
    set ch [ztcl::vm vsock $vm $port_control]
    fconfigure $ch -translation binary -blocking 0
    fileevent $ch readable [list ::dockyard::sandbox::Ids $vm $ch]
    return $ch
}

proc ::dockyard::sandbox::Ids {vm ch} {
    variable port_data
    variable ids
    append ids($ch) [read $ch]
    while {[string length $ids($ch)] >= 4} {
        set id [string range $ids($ch) 0 3]
        set ids($ch) [string range $ids($ch) 4 end]
        set d [ztcl::vm vsock $vm $port_data]
        fconfigure $d -translation binary
        puts -nonewline $d $id
        flush $d
        ::dockyard::proxy attach $d
    }
    if {[eof $ch]} {
        close $ch
        unset ids($ch)
    }
}

# The events of the programs in the guest: a JSON line for each start
# (type exec, time, pid, ppid, argv) and each end (type exit, time, pid).
proc ::dockyard::sandbox::events {vm script} {
    variable port_events
    set ch [ztcl::vm vsock $vm $port_events]
    fconfigure $ch -translation binary -blocking 0
    fileevent $ch readable [list ::dockyard::sandbox::Lines $ch $script]
    return $ch
}

proc ::dockyard::sandbox::Lines {ch script} {
    while {[gets $ch line] >= 0} {
        if {$line ne ""} {{*}$script [ParseEvent $line]}
    }
    if {[eof $ch]} {close $ch}
}

# The JSON of the helper is flat: numbers, strings, and one list of
# strings (argv), so a small reader is enough.
proc ::dockyard::sandbox::ParseEvent {line} {
    set d [dict create]
    set re {"([a-z]+)":(-?[0-9]+|"(?:[^"\\]|\\.)*"|\[(?:[^\]"]|"(?:[^"\\]|\\.)*")*\])}
    foreach {- key value} [regexp -all -inline $re $line] {
        switch -- [string index $value 0] {
            \" {dict set d $key [Unquote [string range $value 1 end-1]]}
            \[ {
                set l {}
                foreach {- s} [regexp -all -inline {"((?:[^"\\]|\\.)*)"} $value] {lappend l [Unquote $s]}
                dict set d $key $l
            }
            default {dict set d $key $value}
        }
    }
    return $d
}

proc ::dockyard::sandbox::Unquote {s} {
    set s [string map {\\\" \" \\\\ \\} $s]
    while {[regexp -indices {\\u00([0-9a-f]{2})} $s m h]} {
        set c [format %c 0x[string range $s {*}$h]]
        set s [string replace $s {*}$m $c]
    }
    return $s
}
