# Providers and transcripts

Provider surfaces intentionally differ. Read their source tables instead of copying one inventory:

| Surface | Source (relative to `src/`) |
| --- | --- |
| Native chat/configuration | `providers/types.zig`, `app/config.zig` |
| User-scoped MCP registration | `providers/mcp.zig` |
| Terminal lifecycle and CLI reporting | `providers/hooks.zig`, `cli/main.zig` (`integration_providers`) |

- Audit all applicable surfaces when changing a provider: native harness/config, MCP, terminal stack/default launcher, lifecycle hooks/plugins, CLI, settings, and tests. Preserve provider-specific registration formats. Treat `VERDE_SESSION_ID` as opaque; derive filesystem-safe state keys.
- Use the shared request/harness contract. Preserve every `SendPromptRequest.images` attachment and legacy `image`; visibly reject unsupported attachments. Verify text-only and multiple-image prompts.
- Show Fast/Default only for equivalent speed/service-tier capabilities; ignore unsupported `fast_changed` events.
- Stream assistant text via `on_stream_delta`, tool/system events via `on_stream_event`. Use short stable titles; command rows are `.system` authored exactly `Ran command` or `Command failed` (failure styling).
- Centralize new transcript categories in `ui/chat_panel.zig`. Verify tail auto-scroll, command/failure rows, and happy/error paths; follow [UI rules](../ui/AGENTS.md) for rendering/scrolling changes.
