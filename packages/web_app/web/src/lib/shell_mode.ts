import { unwrapResult } from './live'
import type { Message, RpcEnvelope, Thread } from './types'

/** Result of the daemon's `chat.shell.run` (composer `!command`). */
export interface ShellRunResult {
  status: 'completed' | 'failed' | 'timed_out'
  exit_code?: number | null
  cwd: string
  shell: string
  duration_ms: number
  truncated?: boolean
  command_message_id: string
  result_message_id: string
}

export type ShellRunOutcome =
  | { kind: 'ran'; result: ShellRunResult; notice: string }
  | { kind: 'declined'; notice: string }
  | { kind: 'failed'; notice: string }

/**
 * Same working-directory fields as `chat.turn.start`: routed chats send only
 * the repository route (the daemon resolves it through its own binding),
 * legacy local chats name the workspace root the daemon verifies.
 */
export function shellRunParams(
  ids: { workspace_id: string; local_thread_id: string },
  command: string,
  thread: Pick<Thread, 'repository_id' | 'repository_cwd'>,
  remote: boolean,
  workspacePath: string,
) {
  const routed = remote || Boolean(thread.repository_cwd) || Boolean(thread.repository_id && thread.repository_id !== 'primary')
  return {
    ...ids,
    command,
    ...(routed
      ? { repository_id: thread.repository_id ?? 'primary', relative_cwd: thread.repository_cwd ?? null }
      : { project_path: workspacePath }),
  }
}

/** Optimistic rows shown until the daemon-committed transcript reloads (desktop parity). */
export function pendingShellRows(command: string, now: number, ids: { command: string; running: string }): Message[] {
  return [
    { message_id: ids.command, role: 'user', author: 'You', body: `!${command}`, created_at_ms: now },
    {
      message_id: ids.running, role: 'system', author: 'Running command', body: `$ ${command}\n\nStatus: running`,
      tool_call_kind: 'execute', tool_call_status: 'in_progress', created_at_ms: now,
    },
  ]
}

/**
 * Runs one composer shell command through the daemon. The daemon owns the
 * approval policy (destructive commands, supervised chats); when it asks for
 * confirmation the user is prompted and the request is resent once.
 */
export async function runComposerShellCommand(
  deps: { call: (params: Record<string, unknown>) => Promise<RpcEnvelope>; confirm: (message: string) => boolean | Promise<boolean> },
  params: Record<string, unknown>,
): Promise<ShellRunOutcome> {
  let response = await deps.call(params)
  if (response.error?.code === 'confirmation_required') {
    const command = String(params.command ?? '')
    if (!(await deps.confirm(`${response.error.message ?? 'Approval required.'}\n\nRun this command?\n\n${command}`))) {
      return { kind: 'declined', notice: 'Command was not run.' }
    }
    response = await deps.call({ ...params, confirmed: true })
  }
  if (response.error || response.ok === false) return { kind: 'failed', notice: shellErrorNotice(response) }
  const result = unwrapResult<ShellRunResult>(response)
  if (!result?.status) return { kind: 'failed', notice: 'The command result was not confirmed.' }
  const notice = result.status === 'completed'
    ? 'Workspace command finished.'
    : result.status === 'timed_out' ? 'Workspace command timed out and was stopped.' : 'Workspace command failed.'
  return { kind: 'ran', result, notice }
}

function shellErrorNotice(response: RpcEnvelope): string {
  switch (response.error?.code) {
    case 'conflict': return 'This chat already has a running command or provider request.'
    case 'resource_not_found': return response.error.message === 'resource not found'
      ? 'This chat is not on its runtime yet. Send a message first, then run shell commands.'
      : response.error.message
    default: return response.error?.message ?? 'Could not run the workspace command.'
  }
}
