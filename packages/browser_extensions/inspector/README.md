# inspector

Standalone Bun package for the in-page Verde inspector overlay.

The package produces a single embeddable browser bundle at `dist/inspector.js`
and also includes a local playground for iterating on the overlay without
touching the Zig app.

## Commands

```bash
bun install
bun run typecheck
bun run build
bun run build:playground
bun run dev
```

## Local playground

```bash
bun run dev
```

The dev server prints the bound localhost URL on startup. You can also pin it:

```bash
PORT=4173 bun run dev
```

The playground exercises:

- hover highlight with margin, border, padding, and content regions
- click-to-freeze selection
- fixed prompt textarea overlay
- structured event emission intended for later Zig/CEF integration
