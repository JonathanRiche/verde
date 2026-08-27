/**
 * JSON Schema for `verde.json`.
 *
 * Source of truth is the desktop parsers in
 * `packages/desktop/src/app/config.zig` and
 * `packages/desktop/src/app/keybinds.zig`. Unknown keys are ignored at
 * runtime; this schema is closed so editors can flag typos and offer
 * completions. Keep the property lists aligned with those parsers.
 */

import { SITE_ORIGIN } from './seo'

export const CONFIG_SCHEMA_PATH = '/config.schema.json'
export const CONFIG_SCHEMA_URL = `${SITE_ORIGIN}${CONFIG_SCHEMA_PATH}`

export interface JsonSchema {
  $schema?: string
  $id?: string
  $comment?: string
  title?: string
  description?: string
  markdownDescription?: string
  type?: string | string[]
  properties?: Record<string, JsonSchema>
  additionalProperties?: boolean | JsonSchema
  required?: string[]
  enum?: readonly (string | number | boolean | null)[]
  default?: unknown
  minimum?: number
  maximum?: number
  minItems?: number
  maxItems?: number
  minLength?: number
  maxLength?: number
  pattern?: string
  format?: string
  items?: JsonSchema
  oneOf?: JsonSchema[]
  anyOf?: JsonSchema[]
}

export const ROOT_KEYS = [
  '$schema',
  'ui',
  'theme',
  'open',
  'browser',
  'terminal',
  'transcript',
  'chat',
  'installed_themes',
  'updates',
  'notifications',
  'integrations',
  'keybinds',
] as const

export const UI_KEYS = [
  'font_size',
  'workspace_pane_gap',
  'workspace_panes_per_view',
  'workspace_split_default_pane',
  'workspace_scroll_direction',
  'workspace_scroll_mode',
  'workspace_scroll_threshold',
  'unzoom_on_pane_navigation',
  'reduced_motion',
  'workspace_tabs',
  'companion_enabled',
  'companion_character',
] as const

export const THEME_KEYS = ['theme', 'active', 'colors'] as const

export const THEME_COLOR_KEYS = [
  'background',
  'panel',
  'panel_alt',
  'panel_muted',
  'text',
  'text_muted',
  'text_subtle',
  'accent',
  'accent_dim',
  'border',
  'border_muted',
  'warning',
  'diff_add',
  'diff_remove',
  'selection',
] as const

export const OPEN_KEYS = [
  'default',
  'links',
  'chat_links',
  'terminal_links',
  'file_links_in_neovim_pane',
] as const

export const BROWSER_KEYS = ['scroll_speed', 'fast_scrolling'] as const

export const TERMINAL_KEYS = ['font_size', 'profiles'] as const

export const TRANSCRIPT_KEYS = [
  'tool_call_groups',
  'tool_call_groups_last_expanded',
  'diff_layout',
] as const

export const CHAT_KEYS = [
  'automatic_titles',
  'title_provider',
  'title_model',
  'default_provider',
  'default_model',
  'default_reasoning',
  'favorite_models',
  'new_pane_behavior',
] as const

export const UPDATES_KEYS = ['check_automatically'] as const
export const NOTIFICATIONS_KEYS = ['enabled'] as const
export const INTEGRATIONS_KEYS = ['mcp_enabled', 'mcp_onboarding_completed'] as const

export const KEYBIND_TOP_KEYS = [
  'refresh',
  'open',
  'open_editor',
  'new_thread',
  'command_palette',
  'companion',
  'sidebar',
  'sidebar_hidden',
  'browser',
  'terminal',
  'chat',
  'workspace',
  'prefix',
  'chat_up',
  'chat_down',
  'chat_page_up',
  'chat_page_down',
] as const

export const KEYBIND_CHAT_KEYS = ['model_picker', 'run_config', 'directory_picker'] as const

export const KEYBIND_TERMINAL_KEYS = [
  'toggle',
  'new_tab',
  'close',
  'rename_tab',
  'tab_previous',
  'tab_next',
  'split_up',
  'split_down',
  'split_left',
  'split_right',
  'focus_up',
  'focus_down',
  'focus_left',
  'focus_right',
] as const

export const KEYBIND_WORKSPACE_KEYS = [
  'split_chat_vertical',
  'split_chat_horizontal',
  'split_terminal_vertical',
  'split_terminal_horizontal',
  'toggle_maximize',
  'toggle_quick_pane',
  'close',
  'close_current',
  'focus_left',
  'focus_right',
  'focus_up',
  'focus_down',
  'focus_prompt',
  'active_select',
  'pane_select',
  'move_left',
  'move_right',
  'move_up',
  'move_down',
  'grow_left',
  'grow_right',
  'grow_up',
  'grow_down',
  'select',
  'previous',
  'next',
  'active_previous',
  'active_next',
  'pane_previous',
  'pane_next',
] as const

export const PREFIX_OBJECT_KEYS = ['enabled', 'key', 'defaults', 'bindings', 'navigate'] as const

/** Named prefix actions from `PREFIX_ACTION_NAMES` in keybinds.zig. */
export const PREFIX_ACTION_NAMES = [
  'refresh',
  'open',
  'open_default',
  'open_editor',
  'new_thread',
  'workspace.add',
  'new_terminal',
  'command_palette',
  'companion',
  'sidebar',
  'sidebar_hidden',
  'browser',
  'chat_up',
  'chat_down',
  'chat_page_up',
  'chat_page_down',
  'chat.model_picker',
  'chat.run_config',
  'chat.directory_picker',
  'terminal.toggle',
  'terminal.new_tab',
  'terminal.close',
  'terminal.rename_tab',
  'terminal.tab_previous',
  'terminal.tab_next',
  'terminal.split_up',
  'terminal.split_down',
  'terminal.split_left',
  'terminal.split_right',
  'terminal.focus_up',
  'terminal.focus_down',
  'terminal.focus_left',
  'terminal.focus_right',
  'workspace.split_default_vertical',
  'workspace.split_default_horizontal',
  'workspace.split_alternate_vertical',
  'workspace.split_alternate_horizontal',
  'workspace.split_chat_vertical',
  'workspace.split_chat_horizontal',
  'workspace.split_terminal_vertical',
  'workspace.split_terminal_horizontal',
  'workspace.toggle_maximize',
  'workspace.toggle_quick_pane',
  'workspace.close',
  'workspace.close_current',
  'workspace.focus_left',
  'workspace.focus_right',
  'workspace.focus_up',
  'workspace.focus_down',
  'workspace.focus_prompt',
  'prefix.keybinds',
  'prefix.navigate',
  'workspace.previous',
  'workspace.next',
  'workspace.active_previous',
  'workspace.active_next',
  'workspace.pane_previous',
  'workspace.pane_next',
  'workspace.move_left',
  'workspace.move_right',
  'workspace.move_up',
  'workspace.move_down',
  'workspace.grow_left',
  'workspace.grow_right',
  'workspace.grow_up',
  'workspace.grow_down',
] as const

export const PREFIX_COMMAND_PLACEMENTS = [
  'background',
  'detached',
  'terminal',
  'current',
  'focused',
  'pane',
  'new_pane',
  'new-pane',
  'new',
  'split',
  'horizontal',
  'split_horizontal',
  'split-horizontal',
  'vertical',
  'split_vertical',
  'split-vertical',
  'floating',
  'float',
  'quick',
  'tab',
] as const

export const CHAT_PROVIDERS = [
  'codex',
  'claude',
  'cursor',
  'opencode',
  'pi',
  'fx',
  'grok',
] as const

export const CHAT_TITLE_PROVIDERS = ['codex', 'claude', 'cursor', 'opencode'] as const

const keybindValue: JsonSchema = {
  description:
    'One accelerator, an array of accelerators, or null/empty to disable. Unknown keys are ignored.',
  oneOf: [
    { type: 'string', minLength: 0 },
    { type: 'array', items: { type: 'string' } },
    { type: 'null' },
  ],
}

const colorValue: JsonSchema = {
  description: 'Hex `#RRGGBB` / `#RRGGBBAA`, or an RGB/RGBA number array (0–1 or 0–255).',
  oneOf: [
    { type: 'string', pattern: '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$' },
    {
      type: 'array',
      minItems: 3,
      maxItems: 4,
      items: { type: 'number', minimum: 0, maximum: 255 },
    },
  ],
}

const themeColors: JsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: Object.fromEntries(
    THEME_COLOR_KEYS.map((key) => [key, colorValue]),
  ),
}

const themeSource: JsonSchema = {
  type: 'string',
  enum: ['omarchy', 'auto', 'default', 'verde'],
  description:
    '`omarchy`/`auto` follow Omarchy colors when present. `default`/`verde` use Verde built-in colors.',
}

function themeObject(includeActive: boolean): JsonSchema {
  const properties: Record<string, JsonSchema> = {
    theme: themeSource,
  }
  if (includeActive) {
    properties.active = {
      type: 'string',
      description: 'Name of an installed theme to activate.',
    }
  }
  properties.colors = themeColors
  return {
    type: 'object',
    additionalProperties: false,
    properties,
  }
}

const prefixActionName: JsonSchema = {
  description:
    'Built-in prefix action. Positional actions use a 1-based ordinal: `workspace.select.N`, `workspace.pane_select.N`, `workspace.active_select.N`.',
  anyOf: [
    { type: 'string', enum: PREFIX_ACTION_NAMES },
    {
      type: 'string',
      pattern: '^workspace\\.(select|pane_select|active_select)\\.[1-9][0-9]*$',
    },
  ],
}

const prefixCommandPlacement: JsonSchema = {
  type: 'string',
  enum: PREFIX_COMMAND_PLACEMENTS,
  description:
    'Where `{ "command" }` runs. Canonical values: `background`, `terminal`, `pane`, `split_horizontal`, `split_vertical`, `floating`, `tab`. Omitted `in` means `background`.',
}

const prefixBindingValue: JsonSchema = {
  description:
    'Action name, `null` to unbind, `{ "action" }`, or `{ "command", "in"? }`.',
  oneOf: [
    prefixActionName,
    { type: 'null' },
    {
      type: 'object',
      additionalProperties: false,
      required: ['action'],
      properties: {
        action: prefixActionName,
      },
    },
    {
      type: 'object',
      additionalProperties: false,
      required: ['command'],
      properties: {
        command: {
          type: 'string',
          minLength: 1,
          description:
            'Shell script. `$1` is the project path for background placement. Other placements run it as the pane PTY command.',
        },
        in: prefixCommandPlacement,
        open: {
          ...prefixCommandPlacement,
          description: 'Alias for `in`.',
        },
      },
    },
  ],
}

const prefixBindings: JsonSchema = {
  type: 'object',
  description:
    'Map of accelerators to prefix actions. A user entry replaces the default on the same chord; `null` removes it.',
  additionalProperties: prefixBindingValue,
}

const prefixObject: JsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    enabled: { type: 'boolean' },
    key: {
      ...keybindValue,
      description: 'Prefix chord. Default is `Ctrl+B`.',
    },
    defaults: {
      type: 'boolean',
      description: 'When `false`, start from an empty prefix table instead of the built-in bindings.',
    },
    bindings: prefixBindings,
    navigate: {
      ...prefixBindings,
      description: 'Second table used while navigate mode (`prefix` then `w`) is active.',
    },
  },
}

function closedObject(
  properties: Record<string, JsonSchema>,
  description?: string,
  required?: string[],
): JsonSchema {
  const schema: JsonSchema = {
    type: 'object',
    additionalProperties: false,
    properties,
  }
  if (description) schema.description = description
  if (required) schema.required = required
  return schema
}

const uiSchema = closedObject(
  {
    font_size: {
      type: 'number',
      minimum: 10,
      maximum: 32,
      default: 24,
      description: 'UI font size in points. Range 10–32; default 24.',
    },
    workspace_pane_gap: {
      type: 'number',
      minimum: 0,
      maximum: 64,
      default: 12,
      description: 'Gap between tiled panes, and outer margin for scrolling views. Range 0–64; default 12.',
    },
    workspace_panes_per_view: {
      type: 'integer',
      minimum: 1,
      maximum: 6,
      default: 2,
      description: 'How many panes fit in one scrolling view. Range 1–6; default 2.',
    },
    workspace_split_default_pane: {
      type: 'string',
      enum: ['chat', 'terminal'],
      description:
        'Unshifted prefix split keys (`v`, `-`) create this pane kind. Shifted variants create the other.',
    },
    workspace_scroll_direction: {
      type: 'string',
      enum: ['horizontal', 'vertical'],
    },
    workspace_scroll_mode: {
      type: 'string',
      enum: ['automatic', 'always', 'disabled'],
    },
    workspace_scroll_threshold: {
      type: 'integer',
      minimum: 1,
      maximum: 64,
      default: 2,
      description: 'Pane count that activates automatic scrolling. Range 1–64; default 2.',
    },
    unzoom_on_pane_navigation: { type: 'boolean' },
    reduced_motion: { type: 'boolean' },
    workspace_tabs: {
      type: 'string',
      enum: ['automatic', 'always', 'disabled'],
    },
    companion_enabled: {
      type: 'boolean',
      description: 'Experimental Companion sidecar. Off by default.',
    },
    companion_character: {
      type: 'string',
      enum: ['sprout', 'moss', 'vireo'],
      default: 'sprout',
    },
  },
  'Appearance and workspace layout.',
)

const openSchema = closedObject(
  {
    default: {
      description:
        'Workspace header primary open action. Named apps, or `{ label, action }` for a custom shell command.',
      oneOf: [
        { type: 'string', enum: ['folder', 'editor', 'cursor', 'vscode', 'zed'] },
        closedObject(
          {
            label: { type: 'string', minLength: 1 },
            action: {
              type: 'string',
              minLength: 1,
              description: 'Shell command. Working directory is the imported project.',
            },
          },
          undefined,
          ['label', 'action'],
        ),
      ],
    },
    links: {
      type: 'string',
      enum: ['verde_browser', 'system_browser'],
      description: 'Global destination for web links.',
    },
    chat_links: {
      type: 'string',
      enum: ['global', 'verde_browser', 'system_browser'],
      description: 'Override `open.links` for GUI chat links.',
    },
    terminal_links: {
      type: 'string',
      enum: ['global', 'verde_browser', 'system_browser'],
      description: 'Override `open.links` for terminal links.',
    },
    file_links_in_neovim_pane: { type: 'boolean' },
  },
  'How project files, folders, and links open.',
)

const browserSchema = closedObject(
  {
    scroll_speed: {
      type: 'number',
      minimum: 1,
      maximum: 5,
      default: 2.5,
      description: 'Embedded-page wheel speed. Range 1.0–5.0; default 2.5.',
    },
    fast_scrolling: {
      type: 'boolean',
      description:
        'Legacy. `true` maps to scroll_speed 2.5; `false` maps to 1.0. Prefer `scroll_speed`.',
    },
  },
  'Embedded browser.',
)

const terminalSchema = closedObject(
  {
    font_size: {
      type: 'number',
      minimum: 13.5,
      maximum: 60,
      default: 18,
      description: 'Terminal font size. Range 13.5–60; default 18.',
    },
    profiles: {
      type: 'array',
      items: closedObject(
        {
          label: { type: 'string', minLength: 1 },
          command: {
            type: 'array',
            minItems: 1,
            items: { type: 'string' },
            description: 'Argv for the profile command.',
          },
        },
        undefined,
        ['label', 'command'],
      ),
    },
  },
  'Terminal dock font and launch profiles.',
)

const transcriptSchema = closedObject(
  {
    tool_call_groups: {
      type: 'string',
      enum: ['collapsed', 'expanded', 'remember_last'],
    },
    tool_call_groups_last_expanded: {
      type: 'boolean',
      description: 'Internal last-expanded state used with `remember_last`.',
    },
    diff_layout: {
      type: 'string',
      enum: ['stacked', 'split'],
    },
  },
  'Chat transcript presentation.',
)

const chatSchema = closedObject(
  {
    automatic_titles: { type: 'boolean', default: true },
    title_provider: {
      type: 'string',
      enum: CHAT_TITLE_PROVIDERS,
    },
    title_model: { type: 'string' },
    default_provider: {
      type: 'string',
      enum: CHAT_PROVIDERS,
    },
    default_model: { type: 'string' },
    default_reasoning: {
      type: 'string',
      enum: ['default', 'low', 'medium', 'high', 'xhigh', 'max'],
    },
    favorite_models: {
      type: 'array',
      items: closedObject(
        {
          provider: { type: 'string', enum: CHAT_PROVIDERS },
          model: { type: 'string', minLength: 1 },
        },
        undefined,
        ['provider', 'model'],
      ),
    },
    new_pane_behavior: {
      type: 'string',
      enum: ['new_pane', 'replace_pane'],
    },
  },
  'New-chat defaults, titles, and favorite models.',
)

const keybindChatSchema = closedObject(
  Object.fromEntries(KEYBIND_CHAT_KEYS.map((key) => [key, keybindValue])),
)

const keybindTerminalObject = closedObject(
  Object.fromEntries(KEYBIND_TERMINAL_KEYS.map((key) => [key, keybindValue])),
)

const keybindWorkspaceSchema = closedObject(
  Object.fromEntries(KEYBIND_WORKSPACE_KEYS.map((key) => [key, keybindValue])),
)

const keybindsSchema = closedObject(
  {
    refresh: keybindValue,
    open: keybindValue,
    open_editor: keybindValue,
    new_thread: keybindValue,
    command_palette: keybindValue,
    companion: keybindValue,
    sidebar: keybindValue,
    sidebar_hidden: keybindValue,
    browser: keybindValue,
    terminal: {
      description:
        'String/`null` remaps the terminal toggle. An object remaps individual terminal actions.',
      oneOf: [keybindValue, keybindTerminalObject],
    },
    chat: keybindChatSchema,
    workspace: keybindWorkspaceSchema,
    prefix: {
      description:
        '`true`/`false` toggles prefix mode with defaults, a string sets the prefix chord, or an object configures the table.',
      oneOf: [{ type: 'boolean' }, { type: 'string' }, prefixObject],
    },
    chat_up: keybindValue,
    chat_down: keybindValue,
    chat_page_up: keybindValue,
    chat_page_down: keybindValue,
  },
  'Keyboard shortcuts. Loaded on startup and app refresh.',
)

export const verdeConfigSchema: JsonSchema = {
  $schema: 'http://json-schema.org/draft-07/schema#',
  $id: CONFIG_SCHEMA_URL,
  $comment:
    'Mirrors packages/desktop/src/app/config.zig and packages/desktop/src/app/keybinds.zig. Verde ignores unknown keys at runtime.',
  title: 'Verde config (verde.json)',
  description:
    'User config loaded from `$XDG_CONFIG_HOME/verde/verde.json` (or `%APPDATA%\\Verde\\verde.json` on Windows). Point editors here with `"$schema": "https://verdeai.dev/config.schema.json"`.',
  type: 'object',
  additionalProperties: false,
  properties: {
    $schema: {
      type: 'string',
      format: 'uri',
      description: 'JSON Schema URL for editor autocomplete. Verde ignores this key when loading config.',
    },
    ui: uiSchema,
    theme: themeObject(true),
    open: openSchema,
    browser: browserSchema,
    terminal: terminalSchema,
    transcript: transcriptSchema,
    chat: chatSchema,
    installed_themes: {
      type: 'array',
      description: 'Themes imported via `verde theme import`. Edited from Settings → Appearance.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'theme'],
        properties: {
          name: { type: 'string', minLength: 1, maxLength: 128 },
          theme: themeObject(false),
          ui_font_size: { type: 'number', minimum: 10, maximum: 32 },
          terminal_font_size: { type: 'number', minimum: 13.5, maximum: 60 },
        },
      },
    },
    updates: closedObject({
      check_automatically: { type: 'boolean', default: true },
    }),
    notifications: closedObject({
      enabled: { type: 'boolean' },
    }),
    integrations: closedObject({
      mcp_enabled: { type: 'boolean' },
      mcp_onboarding_completed: { type: 'boolean' },
    }),
    keybinds: keybindsSchema,
  },
}

export function renderConfigSchemaJson(): string {
  return `${JSON.stringify(verdeConfigSchema, null, 2)}\n`
}
