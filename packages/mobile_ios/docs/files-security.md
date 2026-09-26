# Files, appearance, and app lock (I-09)

File citations and diff “Open file” links open a native sheet. Relative paths
resolve against the selected workspace; the core and host still enforce path,
authorization, and TLS policy. PDFKit displays PDFs and host-converted Office
previews. Images are downsampled to a 4096-pixel edge and support pinch zoom.
Markdown uses the core parser, with a Source switch; citation ranges select and
reveal UTF-16 text offsets. Text is UTF-8 only. Limits match Android: text 2 MiB,
images 16 MiB, PDF/Office 32 MiB. Unsupported types retain the host's error.

The platform executes `file_fetch` through the same URLSession origin/pin,
redirect, cookie, and cache restrictions as other HTTP effects. File bodies stay
outside core JSON and storage. The core receives only status/failure. In-flight
requests are bounded by the core; completed buffers are capped at four / 64 MiB,
consumed once, and dropped after cancellation or host shutdown. A dismissed
viewer marks its pending result unwanted.

Share/Open in is explicit: it writes a protected, backup-excluded temporary
copy, uses the system share sheet, and removes the copy on dismissal. Sign-out
closes the viewer and removes its copy. Startup removes copies left by a crash.
The recipient chosen in the share sheet owns any exported copy.

Settings is in the workspace drawer. Appearance offers Verde dark (default),
host, or system light/dark. Host mode uses authenticated `/api/theme` through a
64 KiB core fetch; native clients never obtain the bearer. Color fields are
validated hex RGBA values. Missing/invalid themes fall back to Verde dark.
Reduce Motion suppresses pulse/drawer/transcript jump animations; an optional
host `reduced_motion` flag is honored if supplied (the current endpoint supplies
colors but no motion flag).

App lock is off by default. Enabling or disabling requires device-owner
authentication (Face ID, Touch ID, or passcode), and settings live in the existing
ThisDeviceOnly Keychain. Cold launch locks immediately when enabled. Background
time uses a monotonic clock, with immediate / 1 / 5 / 15 minute options; inactive
system prompts do not count as background time. Failed storage reads fail closed
with Retry. Failed writes retain the previous settings. A separate scene window
covers presented sheets as well as the root, including app-switcher snapshots;
privacy covering defaults on. Host activity pauses while locked so hidden chats
do not clear attention. Push actions still need their own I-10 authentication.

Simulator unit tests use injected authentication/storage and bounded transport
fixtures, not a live host. The default mise build remains unsigned. Real
Keychain/UI review on a simulator needs a local ad-hoc signing override;
physical devices need an Apple Development identity and registered iPhone.
