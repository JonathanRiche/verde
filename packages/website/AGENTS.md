# Verde website

This directory contains the SolidJS and TanStack Start marketing/documentation
site deployed to Cloudflare Workers through Alchemy.

## Commands

Run website commands from `packages/website` with Bun.

- Local development: `bun run dev` (`alchemy dev`). This is the supported and
  required default for agents because it provisions the local Cloudflare
  bindings used by the app.
- Tests: `bun test`.
- Production build: `bun run build`.
- Compiled preview: `bun run preview`. Use this to inspect an existing build,
  not as the normal development server; it does not provide source hot reload.
- Cloudflare types: `bun run types`.
- Production deploy: `bun run deploy` (`alchemy deploy`). Deploy only when the
  user explicitly requests it.
- Resource teardown: `bun run destroy` (`alchemy destroy`). This is destructive
  and requires explicit user authorization.

Do not run raw `vite dev`. The Alchemy dev entrypoint in `alchemy.run.ts` owns
the Vite process and local Cloudflare configuration. Bypassing it can serve
stale hashed assets from `dist/client`, omit required bindings, and produce a
page that does not hydrate correctly.

Before handing off website changes, run `bun test` and `bun run build`.

## Content and structure

- `src/routes/index.tsx` contains the homepage sections and marketing copy.
- `src/styles.css` contains the shared design system.
- `src/content/docs/*.md` contains documentation pages.
- `src/content/docs/index.ts` is the docs registry and the source of truth for
  navigation, raw Markdown routes, `/llms.txt`, and `/llms-full.txt`.
- `src/lib/config-schema.ts` is the JSON Schema for `verde.json`, hosted at
  `/config.schema.json`. Keep property lists aligned with
  `packages/desktop/src/app/config.zig` and
  `packages/desktop/src/app/keybinds.zig`.
- `src/routes/__root.tsx` owns the HTML shell and site metadata.
- `alchemy.run.ts` owns the Cloudflare deployment and local-development setup.

Keep product claims synchronized with the desktop implementation. Useful
sources of truth include:

- Providers and models: `packages/desktop/src/providers/types.zig`,
  `packages/desktop/src/state/provider_models.zig`, and provider
  implementations under `packages/desktop/src/providers`.
- Keybinds: `packages/desktop/src/app/keybinds.zig`.
- Command palette and slash commands: `packages/desktop/src/ui/command_palette.zig`
  and `packages/desktop/src/chat/slash_commands.zig`.
- CLI: `packages/desktop/src/cli/spec.zig` and
  `packages/desktop/src/cli/main.zig`.
- Browser and Design Mode: `packages/desktop/src/ui/browser.zig` and the browser
  backend implementations.

Do not invent shortcuts, provider capabilities, platform support, or CLI flags.
