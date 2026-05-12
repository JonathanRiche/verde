#!/usr/bin/env node

import readline from "node:readline";
import { extname } from "node:path";

async function loadSdk() {
  try {
    return await import("@anthropic-ai/claude-agent-sdk");
  } catch (err) {
    throw new Error(
      `Unable to load @anthropic-ai/claude-agent-sdk. Install it for the desktop package or provide it on NODE_PATH. ${err?.message ?? err}`,
    );
  }
}

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

let nextApprovalRequestId = 1;
const pendingApprovals = new Map();

function handleInputLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message?.type !== "approval_response" || typeof message.request_id !== "number") return;
  const pending = pendingApprovals.get(message.request_id);
  if (!pending) return;
  pendingApprovals.delete(message.request_id);
  pending.resolve(message.decision === "approve");
}

function approvalRequestBody(toolName, input, options) {
  if (options?.description) return options.description;
  const parts = [];
  parts.push(`Tool: ${toolName}`);
  if (options?.blockedPath) parts.push(`Path: ${options.blockedPath}`);
  if (options?.decisionReason) parts.push(`Reason: ${options.decisionReason}`);
  try {
    parts.push(JSON.stringify(input, null, 2));
  } catch {
    parts.push(String(input ?? ""));
  }
  return parts.filter(Boolean).join("\n\n");
}

async function requestToolApproval(toolName, input, options) {
  const requestId = nextApprovalRequestId++;
  write({
    type: "approval_request",
    request_id: requestId,
    call_id: options?.toolUseID ?? String(requestId),
    title: options?.title ?? options?.displayName ?? `Claude wants to use ${toolName}`,
    body: approvalRequestBody(toolName, input, options),
  });

  const allowed = await new Promise((resolve) => {
    pendingApprovals.set(requestId, { resolve });
    options?.signal?.addEventListener("abort", () => {
      if (!pendingApprovals.has(requestId)) return;
      pendingApprovals.delete(requestId);
      resolve(false);
    }, { once: true });
  });

  return allowed
    ? { behavior: "allow", toolUseID: options?.toolUseID, decisionClassification: "user_temporary" }
    : { behavior: "deny", message: "Denied by user", toolUseID: options?.toolUseID, decisionClassification: "user_reject" };
}

function roleFromSdkMessage(message) {
  if (message?.type === "user") return "user";
  if (message?.type === "assistant") return "assistant";
  if (message?.type === "system") return "system";
  return undefined;
}

function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const chunks = [];
  for (const item of content) {
    if (item?.type === "text" && typeof item.text === "string") chunks.push(item.text);
  }
  return chunks.join("");
}

function mimeTypeForPath(path) {
  switch (extname(path).toLowerCase()) {
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".png":
      return "image/png";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    default:
      return undefined;
  }
}

async function buildPrompt(request) {
  const images = Array.isArray(request.images) ? request.images : [];
  if (images.length === 0) return request.prompt;

  const lines = [];
  if (request.prompt) lines.push(request.prompt);
  lines.push("", "Attached image file(s):");
  for (const image of images) {
    const path = image?.path;
    if (typeof path !== "string" || path.length === 0) {
      throw new Error("Claude image attachment is missing a local path.");
    }
    if (!mimeTypeForPath(path)) {
      throw new Error(`Claude image attachment has an unsupported file type: ${path}`);
    }
    lines.push(`- ${path}`);
  }
  lines.push("", "Use the attached image file(s) as context for this request.");

  return lines.join("\n");
}

function emitSdkMessage(message) {
  const role = roleFromSdkMessage(message);
  const text = textFromContent(message?.message?.content ?? message?.content);
  if (role && text) write({ type: "message", role, text });
}

function commandFromToolUse(item) {
  if (item?.type !== "tool_use") return null;
  const name = String(item.name ?? "").toLowerCase();
  if (name !== "bash" && name !== "shell") return null;
  const input = item.input ?? {};
  return input.command ?? input.cmd ?? null;
}

function commandShouldRunInBackground(command) {
  return /\b(bun|npm|pnpm|yarn)\s+(run\s+)?(dev|dev:[\w:-]+|start)\b/.test(command) ||
    /\b(vite|next|astro|wrangler|alchemy)\s+(dev|start|preview|serve)\b/.test(command);
}

function scheduleBackgroundTask(query, toolUseId, command) {
  if (!toolUseId || typeof query?.backgroundTasks !== "function") return;
  setTimeout(async () => {
    try {
      const backgrounded = await query.backgroundTasks(toolUseId);
      if (backgrounded) {
        write({ type: "stream_event", title: "Backgrounded command", body: command });
      }
    } catch (err) {
      write({ type: "stream_event", title: "Failed to background command", body: err?.message ?? String(err) });
    }
  }, 4000).unref?.();
}

function emitToolEvents(message, commandByToolUseId, query) {
  const content = message?.message?.content ?? message?.content;
  if (!Array.isArray(content)) return false;
  let sawBackgroundableCommand = false;
  for (const item of content) {
    const command = commandFromToolUse(item);
    if (typeof command === "string" && command.length > 0) {
      if (typeof item.id === "string") commandByToolUseId.set(item.id, command);
      write({ type: "stream_event", title: "Ran command", body: command });
      if (commandShouldRunInBackground(command)) {
        sawBackgroundableCommand = true;
        scheduleBackgroundTask(query, item.id, command);
      }
      continue;
    }
    if (item?.type === "tool_result" && item.is_error === true) {
      const failedCommand = commandByToolUseId.get(item.tool_use_id);
      if (failedCommand) {
        write({ type: "stream_event", title: "Command failed", body: failedCommand });
      }
    }
  }
  return sawBackgroundableCommand;
}

function permissionMode(approvalPolicy, sandboxMode) {
  if (approvalPolicy === "never" && sandboxMode === "danger_full_access") {
    return "bypassPermissions";
  }
  if (approvalPolicy === "on_request") return "default";
  if (approvalPolicy === "never") return "dontAsk";
  return undefined;
}

function pathToClaudeCodeExecutable(request) {
  return request?.claude_executable || process.env.CLAUDE_CODE_EXECUTABLE || process.env.VERDE_CLAUDE_CODE_EXECUTABLE || "claude";
}

function buildOptions(request) {
  const options = {
    cwd: request.cwd ?? undefined,
    resume: request.thread_id ?? undefined,
    model: request.model ?? undefined,
    effort: request.reasoning_effort ?? undefined,
    pathToClaudeCodeExecutable: pathToClaudeCodeExecutable(request),
  };

  const mode = permissionMode(request.approval_policy, request.sandbox_mode);
  if (mode) {
    options.permissionMode = mode;
    if (mode === "bypassPermissions") options.allowDangerouslySkipPermissions = true;
    if (mode === "default") options.canUseTool = requestToolApproval;
  }

  return Object.fromEntries(Object.entries(options).filter(([, value]) => value !== undefined));
}

async function handleAuth(sdk, request) {
  const query = sdk.query({ prompt: "", options: { maxTurns: 0, pathToClaudeCodeExecutable: pathToClaudeCodeExecutable(request) } });
  const info = await query.accountInfo();
  query.close?.();
  write({ type: "result", state: info ? "signed_in" : "signed_out" });
}

async function handleListModels(sdk, request) {
  const query = sdk.query({ prompt: "", options: { maxTurns: 0, pathToClaudeCodeExecutable: pathToClaudeCodeExecutable(request) } });
  const models = await query.supportedModels();
  query.close?.();
  write({
    type: "result",
    models: (models ?? []).map((model) => ({
      id: model.value ?? model.id ?? model.name ?? String(model),
      name: claudeModelDisplayName(model),
      reasoning_supported: model.supportsEffort ?? false,
      supported_effort_levels: Array.isArray(model.supportedEffortLevels) ? model.supportedEffortLevels : null,
    })),
  });
}

function claudeModelDisplayName(model) {
  const fallback = model.displayName ?? model.name ?? model.value ?? model.id ?? String(model);
  const description = typeof model.description === "string" ? model.description : "";
  const version = description.match(/\b(?:Opus|Sonnet|Haiku)\s+\d+(?:\.\d+)?\b/)?.[0];
  if (!version) return fallback;

  const display = String(model.displayName ?? "");
  if (display.includes("1M context")) return `${version} (1M context)`;
  if (display.toLowerCase().includes("recommended")) return `Default (${version})`;
  return version;
}

async function handleListThreads(sdk, request) {
  if (typeof sdk.listSessions !== "function") {
    write({ type: "result", threads: [] });
    return;
  }
  const sessions = await sdk.listSessions({ dir: request.cwd ?? undefined, limit: request.limit ?? 100 });
  write({
    type: "result",
    threads: (sessions ?? []).map((session) => ({
      id: session.id ?? session.session_id ?? session.sessionId,
      title: session.title ?? session.summary ?? session.id ?? session.session_id ?? session.sessionId,
      updated_at: session.updated_at ?? session.updatedAt ?? null,
    })).filter((thread) => thread.id),
  });
}

async function handleReadThread(sdk, request) {
  if (typeof sdk.getSessionMessages !== "function") {
    throw new Error("Claude Agent SDK does not expose getSessionMessages");
  }
  const messages = await sdk.getSessionMessages(request.thread_id, { dir: request.cwd ?? undefined, limit: request.limit ?? 1000 });
  write({
    type: "result",
    thread_id: request.thread_id,
    title: request.thread_id,
    messages: (messages ?? []).map((message) => ({
      role: roleFromSdkMessage(message) ?? "assistant",
      text: textFromContent(message?.message?.content ?? message?.content),
    })).filter((message) => message.text),
  });
}

async function handleSendPrompt(sdk, request) {
  const stderrChunks = [];
  const options = buildOptions(request);
  options.stderr = (data) => {
    if (typeof data === "string" && data.length > 0) stderrChunks.push(data);
  };

  const query = sdk.query({
    prompt: await buildPrompt(request),
    options,
  });

  try {
    let sessionId = request.thread_id ?? null;
    let reply = "";
    const commandByToolUseId = new Map();
    let sawBackgroundableCommand = false;
    let closeAfterReplyTimer = null;
    for await (const message of query) {
      if (message?.type === "system" && message?.subtype === "init" && message.session_id) {
        sessionId = message.session_id;
        write({ type: "thread_id", thread_id: sessionId });
        continue;
      }
      if (message?.type === "result") {
        sessionId = message.session_id ?? sessionId;
        if (typeof message.result === "string") reply = message.result;
        continue;
      }
      emitSdkMessage(message);
      sawBackgroundableCommand = emitToolEvents(message, commandByToolUseId, query) || sawBackgroundableCommand;
      const delta = textFromContent(message?.message?.content ?? message?.content);
      if (message?.type === "assistant" && delta) {
        reply += delta;
        write({ type: "delta", text: delta });
        if (sawBackgroundableCommand && typeof query?.close === "function") {
          if (closeAfterReplyTimer) clearTimeout(closeAfterReplyTimer);
          closeAfterReplyTimer = setTimeout(() => {
            write({ type: "stream_event", title: "Finished reply", body: "Closed Claude stream after background dev command." });
            query.close();
          }, 3000);
          closeAfterReplyTimer.unref?.();
        }
      }
    }
    if (closeAfterReplyTimer) clearTimeout(closeAfterReplyTimer);

    write({ type: "result", thread_id: sessionId, reply_text: reply });
  } catch (err) {
    const stderr = stderrChunks.join("").trim();
    if (stderr) throw new Error(`${err?.message ?? String(err)}\n${stderr}`);
    throw err;
  }
}

async function dispatch(request) {
  const sdk = await loadSdk();
  switch (request.command) {
    case "auth":
      return handleAuth(sdk, request);
    case "list_models":
      return handleListModels(sdk, request);
    case "list_threads":
      return handleListThreads(sdk, request);
    case "read_thread":
      return handleReadThread(sdk, request);
    case "send_prompt":
      return handleSendPrompt(sdk, request);
    default:
      throw new Error(`Unknown command: ${request.command}`);
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", handleInputLine);
rl.once("line", async (line) => {
  try {
    await dispatch(JSON.parse(line));
  } catch (err) {
    write({ type: "error", message: err?.message ?? String(err) });
    process.exitCode = 1;
  } finally {
    if (pendingApprovals.size === 0) rl.close();
  }
});
