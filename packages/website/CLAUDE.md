# AGENTS.md — `packages/website`

The Verde marketing site (https://verdeai.dev). SolidJS + TanStack Start
(`@tanstack/solid-start`) + Tailwind v4, built with Vite and deployed to
Cloudflare Workers via **Alchemy**.

## Commands

Run these from `packages/website` (the repo uses `bun`):

- **Dev:** `bun run dev` → `alchemy dev`. **Use this for local development**, not
  raw `vite dev`. See the asset gotcha below for why.
- **Build:** `bun run build` → `vite build`. Emits `dist/client` (browser bundle +
  hashed assets) and `dist/server` (SSR).
- **Deploy:** `bun run deploy` → `alchemy deploy`. Publishes to Cloudflare. This
  is the live production site — only deploy when the user asks.
- **Destroy:** `bun run deploy`'s counterpart is `bun run destroy` (tears down the
  Alchemy-managed resources). Don't run it casually.

## Asset-serving gotcha (important)

`vite.config.ts` has a custom plugin, `serveStaleClientAssetsFromDist`. In dev,
TanStack Start's SSR manifest references `/assets/*` hashed files from the **last
client build**, which `vite dev` does not emit — so the plugin serves
images/CSS/fonts out of `dist/client/`.

Consequences when you run **raw `vite dev`** (e.g. `bun run dev:vite`):

- Edits to **images, `styles.css`, or fonts do not hot-reload.** The page keeps
  showing whatever the last `bun run build` produced, because those assets come
  from `dist/client`, and the SSR manifest is pinned to that build.
- To see asset/style changes you must `bun run build` **and restart** the server.

`bun run dev` (`alchemy dev`) is the supported dev path and avoids this; prefer
it. If you must use raw `vite dev`, remember: **rebuild after any asset/CSS
change.** (JS is deliberately excluded from the stale-asset plugin, so component
logic in `.tsx` does hot-reload.)

## Where things live

- `src/routes/index.tsx` — the entire homepage (hero, providers, feature rows,
  command-palette + tiling CSS mockups, feature grid, keybinds, CLI, comparison
  table, install, footer). Content is plain data arrays near the top of the file.
- `src/styles.css` — all styling. Design tokens at the top are derived from the
  desktop theme (`packages/desktop/src/ui/theme.zig`, `colors.zig`): dark bg,
  warm-green accent, amber counterpoint. Keep brand parity with the app.
- `src/components/Header.tsx` — sticky nav; its anchors must match section `id`s
  in `index.tsx`.
- `src/routes/__root.tsx` — `<head>` meta/OG tags and the HTML shell.
- Provider logos / hero screenshot are imported from `packages/desktop/src/assets`
  and the repo-root `assets/` dir. `.app-screenshot`'s `aspect-ratio` is matched
  to the source image so it renders uncropped — update it if you swap the image.

## Keeping the feature list honest

The marketing copy must reflect what the app actually ships. When desktop
features change, update the site to match. Sources of truth:

- **Providers:** `packages/desktop/src/provider_types.zig` (currently Codex,
  Claude Code, OpenCode, Cursor).
- **Keybinds:** `packages/desktop/src/keybinds.zig` (the `cloneDefault*Keybinds`
  fns hold the real defaults). Don't invent shortcuts.
- **Command palette / slash commands:** `src/ui/command_palette.zig` and
  `src/slash_commands.zig` (`/stack`, `/process`).
- **CLI surface:** the root `AGENTS.md` "CLI And Live-Control Testing" section.

## Verifying visually without a browser window

Headless Chromium works for screenshots (`chromium --headless=new
--screenshot=... http://localhost:<port>/`). Fragment scrolling (`/#section`) is
NOT honored by headless screenshots — capture one tall `--window-size=1400,7200`
full-page render and slice it with ImageMagick (`magick in.png -crop WxH+0+Y`)
to inspect lower sections. Use a fresh `--user-data-dir` to avoid stale caches.
