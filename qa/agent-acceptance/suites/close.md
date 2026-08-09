# Suite: close — WM close semantics and timing

C1 UNFOCUSED CLOSE: launch on workspace 2, stay on workspace 1, close via
`hyprctl dispatch closewindow address:<addr>` (window is occluded/unfocused —
this MUST work). Measure window-gone and process-exit separately.

C2 FOCUSED CLOSE: relaunch, focus the window, close the same way. Same
measurements. Focused must not be slower than unfocused beyond noise.

C3 DIRTY CLOSE: relaunch, type into a QATEST- draft, close immediately.
Window must still hide fast; record the handoff elapsed_ms marker and process
exit time; the draft must survive the next launch (verify).

C4 SUPER+W: with the window focused and pointer NOT over the window, send
Super+W via ydotool. The window must close (keyboard-driven tiling-WM close).

C5 MARKERS + SURVIVAL: report every `close durability handoff` marker from
your session; the daemon must be alive after every exit; no window may ever
re-show (a re-show means the durability handoff failed — report loudly).

Cleanup per charter. Report per charter.
