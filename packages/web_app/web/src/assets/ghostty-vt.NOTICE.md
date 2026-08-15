# ghostty-vt.wasm

Official pre-built libghostty-vt WebAssembly artifact, vendored verbatim.

- Upstream: https://github.com/ghostty-org/ghostty
- Pin: `d760ee96e54657416eb427b793c7e839f003df7d`
- Source URL (immutable): https://tip.files.ghostty.org/d760ee96e54657416eb427b793c7e839f003df7d/ghostty-vt.wasm
- SHA-256: `429a012aa07105f158a01676c5c02d852cc0b31a4ca6c04d95ab2338df3f837a`
- Requires WebAssembly SIMD128 (no scalar fallback build).

To bump the pin: replace the commit hash in the URL, verify the new SHA-256,
update this file and the header comment in `../lib/ghostty_vt.ts`, and re-run
the binding's functional test against the new artifact before shipping.

## Licenses

This binary embeds the following third-party works:

- **Ghostty** — MIT License, © Mitchell Hashimoto
  https://github.com/ghostty-org/ghostty/blob/main/LICENSE
- **simdutf** — MIT License (dual MIT/Apache-2.0)
  https://github.com/simdutf/simdutf
- **Google Highway** — Apache License 2.0
  https://github.com/google/highway/blob/master/LICENSE
