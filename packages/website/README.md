# Verde website

The marketing site for Verde, served at [verdeai.dev](https://verdeai.dev). It is
a [SolidJS](https://www.solidjs.com/) + [TanStack Start](https://tanstack.com/start)
app styled with [Tailwind CSS v4](https://tailwindcss.com/) and a hand-written
design system in `src/styles.css`, built with Vite and deployed to Cloudflare
Workers via [Alchemy](https://alchemy.run/).

The homepage also serves the install script at
[`verdeai.dev/install.sh`](https://verdeai.dev/install.sh) (see
`src/routes/install[.]sh.ts`).

## Commands

Run from `packages/website` with `bun`:

```bash
bun install
bun run dev      # alchemy dev — local development (use this)
bun run build    # vite build → dist/client + dist/server
bun run deploy   # alchemy deploy → Cloudflare (production: verdeai.dev)
```

> **Heads up:** prefer `bun run dev` (`alchemy dev`) over raw `vite dev`. A custom
> Vite plugin (`serveStaleClientAssetsFromDist`) serves images/CSS/fonts from the
> last `bun run build`, so under raw `vite dev` those assets do **not** hot-reload
> until you rebuild. Component logic in `.tsx` still hot-reloads. See
> [`CLAUDE.md`](CLAUDE.md) for the full explanation and other notes.

## Layout

- `src/routes/index.tsx` — the entire homepage (hero, providers, feature rows,
  command-palette and tiling CSS mockups, feature grid, keybinds, CLI examples,
  comparison table, install, footer). Page copy lives in plain data arrays near
  the top of the file.
- `src/styles.css` — all styling. Design tokens at the top mirror the desktop
  theme (`packages/desktop/src/ui/theme.zig`): dark background, warm-green accent.
- `src/components/Header.tsx` — sticky nav; its anchors match the section `id`s
  in `index.tsx`.
- `src/routes/__root.tsx` — HTML shell, `<head>` meta and Open Graph tags.

## Keeping content honest

Marketing copy must reflect what the desktop app actually ships. When provider,
keybind, command-palette, or CLI behavior changes in `packages/desktop`, update
this site to match — see [`CLAUDE.md`](CLAUDE.md) for the sources of truth.
