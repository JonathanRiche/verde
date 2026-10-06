import type { RpcEnvelope, Thread, Workspace } from './types'

type Call = (method: string, params: unknown) => Promise<RpcEnvelope>
type Mutation = () => Promise<{ client_id: string; request_key: string }>

/** A new web chat is a daemon-owned draft, including on paired sessions. */
export async function requestNewThread(call: Call, mutation: Mutation, workspace: Workspace, thread: Thread) {
  return call('chat.thread.upsert', {
    mutation: await mutation(), workspace_id: workspace.workspace_id, thread,
  })
}

export type WorkspaceCommandPatch =
  | { label: string }
  | { archived: true }
  | { icon_index: number | null; color_index: number | null }

/** Legacy workspace verbs may be unavailable or forbidden to paired clients.
 *  Identity edits have no dedicated verb and always use workspace.upsert, which
 *  replaces the whole row: both slots are always sent, explicit null = automatic. */
export async function requestWorkspaceCommand(
  call: Call, mutation: Mutation, workspace: Workspace, patch: WorkspaceCommandPatch,
): Promise<RpcEnvelope> {
  if (!('icon_index' in patch)) {
    const rename = 'label' in patch
    const response = await call(rename ? 'workspace.rename' : 'workspace.close', {
      workspace: workspace.workspace_id, ...(rename ? { label: patch.label } : {}),
    })
    if (!['unknown_method', 'method_not_found', 'capability_unavailable', 'forbidden'].includes(response.error?.code ?? '')) return response
  }
  const metadata: Workspace = { ...workspace, ...patch }
  delete metadata.threads
  delete metadata.messages
  // The gateway still authorizes workspace.upsert against repository:write.
  return call('workspace.upsert', { mutation: await mutation(), workspace: metadata })
}

/** Automatic focus must not summon a mobile keyboard; an explicit request must. */
export function focusChatPrompt(field: Pick<HTMLTextAreaElement, 'focus'> | undefined, compact: boolean, explicit: boolean) {
  if (explicit || !compact) field?.focus()
}
