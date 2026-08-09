# Suite: switching — sustained workspace switching must be stutter-free

The single most user-sensitive metric. Single-screenshot timing is
insufficient — follow the charter's measurement discipline.

W1 SETUP: launch on workspace 2, wait for the restored UI (loading frame
gone). Identify a light and a heavy internal workspace from the sidebar.

W2 SUSTAINED BURST: ydotool Alt+1/Alt+2/Alt+3 round-robin, >=12 switches over
~30s: some immediately consecutive (no settle), some followed by 5s of
observation. Capture frames continuously at 4-10Hz for the entire burst.
For each switch report: time to first visual change, and any frozen interval
>200ms after the change. Report first-visit vs repeat-visit separately.

W3 DIRTY-FLUSH SWITCH: type a few words into a QATEST- workspace draft
(create `QATEST-switching` if absent), then immediately switch workspaces
repeatedly during the flush window. No freeze allowed; the typed draft must
survive a relaunch (verify, then note it for cleanup).

W4 GROUND TRUTH: grep the stderr log for `SDL thread stall` and slow-frame
markers within your session window; report every hit (operation + elapsed_ms).
PASS requires none >200ms after restore completed.

Cleanup per charter. Report per charter.
