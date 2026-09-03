import { describe, expect, test } from 'bun:test'

import { SITE_ORIGIN } from './seo'
import {
  BROWSER_KEYS,
  CHAT_KEYS,
  CHAT_PROVIDERS,
  CHAT_TITLE_PROVIDERS,
  CONFIG_SCHEMA_URL,
  INTEGRATIONS_KEYS,
  KEYBIND_CHAT_KEYS,
  KEYBIND_TERMINAL_KEYS,
  KEYBIND_TOP_KEYS,
  KEYBIND_WORKSPACE_KEYS,
  NOTIFICATIONS_KEYS,
  OPEN_KEYS,
  PREFIX_ACTION_NAMES,
  PREFIX_COMMAND_PLACEMENTS,
  PREFIX_OBJECT_KEYS,
  ROOT_KEYS,
  TERMINAL_KEYS,
  THEME_COLOR_KEYS,
  THEME_KEYS,
  TRANSCRIPT_KEYS,
  UI_KEYS,
  UPDATES_KEYS,
  renderConfigSchemaJson,
  verdeConfigSchema,
  type JsonSchema,
} from './config-schema'

function propertiesOf(schema: JsonSchema | undefined): string[] {
  return Object.keys(schema?.properties ?? {})
}

function child(schema: JsonSchema, key: string): JsonSchema {
  const child_schema = schema.properties?.[key]
  expect(child_schema).toBeDefined()
  return child_schema!
}

describe('verde.json JSON Schema', () => {
  test('hosts a stable production URL', () => {
    expect(CONFIG_SCHEMA_URL).toBe('https://verdeai.dev/config.schema.json')
    expect(verdeConfigSchema.$id).toBe(CONFIG_SCHEMA_URL)
    expect(verdeConfigSchema.$schema).toBe('http://json-schema.org/draft-07/schema#')
    expect(SITE_ORIGIN).toBe('https://verdeai.dev')
  })

  test('docs and llms.txt point editors at the hosted schema', async () => {
    const configDoc = await Bun.file(new URL('../content/docs/config.md', import.meta.url)).text()
    const keybindsDoc = await Bun.file(new URL('../content/docs/keybinds.md', import.meta.url)).text()
    const llmsSource = await Bun.file(new URL('../content/docs/index.ts', import.meta.url)).text()
    expect(configDoc).toContain(CONFIG_SCHEMA_URL)
    expect(keybindsDoc).toContain(CONFIG_SCHEMA_URL)
    expect(llmsSource).toContain('/config.schema.json')
  })

  test('covers every top-level parser key and closes unknown properties', () => {
    expect(propertiesOf(verdeConfigSchema)).toEqual([...ROOT_KEYS])
    expect(verdeConfigSchema.additionalProperties).toBe(false)
    expect(verdeConfigSchema.type).toBe('object')
  })

  test('covers ui, theme, open, browser, terminal, transcript, and chat keys', () => {
    expect(propertiesOf(child(verdeConfigSchema, 'ui'))).toEqual([...UI_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'theme'))).toEqual([...THEME_KEYS])
    expect(propertiesOf(child(child(verdeConfigSchema, 'theme'), 'colors'))).toEqual([
      ...THEME_COLOR_KEYS,
    ])
    expect(propertiesOf(child(verdeConfigSchema, 'open'))).toEqual([...OPEN_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'browser'))).toEqual([...BROWSER_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'terminal'))).toEqual([...TERMINAL_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'transcript'))).toEqual([...TRANSCRIPT_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'chat'))).toEqual([...CHAT_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'updates'))).toEqual([...UPDATES_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'notifications'))).toEqual([...NOTIFICATIONS_KEYS])
    expect(propertiesOf(child(verdeConfigSchema, 'integrations'))).toEqual([...INTEGRATIONS_KEYS])
  })

  test('covers every keybind parser key including prefix command placement', () => {
    const keybinds = child(verdeConfigSchema, 'keybinds')
    expect(propertiesOf(keybinds)).toEqual([...KEYBIND_TOP_KEYS])

    const chat = child(keybinds, 'chat')
    expect(propertiesOf(chat)).toEqual([...KEYBIND_CHAT_KEYS])

    const workspace = child(keybinds, 'workspace')
    expect(propertiesOf(workspace)).toEqual([...KEYBIND_WORKSPACE_KEYS])
    expect(child(workspace, 'close').description).toContain('Unbound by default')
    expect(child(workspace, 'close').description).toContain('Alt+X')
    expect(child(workspace, 'active_select').description).toContain('Active')
    expect(child(workspace, 'active_previous').description).toContain('Alt+Left')

    const terminalOneOf = child(keybinds, 'terminal').oneOf
    expect(terminalOneOf).toHaveLength(2)
    const terminalObject = terminalOneOf!.find((entry) => entry.properties)
    expect(propertiesOf(terminalObject)).toEqual([...KEYBIND_TERMINAL_KEYS])

    const prefixOneOf = child(keybinds, 'prefix').oneOf
    const prefixObject = prefixOneOf?.find((entry) => entry.properties)
    expect(propertiesOf(prefixObject)).toEqual([...PREFIX_OBJECT_KEYS])

    const commandObject = prefixObject?.properties?.bindings?.additionalProperties
    expect(commandObject).toBeDefined()
    const commandShape = (commandObject as JsonSchema).oneOf?.find(
      (entry) => entry.required?.includes('command'),
    )
    expect(commandShape?.properties?.in?.enum).toEqual([...PREFIX_COMMAND_PLACEMENTS])
    expect(commandShape?.properties?.open?.enum).toEqual([...PREFIX_COMMAND_PLACEMENTS])
  })

  test('lists every named prefix action from keybinds.zig', () => {
    expect(PREFIX_ACTION_NAMES).toHaveLength(67)
    expect(new Set(PREFIX_ACTION_NAMES).size).toBe(PREFIX_ACTION_NAMES.length)

    const keybinds = child(verdeConfigSchema, 'keybinds')
    const prefixObject = child(keybinds, 'prefix').oneOf?.find((entry) => entry.properties)
    const bindingValue = prefixObject?.properties?.bindings?.additionalProperties as JsonSchema
    const named = bindingValue.oneOf?.[0]?.anyOf?.[0]
    expect(named?.enum).toEqual([...PREFIX_ACTION_NAMES])
  })

  test('uses parser enums for providers, placement, and companion', () => {
    const chat = child(verdeConfigSchema, 'chat')
    expect(child(chat, 'default_provider').enum).toEqual([...CHAT_PROVIDERS])
    expect(child(chat, 'title_provider').enum).toEqual([...CHAT_TITLE_PROVIDERS])
    expect(child(chat, 'default_reasoning').enum).toEqual([
      'default',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ])

    const ui = child(verdeConfigSchema, 'ui')
    expect(child(ui, 'companion_character').enum).toEqual(['sprout', 'moss', 'vireo'])
    expect(child(ui, 'workspace_split_default_pane').enum).toEqual(['chat', 'terminal'])
    expect(child(ui, 'font_size').minimum).toBe(10)
    expect(child(ui, 'font_size').maximum).toBe(32)
    expect(child(child(verdeConfigSchema, 'terminal'), 'font_size').minimum).toBe(13.5)
    expect(child(child(verdeConfigSchema, 'browser'), 'scroll_speed').maximum).toBe(5)
  })

  test('serializes as pretty JSON and closes nested objects', () => {
    const body = renderConfigSchemaJson()
    const parsed = JSON.parse(body) as JsonSchema
    expect(parsed.$id).toBe(CONFIG_SCHEMA_URL)
    expect(body.endsWith('\n')).toBe(true)

    const closed = [
      parsed,
      child(parsed, 'ui'),
      child(parsed, 'theme'),
      child(child(parsed, 'theme'), 'colors'),
      child(parsed, 'open'),
      child(parsed, 'keybinds'),
      child(child(parsed, 'keybinds'), 'workspace'),
    ]
    for (const schema of closed) {
      expect(schema.additionalProperties).toBe(false)
    }
  })
})
