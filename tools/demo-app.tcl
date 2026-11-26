# The app of the README screenshots: a tip calculator.
wm title . "Tip calculator"
set ::bill 84.00
set ::tip 15

proc update_total {args} {
    if {[string is double -strict $::bill]} {
        set t [expr {$::bill * $::tip / 100.0}]
        .tip configure -text [format "Tip: %.2f" $t]
        .total configure -text [format "Total: %.2f" [expr {$::bill + $t}]]
    } else {
        .tip configure -text "Tip: -"
        .total configure -text "Enter the bill."
    }
}

ttk::frame .f -padding 16
ttk::label .f.head -text "Tip calculator" -font {TkDefaultFont 18 bold}
ttk::label .f.billl -text "Bill"
ttk::entry .f.bill -textvariable ::bill -width 12
ttk::label .f.tipl -text "Tip percent"
scale .f.pct -from 0 -to 30 -orient horizontal -variable ::tip -command update_total
label .tip -font {TkDefaultFont 13}
label .total -font {TkDefaultFont 16 bold}
grid .f.head - -sticky w -pady {0 12}
grid .f.billl .f.bill -sticky w -pady 4
grid .f.tipl .f.pct -sticky we -pady 4
grid columnconfigure .f 1 -weight 1
pack .f -fill x
pack .tip .total -anchor w -padx 16 -pady 4
trace add variable ::bill write update_total
update_total
