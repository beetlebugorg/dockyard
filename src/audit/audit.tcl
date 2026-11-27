# The records of the audit log (docs/dev/audit.md) from the events of
# the dockyard window: the sessions of the pane, the hooks of the agent
# program, the programs of the guest, the proxy, the file watcher, the
# shares, and the rules. `dockyard::audit` (audit.zig) writes them.
#
# A failure to write a record does not stop the window. The first
# failure goes to the script in on_error, with the message. This file has
# no UI code: the window sets on_error.

namespace eval ::dockyard::audit {
    variable session ""
    variable turns 0
    variable failed 0
    variable on_error {}
}

# Adds one record. `opts` are the options of `dockyard::audit log`.
proc ::dockyard::audit::Log {kind data args} {
    variable failed
    variable on_error
    # A build for Windows has no audit log yet.
    if {[info commands ::dockyard::audit] eq ""} return
    if {[catch {::dockyard::audit log $kind $data {*}$args} msg] && !$failed} {
        set failed 1
        if {$on_error ne ""} {catch {{*}$on_error $msg}}
    }
}

# A session starts: one start of the agent program in the pane.
proc ::dockyard::audit::start {sandbox argv} {
    variable session
    variable turns
    if {[catch {::dockyard::audit session} session]} {set session ""}
    set turns 0
    Log session [list op start sandbox $sandbox argv $argv project $::dockyard::project]
}

proc ::dockyard::audit::end {status} {
    variable session
    if {$session eq ""} return
    if {[string is integer -strict $status]} {
        Log session [list op end exit $status]
    } else {
        Log session [list op end status $status]
    }
    catch {::dockyard::audit context -turn ""}
}

# One event of the guest helper or of the hooks (type, time, fields).
proc ::dockyard::audit::guest {kind d} {
    set opts {}
    if {[dict exists $d time]} {
        lappend opts -time [dict get $d time]
        dict unset d time
    }
    switch -- $kind {
        hook {hook $d $opts}
        exec - exit {Log $kind $d -source helper {*}$opts}
        note {Log note $d -source helper {*}$opts}
        default {Log note [list text "an event of the guest of type $kind"] -source helper {*}$opts}
    }
}

# A hook of the agent program. UserPromptSubmit starts a turn, and Stop
# ends it. PreToolUse and PostToolUse are the start and the end of a
# tool call.
proc ::dockyard::audit::hook {d opts} {
    variable session
    variable turns
    set ev [dict get $d event]
    set input {}
    foreach f {path command pattern url} {
        if {[dict exists $d $f]} {dict set input $f [dict get $d $f]}
    }
    set more {}
    if {[dict exists $d session]} {lappend more agent_session [dict get $d session]}
    if {[dict exists $d call]} {lappend opts -call [dict get $d call]}
    set tool [expr {[dict exists $d tool] ? [dict get $d tool] : ""}]
    switch -- $ev {
        UserPromptSubmit {
            catch {::dockyard::audit context -turn $session.[incr turns]}
            set prompt [expr {[dict exists $d prompt] ? [dict get $d prompt] : ""}]
            Log turn [list op start prompt $prompt {*}$more] -source hook {*}$opts
        }
        Stop {
            Log turn [list op end {*}$more] -source hook {*}$opts
            catch {::dockyard::audit context -turn ""}
        }
        PreToolUse {Log tool [list op start tool $tool input $input] -source hook {*}$opts}
        PostToolUse {Log tool [list op end tool $tool input $input] -source hook {*}$opts}
        default {Log note [list text "hook $ev" tool $tool {*}$more] -source hook {*}$opts}
    }
}

# A call of the egress proxy. A blocked call also gives a blocked record.
proc ::dockyard::audit::net {d} {
    set time [dict get $d time]
    dict unset d time
    Log net $d -source proxy -time $time
    if {[dict get $d result] eq "blocked"} {
        Log blocked [list what net target [dict get $d host]:[dict get $d port]] -source proxy -time $time
    }
}

# A change of the file watcher of the project folder.
proc ::dockyard::audit::change {change} {
    lassign $change kind path
    set ops {created create modified write deleted remove moved rename}
    set op [expr {[dict exists $ops $kind] ? [dict get $ops $kind] : $kind}]
    Log file [list op $op path $path before {} after {}] -source watch
}
