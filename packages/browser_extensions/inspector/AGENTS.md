# Inspector overlay

Follow the [root rules](../../../AGENTS.md). This Bun package builds the embeddable browser overlay from `src/entry-embed.ts` to `dist/inspector.js`.

- Use Bun tooling and the existing `Bun.serve` HTML-import playground; do not introduce another dev server/bundler or generic backend dependencies.
- Run package commands here: `bun run dev`, `bun run typecheck`, `bun run build`; `bun run build:playground` checks the standalone playground. Verify code changes with typecheck and build.
- Read the actual port from dev-server output (or set `PORT`); follow root resource/browser ownership rules.
- Playground usage and interaction coverage: [README](README.md). Preserve the structured events consumed by the Zig browser bridge.
