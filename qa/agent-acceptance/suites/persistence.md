# Suite: persistence — headless/GUI data integrity

P1 HEADLESS -> GUI: with no GUI, create/verify a `QATEST-persistence`
workspace via CLI (use an existing QATEST- one if present). Launch the GUI on
workspace 2; the entity must be visible. Screenshot.

P2 GUI EDIT -> RELAUNCH: type a timestamped line into the QATEST- draft,
close (normal WM close), relaunch. The draft content must survive. No
persistence banner at any point.

P3 SECOND INSTANCE: launch a second GUI on workspace 2. Both must coexist on
the SAME daemon (no second `__session-daemon` for the real XDG dir), render
coherently, show no banner. Close both normally.

P4 DAEMON SURVIVAL + CLI CONSISTENCY: after all GUIs are closed, scoped CLI
reads must still work in ms-range and reflect the QATEST- edits.

Cleanup per charter (leave QATEST- entities, list them). Report per charter.
