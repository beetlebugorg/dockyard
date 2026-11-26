#!/bin/sh
# A fake agent program for the screenshots of the README. It prints a
# short session in the terminal pane and waits. The screenshots never
# run a real agent program.
b=$(printf '\033[1m'); d=$(printf '\033[2m'); g=$(printf '\033[32m'); r=$(printf '\033[0m')
cat <<END
${b}> Make a tip calculator: the bill, a slider for the tip, and the total.${r}

I write main.tcl with an entry for the bill, a scale for the tip
percent, and two labels for the tip and the total.

  ${g}Write${r}       ${d}main.tcl${r}
  ${g}errors${r}      ${d}no errors${r}
  ${g}screenshot${r}  ${d}tip calculator, 380x260${r}
  ${g}type${r}        ${d}.bill: 84.00${r}
  ${g}eval${r}        ${d}set ::tip -> 15${r}
  ${g}widgets${r}     ${d}.total: "Total: 96.60"${r}

The app works: a bill of 84.00 with a tip of 15% gives 12.60 and
a total of 96.60. The total changes when you move the slider.

END
printf '%s> %s' "$b" "$r"
# The pane closes the pseudo-terminal at the exit, and cat ends.
exec cat >/dev/null
