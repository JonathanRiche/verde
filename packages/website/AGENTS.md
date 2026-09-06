# Website

Follow the [root rules](../../AGENTS.md). SolidJS/TanStack Start marketing and docs, deployed to Cloudflare Workers through Alchemy.

## Commands

Run with Bun from `packages/website`:

| Work | Command |
| --- | --- |
| Development | `bun run dev` (Alchemy; required default) |
| Verify site changes | `bun test` and `bun run build` |
| Preview existing build | `bun run preview` (no hot reload) |
| Cloudflare types | `bun run types` |
| Deploy / destroy resources | `bun run deploy` / `bun run destroy`; explicit user authorization required |

Never use raw `vite dev`: `alchemy.run.ts` owns Vite and required Cloudflare bindings; bypassing it can serve stale assets or break hydration.

## Sources of truth

- Homepage: `src/routes/index.tsx`; styles: `src/styles.css`; HTML/metadata: `src/routes/__root.tsx`.
- Docs: `src/content/docs/*.md`; `src/content/docs/index.ts` owns navigation, raw Markdown, and LLM routes.
- `src/lib/config-schema.ts` serves `/config.schema.json`; align it with desktop `app/config.zig` and `app/keybinds.zig`.
- Check product claims against desktop sources: `providers/types.zig`, `state/provider_models.zig`, provider implementations, `app/keybinds.zig`, `ui/command_palette.zig`, `chat/slash_commands.zig`, `cli/spec.zig`, `cli/main.zig`, and browser implementations (all under `packages/desktop/src`). Never invent capabilities, shortcuts, platform support, or CLI flags.
