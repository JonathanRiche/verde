# Desktop Live voice

Native, full-duplex voice with the machine Companion in the desktop app. It
mirrors the phone apps (`LiveVoice.kt`, `LiveVoice.swift`): the daemon keeps the
provider API key and mints a short-lived token (`voice.session.create`), and the
client opens the provider WebSocket, streams microphone PCM, plays the reply,
and runs the voice model's tools against the Companion. Linux (PipeWire) ships
first. macOS and Windows have stub backends behind the same interface.

No browser, webview, or WebRTC stack is involved. Audio, TLS, and the
WebSocket are native code in `verde-gui`.

## Decisions

### Linux audio: PipeWire native API, loaded with `dlopen`

| Option | Verdict |
| --- | --- |
| **PipeWire `libpipewire-0.3` streams** | **Chosen.** Omarchy runs PipeWire 1.6. `pw_stream` gives an RT callback per quantum, converts rate, format, and channels inside the server's adapter (so we ask for S16 mono at the provider rate directly), and is the only option that can load the echo canceller per session. |
| PulseAudio simple API (`pa_simple`) | Blocking read/write calls with no cancellable callback and high latency on pipewire-pulse. No way to load AEC per client. |
| ALSA | Raw ALSA bypasses PipeWire, so there is no routing, no device follow, and no AEC, and it fights the session manager for the device. |

The library is opened with `std.DynLib` (`libpipewire-0.3.so.0`) the first time
Live starts, never at link time. A machine without PipeWire still starts
Verde, and the mic button reports "PipeWire not available". We don't use `@cImport`
and need no build-time headers. The handful of `pw_*` entry points are
resolved by name. The stable C ABI structs we touch (`pw_stream_events`,
`pw_buffer`, `spa_buffer`/`spa_data`/`spa_chunk`) are declared in Zig. The
one SPA pod we need, the `EnumFormat` audio/raw object, is assembled as
bytes. The pod layout is part of the SPA ABI, and a unit test covers it.

### Echo cancellation: PipeWire `module-echo-cancel` per session, half-duplex fallback

- **Default:** when Live starts, we load `libpipewire-module-echo-cancel`
  (WebRTC AEC, `aec/libspa-aec-webrtc`) into **our own** `pw_context`. The
  module's nodes live in our client, so they disappear when the session ends
  or Verde crashes. The system graph is never left modified. Our capture
  stream targets the module's cleaned source and our playback stream targets
  its sink, so the AEC reference is exactly what Moss says. On Omarchy both
  the module and the WebRTC plugin ship in the `pipewire` package, so this
  needs no setup.
- **Fallback:** if the module fails to load (older PipeWire, plugin missing,
  or `VERDE_LIVE_AEC=off`), the streams use the default mic and speaker and
  the engine runs **half-duplex**. Mic audio is not sent while reply audio is
  playing, plus a 350 ms tail. Moss never hears itself. Barge-in then needs a
  click on the character or the keybind, and the panel says "Use headphones
  to interrupt by voice".
- **Rejected:** bundling WebRTC AEC3 or speexdsp means a C++ dependency, the
  delay estimation is ours to get right, and it duplicates what the audio
  server already does. Requiring headphones fails "works out of the box".

### Resampling

PipeWire's adapter resamples for us: capture is negotiated at the provider's
input rate (24 kHz for OpenAI and xAI, 16 kHz for Gemini) and playback at
24 kHz, S16LE mono. A portable streaming resampler
(`live_voice/resample.zig`) remains for backends that can't convert
(WASAPI shared mode) and for a device that insists on its own rate. It is
linear interpolation with fractional phase carried across chunks, plus a
2-pole low-pass ahead of downsampling. That is enough for speech into a
speech model, and it is unit tested.

### WebSocket over TLS: Zig std only

`std.http.Client` already loads the system CA bundle and builds a
`std.crypto.tls.Client` (`connectTcp(host, 443, .tls)`). We take that
`Connection`, write the RFC 6455 upgrade ourselves, check
`Sec-WebSocket-Accept`, and run a small framer (`live_voice/websocket.zig`):
masked client frames, fragmented server messages, ping/pong, and close. The
loopback-only WebSocket in `providers/codex.zig` is plain TCP, so it isn't
reusable. We add no new dependency. `std.crypto.tls.Client` must not be read
and written from two threads at once, because a server `KeyUpdate` rewrites
the write keys inside `read`. One network thread therefore owns the socket.

### Threading

```
PipeWire RT thread ── capture ring (SPSC i16) ──▶ network thread ── wss ──▶ provider
PipeWire RT thread ◀─ playback ring (SPSC i16) ── network thread ◀─ wss ──
                                                   │  ▲
                              events (mutex queue) ▼  │ commands (mutex queue + eventfd)
                                               GUI thread (Companion)
```

- Audio callbacks only copy samples into or out of lock-free single-producer
  rings. They never lock, allocate, log, or touch the network. On a playback
  underrun they write silence. A barge-in flush is a flag the playback
  callback honours on its next quantum.
- The network thread `poll`s the socket plus an eventfd (commands), drains the
  capture ring in 40 ms chunks, base64s them into `input_audio_buffer.append`
  or `realtimeInput`, and decodes reply audio into the playback ring.
- The GUI thread never blocks. It drains the event queue in the Companion
  tick (like `schedules_sync`) and posts commands: tool results, injected
  companion updates, mute, end. Session minting is a worker-thread daemon RPC.

### Where it runs: in the GUI process

The microphone and speakers belong to the machine with the window. The daemon
may be headless or remote, and the phones already run voice client-side, so
the desktop does the same. A separate helper process would add an IPC hop on
the audio path (latency, and barge-in flush crossing a process), plus a new
packaged executable. It would buy crash isolation against a library
(libpipewire) that is loaded only while Live runs and is driven from its own
thread loop. On Linux, mic access needs no permission prompt outside
Flatpak. On macOS the TCC prompt attaches to the app bundle either way. The
engine has no GUI imports, so it can move into a helper later without a
rewrite. API keys never reach the GUI, only the 10-minute token does.

### Interaction

Hands-free by default, like mobile: provider server VAD does turn detection,
and barge-in works when the model starts talking over you
(`input_audio_buffer.speech_started` or Gemini `interrupted`), because the
playback ring is flushed at once. Controls:

- **Start and end:** the waveform button in the Companion header, or
  **Ctrl+Alt+Space** (`keybinds.companion_live`; in prefix mode `Shift+Space`,
  configurable under `keybinds.prefix.bindings` as `companion_live`). The
  keybind does not open the panel.
- **Call pill:** a floating bar in the Grok style. It sits over the top of
  the conversation when the panel is open, and just above the Companion
  bubble when it is collapsed. It holds:
  - the character, with a dotted level meter that rises with whoever is
    talking
  - **Settings:** a popover to pick the provider (only ones with a key) and
    the voice. A change restarts the call.
  - **Captions:** shows or hides the card with the last two spoken lines
  - **Mute** (**Ctrl+Alt+M**, `keybinds.companion_live_mute`)
  - a red **End**
- **Interrupt:** clicking the character in the pill while Moss speaks cuts it
  off, which is the half-duplex barge-in.
- **Transcript:** each finished exchange lands in the Companion chat as
  "You · voice" / "<Name> · voice" turns.

Push-to-talk can be added later with the same engine (send `input_audio_buffer.commit`
on release and turn server VAD off). It isn't needed for v1.

## Behaviour ported from mobile

- Protocols (`live_voice/protocol.zig`): `openai_realtime` (OpenAI GA session
  shape, and the xAI beta shape with cumulative transcripts) and
  `gemini_live`. These are pure functions from JSON in to normalized events
  out, unit tested.
- Transcript (`live_voice/transcript.zig`): a port of `LiveTranscript.kt`.
  It keeps one user line per turn, merges cumulative and partial
  transcripts, drops repeats, and adds system lines for tool hand-offs. Lines
  are appended to the Companion thread as `You (voice)`, `<Name> (voice)`,
  and `Live`. Saves happen every 2 min while the Companion is idle and on
  every ending. No audio is ever stored.
- Tools: `ask_companion` sends the request as a normal Companion turn,
  appended to any draft as mobile does, and injects `companion_update: …`
  when the turn finishes so the voice reads the reply out.
  `companion_status` reports crew and inbox. `decide_approval` matches the
  named chat in inbox, crew, or the Companion's own approval and resolves it.
- State machine (`live_voice/session.zig`): off → connecting → live
  (listening / thinking / speaking) → reconnecting (up to 3 times on drop or
  `goAway`) → failed. Silence for 2 min ends the session.

## Setup on Omarchy

None beyond an API key the daemon can see: `XAI_API_KEY`, `OPENAI_API_KEY`,
or `GEMINI_API_KEY` in the daemon's environment, or a key saved from the
phone app (`<pref>/voice.json`). PipeWire and the echo-cancel module are part
of the base install.

## Not yet

- macOS (CoreAudio VoiceProcessingIO gives AEC) and Windows (WASAPI plus the
  communications AEC effect) backends. The stubs return `error.Unsupported`.
- Typing an API key on the desktop. Today a key comes from the environment
  or the phone app.
- Device picker. Live follows the PipeWire default source and sink.
