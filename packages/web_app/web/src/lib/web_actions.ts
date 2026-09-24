//! Pure builders for chat/workspace actions the web client runs through the
//! shared daemon: agent TUI launch lines, handoff packages, and the Herdr
//! handoff script. They mirror the desktop's GUI-side builders
//! (terminal_controller.zig, workspace_controller.zig tuiResumeCommand,
//! chat/handoff.zig, herdr_controller.zig) so both clients produce the same
//! commands and text.

import type { LayoutNode, LivePane, Message } from './types'

/** Single-quote a word for POSIX sh. */
export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

/** Same defaults as terminal_controller.zig `defaultAgentTui`. */
export function agentTuiCommand(provider: string): string | null {
  switch (provider) {
    case 'codex': return 'codex'
    case 'claude': return 'claude'
    case 'opencode': return 'opencode'
    case 'cursor': return 'cursor-agent'
    case 'grok': return 'grok --no-auto-update --no-alt-screen --no-memory --disable-web-search --permission-mode plan --reasoning-effort low'
    case 'amp': return 'amp'
    case 'muse': return 'muse'
    case 'pi': return 'pi'
    case 'fx': return 'fx'
    default: return null
  }
}

/** Same resume lines as workspace_controller.zig `tuiResumeCommand`. */
export function agentResumeCommand(provider: string, providerThreadId: string): string | null {
  const id = shellQuote(providerThreadId)
  switch (provider) {
    case 'codex': return `codex resume ${id}`
    case 'opencode': return providerThreadId.startsWith('ses') ? `opencode --session ${id}` : 'opencode --continue'
    case 'claude': return `claude --resume ${id}`
    case 'cursor': return `agent --resume ${id}`
    case 'pi': return `pi --session-id ${id}`
    case 'grok': return `grok --resume ${id}`
    case 'muse': return `muse resume ${id}`
    case 'fx': return `fx --resume ${id}`
    default: return null
  }
}

/**
 * Run the agent under a login shell and drop back to an interactive shell
 * when it exits, so the pane stays usable like a desktop terminal dock.
 */
export function agentTerminalArgv(command: string): string[] {
  return ['/bin/sh', '-lc', `${command}; exec "\${SHELL:-/bin/sh}" -i`]
}

export const PROVIDER_LABELS: Record<string, string> = {
  codex: 'Codex', claude: 'Claude', opencode: 'OpenCode', cursor: 'Cursor',
  pi: 'Pi', fx: 'FX', grok: 'Grok', muse: 'Muse', amp: 'Amp',
}

export function providerLabel(provider: string | null | undefined): string {
  return PROVIDER_LABELS[provider ?? ''] ?? (provider || 'Agent')
}

/** handoff_controller.zig TARGET_PROVIDERS. */
export const HANDOFF_PROVIDERS = ['codex', 'opencode', 'claude', 'cursor', 'pi', 'fx', 'grok'] as const
/** Providers the daemon's provider.threads.list can import from. */
export const IMPORT_PROVIDERS = ['codex', 'opencode', 'claude'] as const
/** Providers provider.title.generate accepts. */
export const TITLE_PROVIDERS = ['codex', 'claude', 'cursor', 'opencode'] as const

export type HandoffContextMode = 'summary' | 'recent' | 'full'

export interface HandoffInput {
  workspace_id: string
  workspace_label: string
  workspace_path: string
  pane_id: number
  source_provider: string
  verde_thread_id?: string | null
  provider_thread_id?: string | null
  title: string
  messages: Pick<Message, 'role' | 'author' | 'body' | 'images'>[]
  process_context?: string
  context_mode: HandoffContextMode
}

const SENSITIVE = ['authorization:', 'bearer ', 'api_key', 'apikey', 'access_token', 'refresh_token', 'client_secret', 'password=', 'password:', 'private key', '-----begin']

function likelySensitive(line: string): boolean {
  const lower = line.toLowerCase()
  return SENSITIVE.some((pattern) => lower.includes(pattern))
}

function redactedBlock(raw: string, maxBytes: number): string {
  const clipped = raw.slice(0, maxBytes)
  let out = clipped.split('\n').map((line) => likelySensitive(line) ? '[redacted potentially sensitive line]' : line).join('\n') + '\n'
  if (clipped.length < raw.length) out += '[content truncated]\n'
  return out
}

function roleOf(role: string): 'user' | 'assistant' | 'system' {
  return role === 'user' ? 'user' : role === 'assistant' ? 'assistant' : 'system'
}

function messageBlock(message: HandoffInput['messages'][number]): string {
  return `### ${message.author} (${roleOf(message.role)})\n${redactedBlock(message.body, 12 * 1024)}\n`
}

function messagesSection(messages: HandoffInput['messages'], mode: HandoffContextMode): string {
  const max = 28 * 1024
  let out = ''
  if (mode === 'full') {
    for (const message of messages) {
      if (out.length >= max) { out += 'Transcript embedding limit reached; use the history commands above for the remainder.\n'; break }
      out += messageBlock(message)
    }
  } else if (mode === 'recent') {
    const start = Math.max(0, messages.length - 12)
    if (start > 0) out += `Earlier messages omitted (${start}); use the history commands above for the complete thread.\n\n`
    for (const message of messages.slice(start)) {
      if (out.length >= max) { out += 'Recent-message embedding limit reached; use the history commands above for the remainder.\n'; break }
      out += messageBlock(message)
    }
  } else {
    let first_user = -1, last_user = -1, last_assistant = -1
    messages.forEach((message, index) => {
      const role = roleOf(message.role)
      if (role === 'user') { if (first_user < 0) first_user = index; last_user = index }
      if (role === 'assistant') last_assistant = index
    })
    const picks = [...new Set([first_user, last_user, last_assistant].filter((index) => index >= 0))].sort((a, b) => a - b)
    for (const index of picks) {
      if (out.length >= max) break
      out += messageBlock(messages[index]!)
    }
    out += `Summary view selected (${messages.length} total messages). Use the history commands above for the complete thread.\n`
  }
  return out
}

/** Port of chat/handoff.zig `buildAlloc` for a GUI-chat source. */
export function buildHandoffPackage(input: HandoffInput): string {
  const field = (label: string, value: string) => `- ${label}: ${value}\n`
  let out = '# Verde agent handoff\n\nContinue the work described below. This is provider-neutral context copied from another Verde surface.\n\n## Source identity\n\n'
  out += field('Workspace', input.workspace_label)
  out += field('Workspace ID', input.workspace_id)
  out += field('Workspace path', input.workspace_path)
  out += `- Active Verde pane ID: ${input.pane_id}\n`
  out += field('Source surface', 'gui_chat')
  out += field('Source provider', input.source_provider)
  if (input.verde_thread_id) out += field('Verde local thread ID', input.verde_thread_id)
  if (input.provider_thread_id) {
    out += field('Source provider thread ID', input.provider_thread_id)
    out += "- Provider-ID scope: source provider only; do not use this ID as the target provider's thread ID.\n"
  }
  out += field('Source title', input.title)

  out += '\n## Attachment disclosure\n\n'
  const attachments = input.messages.flatMap((message) => message.images ?? [])
  if (attachments.length === 0) out += '- No GUI chat attachments were present.\n'
  else {
    out += '- Attachment bytes are not shared by this handoff. Source references:\n'
    for (const attachment of attachments) {
      const name = attachment.name ?? attachment.path.split('/').pop() ?? 'attachment'
      out += `  - ${likelySensitive(name) ? '[redacted attachment name]' : name} (${attachment.mime}, ${attachment.byte_size ?? 0} bytes)\n`
    }
  }

  out += '\n## Retrieve more Verde history\n\n'
  const thread_ref = input.provider_thread_id ?? input.verde_thread_id
  if (thread_ref) out += `- Complete persisted thread: \`verde state transcript --workspace ${input.workspace_id} --thread ${thread_ref} --json\`\n`
  out += `- Active pane while Verde is running: \`verde live chat transcript --workspace ${input.workspace_id} --pane ${input.pane_id} --json\`\n`
  out += '- Discover current commands first when needed: `verde capabilities --json` and `verde live capabilities --json`.\n'

  out += '\n## Objective and conversation context\n\n'
  out += input.messages.length > 0 ? messagesSection(input.messages, input.context_mode) : 'No transcript was available from the source surface.\n'

  if (input.process_context) out += '\n## Active processes\n\n' + redactedBlock(input.process_context, 4 * 1024)

  out += '\n## Safety and continuation instructions\n\n'
  out += '- The source thread and pane remain unchanged.\n'
  out += '- Re-check the workspace before changing files because this snapshot may become stale.\n'
  out += '- Credentials, authorization headers, and likely secret-bearing lines were excluded by default.\n'
  out += '- Review unresolved approvals in the conversation before taking privileged or destructive actions.\n'
  out += '- Ask the user when authority is missing; do not infer approval from this handoff.'
  return out
}

/** First user message and the first assistant reply after it (chat_controller.zig `openingExchange`). */
export function openingExchange(messages: Pick<Message, 'role' | 'body' | 'tool_call_id'>[]): { user: string; assistant: string } | null {
  const user_index = messages.findIndex((message) => message.role === 'user')
  if (user_index < 0) return null
  const assistant = messages.slice(user_index + 1).find((message) => message.role === 'assistant' && !message.tool_call_id && message.body.trim())
  if (!assistant) return null
  return { user: messages[user_index]!.body.slice(0, 4096), assistant: assistant.body.slice(0, 4096) }
}

export const HERDR_LINK_MARKER = 'VERDE-HERDR-LINK'

export interface HerdrPanePlan {
  title: string
  command: string | null
}

/** herdr_controller.zig `herdrAgentCommandForProvider`. */
export function herdrAgentCommand(provider: string | undefined, providerThreadId: string | null | undefined): string | null {
  if (providerThreadId) {
    const id = shellQuote(providerThreadId)
    switch (provider) {
      case 'codex': return `codex resume ${id}`
      case 'claude': return `claude --resume ${id}`
      case 'opencode': return providerThreadId.startsWith('ses') ? `opencode --session ${id}` : 'opencode'
      case 'cursor': return `agent --resume ${id}`
      default: return null
    }
  }
  switch (provider) {
    case 'codex': return 'codex'
    case 'claude': return 'claude'
    case 'opencode': return 'opencode'
    case 'cursor': return 'cursor-agent'
    default: return null
  }
}

export function herdrPanePlan(pane: LivePane, title: string): HerdrPanePlan {
  if (pane.kind === 'chat') return { title: `${title} GUI`, command: herdrAgentCommand(pane.provider, pane.provider_thread_id) }
  if (pane.kind === 'terminal') return { title: `Terminal ${pane.dock_id ?? pane.pane_id}`, command: null }
  return { title: `Browser: ${title}`, command: null }
}

/**
 * Shell script that mirrors a pane tree into Herdr like
 * herdr_controller.zig `handoffProjectToHerdr`, prints one marker line the
 * web client records as the workspace's herdr_link, then attaches.
 */
export function buildHerdrHandoffScript(options: {
  session: string
  label: string
  cwd: string
  existing_workspace_id?: string | null
  layout: LayoutNode | null
  panes: ReadonlyMap<number, HerdrPanePlan>
}): string {
  const q = shellQuote
  const lines = [
    'set -e',
    'H="${HERDR_BIN:-herdr}"',
    `S=${q(options.session)}`,
    `CWD=${q(options.cwd)}`,
    // herdr prints JSON; take the first string value for a key.
    'field() { printf "%s" "$1" | tr -d "\\n" | sed -n "s/.*\\"$2\\"[[:space:]]*:[[:space:]]*\\"\\([^\\"]*\\)\\".*/\\1/p" | head -n 1; }',
    'echo "Handing this workspace off to Herdr session $S..."',
  ]
  if (options.existing_workspace_id) {
    lines.push(`W=${q(options.existing_workspace_id)}`)
    lines.push(`OUT=$("$H" --session "$S" tab create --workspace "$W" --cwd "$CWD" --label ${q(`Verde: ${options.label}`)} --no-focus)`)
  } else {
    lines.push(`OUT=$("$H" --session "$S" workspace create --cwd "$CWD" --label ${q(options.label)} --no-focus)`)
    lines.push('W=$(field "$OUT" workspace_id)')
  }
  lines.push('P0=$(field "$OUT" pane_id)')
  lines.push('[ -n "$W" ] && [ -n "$P0" ] || { echo "Herdr did not return a workspace/pane id: $OUT"; exit 1; }')
  let counter = 0
  const mirror = (node: LayoutNode, pane_var: string) => {
    if ('leaf' in node) {
      const plan = options.panes.get(node.leaf)
      if (!plan) return
      lines.push(`"$H" --session "$S" pane rename "$${pane_var}" ${q(plan.title)} >/dev/null`)
      if (plan.command) lines.push(`"$H" --session "$S" pane run "$${pane_var}" ${q(plan.command)} >/dev/null`)
      return
    }
    const ratio = Math.min(0.95, Math.max(0.05, node.split.ratio))
    const direction = node.split.axis === 'vertical' ? 'right' : 'down'
    const next = `P${++counter}`
    lines.push(`OUT=$("$H" --session "$S" pane split "$${pane_var}" --direction ${direction} --ratio ${ratio} --cwd "$CWD" --no-focus)`)
    lines.push(`${next}=$(field "$OUT" pane_id)`)
    mirror(node.split.first, pane_var)
    mirror(node.split.second, next)
  }
  if (options.layout) mirror(options.layout, 'P0')
  lines.push(`echo "${HERDR_LINK_MARKER} $W $P0"`)
  lines.push('exec "$H" --session "$S"')
  return lines.join('\n')
}

/** Parse the handoff script's marker line out of terminal output. */
export function parseHerdrLinkMarker(text: string): { workspace_id: string; pane_id: string } | null {
  const match = new RegExp(`${HERDR_LINK_MARKER} (\\S+) (\\S+)`).exec(text)
  return match ? { workspace_id: match[1]!, pane_id: match[2]! } : null
}

/** Chain a workspace's pane groups side by side, like the web canvas shows them. */
export function chainLayouts(layouts: LayoutNode[]): LayoutNode | null {
  if (layouts.length === 0) return null
  return layouts.reduceRight((second, first) => ({ split: { axis: 'vertical', ratio: 0.5, first, second } }))
}
