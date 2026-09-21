import type { LivePane, RpcEnvelope, Thread, Workspace } from './types'

type Call = (method: string, params: unknown) => Promise<RpcEnvelope>
type Mutation = () => Promise<{ client_id: string; request_key: string }>

/** A new web chat is a daemon-owned draft, including on paired sessions. */
export async function requestNewThread(call: Call, mutation: Mutation, workspace: Workspace, thread: Thread) {
  return call('chat.thread.upsert', {
    mutation: await mutation(), workspace_id: workspace.workspace_id, thread,
  })
}

/** Legacy workspace verbs may be unavailable or forbidden to paired clients. */
export async function requestWorkspaceCommand(
  call: Call, mutation: Mutation, workspace: Workspace, patch: { label: string } | { archived: true },
): Promise<RpcEnvelope> {
  const rename = 'label' in patch
  const response = await call(rename ? 'workspace.rename' : 'workspace.close', {
    workspace: workspace.workspace_id, ...(rename ? { label: patch.label } : {}),
  })
  if (!['unknown_method', 'method_not_found', 'capability_unavailable', 'forbidden'].includes(response.error?.code ?? '')) return response
  const metadata = { ...workspace, ...patch }
  delete metadata.threads
  delete metadata.messages
  // The gateway still authorizes workspace.upsert against repository:write.
  return call('workspace.upsert', { mutation: await mutation(), workspace: metadata })
}

export function archiveCommand(
  pane: LivePane,
  owner: (pane: LivePane) => string,
  archive: (workspace: string, thread: string) => Promise<boolean>,
) {
  return archive(owner(pane), pane.thread_id!)
}

/** Automatic focus must not summon a mobile keyboard; an explicit request must. */
export function focusChatPrompt(field: Pick<HTMLTextAreaElement, 'focus'> | undefined, compact: boolean, explicit: boolean) {
  if (explicit || !compact) field?.focus()
}
