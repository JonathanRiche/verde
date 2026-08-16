# Suite: full — complete acceptance sweep

Run all four focused suites in this order, as one session where sensible
(reuse launched GUIs across steps when the suite semantics allow it):

1. suites/smoke.md
2. suites/persistence.md
3. suites/close.md
4. suites/switching.md

Produce ONE combined report per the charter, with a per-suite PASS/FAIL
rollup at the top and the environment pin stated once.
