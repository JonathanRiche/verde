# Terminal engine

- Use upstream `ghostty-org/ghostty`; no vendored source tree. Only `engine.zig` imports `ghostty-vt`; name engine types through that boundary.
- Desktop `build.zig.zon` and the official web wasm must pin the same commit. Web pin/hash/bump instructions: [ghostty-vt.NOTICE.md](../../../web_app/web/src/assets/ghostty-vt.NOTICE.md).
- For bumps, verify the Zig archive hash with `zig fetch` in a scratch project, replace the matching wasm, and audit `engine.zig` / `terminal.zig` API drift. Finish with `mise run build` for this dependency/payload change. Do not introduce third-party wasm wrappers.
