#!/usr/bin/env node

import readline from "node:readline";
import { extname } from "node:path";
import * as claudeSdkStatic from "@anthropic-ai/claude-agent-sdk";

const write = (message) => {
  process.stdout.write(`${JSON.stringify(message)}\n`);
};

const fail = (message) => {
  write({ type: "error", message });
  process.exitCode = 1;
};

function mimeTypeForPath(path) {
  switch (extname(String(path || "")).toLowerCase()) {
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

function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const chunks = [];
  for (const item of content) {
    if (item?.type === "text" && typeof item.text === "string") chunks.push(item.text);
  }
  return chunks.join("");
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
  const parts = [`Tool: ${toolName}`];
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

function claudeRoleFromSdkMessage(message) {
  if (message?.type === "user") return "user";
  if (message?.type === "assistant") return "assistant";
  if (message?.type === "system") return "system";
  return undefined;
}

async function buildClaudePrompt(request) {
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

function emitClaudeSdkMessage(message) {
  const role = claudeRoleFromSdkMessage(message);
  const text = textFromContent(message?.message?.content ?? message?.content);
  if (role && text) write({ type: "message", role, text });
}

function commandFromClaudeToolUse(item) {
  if (item?.type !== "tool_use") return null;
  const name = String(item.name ?? "").toLowerCase();
  if (name !== "bash" && name !== "shell") return null;
  const input = item.input ?? {};
  return input.command ?? input.cmd ?? null;
}

function backgroundCommandMode(command) {
  if (/\bgh\s+run\s+watch\b/.test(command)) return "tracked";
  if (/\b(bun|npm|pnpm|yarn)\s+(run\s+)?(dev|dev:[\w:-]+|start)\b/.test(command)) return "detached";
  if (/\b(vite|next|astro|wrangler|alchemy)\s+(dev|start|preview|serve)\b/.test(command)) return "detached";
  if (/\btail\s+-(?:[^\s]*[fF][^\s]*)\b/.test(command)) return "detached";
  if (/(?:^|[;&|]\s*)watch\s+(?:-[^\s]+\s+)*/.test(command)) return "detached";
  if (/(?:^|[;&|]\s*)while\s+(?:true|:)\s*;\s*do\b/.test(command)) return "detached";
  if (/(?:^|[;&|]\s*)for\s*\(\(\s*;\s*;\s*\)\)\s*;\s*do\b/.test(command)) return "detached";
  if (/(?:^|[;&|]\s*)for\s+\w+\s+in\b[\s\S]*;\s*do\b[\s\S]*\bsleep\s+\d+/.test(command)) return "detached";
  return null;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function randomTaskId() {
  return `vbg${Math.random().toString(36).slice(2, 10)}`;
}

function detachedTaskPaths(taskId) {
  return {
    command: `/tmp/verde-claude-bg-${taskId}.command`,
    log: `/tmp/verde-claude-bg-${taskId}.log`,
    pid: `/tmp/verde-claude-bg-${taskId}.pid`,
  };
}

function detachedTaskStopCommand(taskId) {
  const { pid } = detachedTaskPaths(taskId);
  return `pid=$(cat ${shellQuote(pid)}); kill -TERM -- -$pid 2>/dev/null || kill -TERM "$pid"`;
}

function detachedTaskSummary(taskId) {
  const paths = detachedTaskPaths(taskId);
  return [
    `Verde task ID: ${taskId}`,
    `Output log: ${paths.log}`,
    `Stop command: ${detachedTaskStopCommand(taskId)}`,
  ].join("\n");
}

function detachedShellCommand(command, taskId) {
  const paths = detachedTaskPaths(taskId);
  const quotedCommand = shellQuote(command);
  const quotedCommandFile = shellQuote(paths.command);
  const quotedLog = shellQuote(paths.log);
  const quotedPid = shellQuote(paths.pid);
  const quotedStop = shellQuote(detachedTaskStopCommand(taskId));
  return [
    `printf '%s\\n' ${quotedCommand} > ${quotedCommandFile}`,
    `if command -v setsid >/dev/null 2>&1; then setsid sh -lc ${quotedCommand} > ${quotedLog} 2>&1 & else sh -lc ${quotedCommand} > ${quotedLog} 2>&1 & fi`,
    "pid=$!",
    `printf '%s\\n' "$pid" > ${quotedPid}`,
    `printf 'Verde background task ${taskId} started. PID: %s. Output log: ${paths.log}. Stop command: %s\\n' "$pid" ${quotedStop}`,
  ].join("; ");
}

function backgroundTaskResultTitle(status) {
  switch (status) {
    case "completed":
      return "Background task completed";
    case "failed":
      return "Background task failed";
    case "stopped":
      return "Background task stopped";
    default:
      return "Background task updated";
  }
}

function backgroundTaskBody(command, summary) {
  if (typeof summary === "string" && summary.trim().length > 0) {
    return `${command}\n\n${summary.trim()}`;
  }
  return command;
}

function emitClaudeTaskNotification(message, commandByToolUseId, backgroundState) {
  if (message?.type !== "system" || message?.subtype !== "task_notification") return false;
  const toolUseId = message.tool_use_id;
  if (typeof toolUseId !== "string" || !backgroundState.trackedToolUseIds.has(toolUseId)) return false;
  const command = typeof toolUseId === "string"
    ? commandByToolUseId.get(toolUseId)
    : null;
  if (!command) return false;

  if (typeof toolUseId === "string") backgroundState.trackedToolUseIds.delete(toolUseId);
  const details = [];
  if (typeof message.task_id === "string" && message.task_id.length > 0) details.push(`Claude task ID: ${message.task_id}`);
  if (typeof message.output_file === "string" && message.output_file.length > 0) details.push(`Output log: ${message.output_file}`);
  if (typeof message.summary === "string" && message.summary.trim().length > 0) details.push(message.summary.trim());
  write({
    type: "stream_event",
    title: backgroundTaskResultTitle(message.status),
    body: backgroundTaskBody(command, details.join("\n")),
  });
  return true;
}

function commandShouldTrackUntilNotification(command) {
  return backgroundCommandMode(command) === "tracked";
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function scheduleBackgroundTask(query, toolUseId, command, backgroundState) {
  if (!toolUseId || typeof query?.backgroundTasks !== "function") return;
  if (backgroundState.scheduledToolUseIds.has(toolUseId)) return;
  backgroundState.scheduledToolUseIds.add(toolUseId);
  backgroundState.sawTracked = true;
  backgroundState.trackedToolUseIds.add(toolUseId);
  write({ type: "stream_event", title: "Backgrounded command", body: command });

  const task = (async () => {
    let lastError = null;
    for (const delayMs of [500, 750, 1000, 1250, 1500, 2000]) {
      await sleep(delayMs);
      try {
        const backgrounded = await query.backgroundTasks(toolUseId);
        if (backgrounded) return;
      } catch (err) {
        lastError = err;
        if (query?.isClosed?.()) return;
      }
    }
    if (lastError) {
      write({ type: "stream_event", title: "Failed to background command", body: lastError?.message ?? String(lastError) });
    }
  })();
  backgroundState.pendingBackgrounds.push(task);
}

function emitClaudeToolEvents(message, commandByToolUseId, query, backgroundState) {
  const content = message?.message?.content ?? message?.content;
  if (!Array.isArray(content)) return;
  for (const item of content) {
    const rawCommand = commandFromClaudeToolUse(item);
    const command = typeof item?.id === "string" && commandByToolUseId.has(item.id)
      ? commandByToolUseId.get(item.id)
      : rawCommand;
    if (typeof command === "string" && command.length > 0) {
      if (typeof item.id === "string") commandByToolUseId.set(item.id, command);
      write({ type: "stream_event", title: "Ran command", body: command });
      if (commandShouldTrackUntilNotification(command)) {
        scheduleBackgroundTask(query, item.id, command, backgroundState);
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
}

function buildVerdeClaudeHooks() {
  return {
    PreToolUse: [{
      hooks: [async (input) => {
        const toolName = String(input?.tool_name ?? "").toLowerCase();
        if (toolName !== "bash" && toolName !== "shell") return { continue: true };
        const toolInput = input?.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
        const command = toolInput.command ?? toolInput.cmd;
        if (typeof command !== "string" || backgroundCommandMode(command) !== "detached") {
          return { continue: true };
        }

        const taskId = randomTaskId();
        write({
          type: "stream_event",
          title: "Backgrounded command",
          body: backgroundTaskBody(command, detachedTaskSummary(taskId)),
        });

        return {
          continue: true,
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "allow",
            permissionDecisionReason: "Verde detached long-running shell command",
            updatedInput: {
              ...toolInput,
              command: detachedShellCommand(command, taskId),
            },
          },
        };
      }],
    }],
  };
}

function claudePermissionMode(approvalPolicy, sandboxMode) {
  if (approvalPolicy === "never" && sandboxMode === "danger_full_access") return "bypassPermissions";
  if (approvalPolicy === "on_request") return "default";
  if (approvalPolicy === "never") return "dontAsk";
  return undefined;
}

function pathToClaudeCodeExecutable(request) {
  if (request?.claude_executable && request.claude_executable !== "claude") return request.claude_executable;
  return process.env.VERDE_CLAUDE_CODE_EXECUTABLE ||
    process.env.CLAUDE_CODE_EXECUTABLE ||
    request?.claude_executable ||
    "claude";
}

function buildClaudeOptions(request) {
  const options = {
    cwd: request.cwd ?? undefined,
    resume: request.thread_id ?? undefined,
    model: request.model ?? undefined,
    effort: request.reasoning_effort ?? undefined,
    pathToClaudeCodeExecutable: pathToClaudeCodeExecutable(request),
    hooks: buildVerdeClaudeHooks(),
  };

  const mode = claudePermissionMode(request.approval_policy, request.sandbox_mode);
  if (mode) {
    options.permissionMode = mode;
    if (mode === "bypassPermissions") options.allowDangerouslySkipPermissions = true;
    if (mode === "default") options.canUseTool = requestToolApproval;
  }

  return Object.fromEntries(Object.entries(options).filter(([, value]) => value !== undefined));
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

async function loadClaudeSdk() {
  return claudeSdkStatic;
}

async function handleClaudeAuth(sdk, request) {
  const query = sdk.query({ prompt: "", options: { maxTurns: 0, pathToClaudeCodeExecutable: pathToClaudeCodeExecutable(request) } });
  const info = await query.accountInfo();
  query.close?.();
  write({ type: "result", state: info ? "signed_in" : "signed_out" });
}

async function handleClaudeListModels(sdk, request) {
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

async function handleClaudeListThreads(sdk, request) {
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

async function handleClaudeReadThread(sdk, request) {
  if (typeof sdk.getSessionMessages !== "function") {
    throw new Error("Claude Agent SDK does not expose getSessionMessages");
  }
  const messages = await sdk.getSessionMessages(request.thread_id, { dir: request.cwd ?? undefined, limit: request.limit ?? 1000 });
  write({
    type: "result",
    thread_id: request.thread_id,
    title: request.thread_id,
    messages: (messages ?? []).map((message) => ({
      role: claudeRoleFromSdkMessage(message) ?? "assistant",
      text: textFromContent(message?.message?.content ?? message?.content),
    })).filter((message) => message.text),
  });
}

async function handleClaudeSendPrompt(sdk, request) {
  const stderrChunks = [];
  const commandByToolUseId = new Map();
  const options = buildClaudeOptions(request);
  options.stderr = (data) => {
    if (typeof data === "string" && data.length > 0) stderrChunks.push(data);
  };

  const query = sdk.query({
    prompt: await buildClaudePrompt(request),
    options,
  });

  try {
    let sessionId = request.thread_id ?? null;
    let reply = "";
    const backgroundState = { trackedToolUseIds: new Set(), scheduledToolUseIds: new Set(), sawTracked: false, pendingBackgrounds: [] };
    let sawResult = false;
    for await (const message of query) {
      if (message?.type === "system" && message?.subtype === "init" && message.session_id) {
        sessionId = message.session_id;
        write({ type: "thread_id", thread_id: sessionId });
        continue;
      }
      if (message?.type === "result") {
        sessionId = message.session_id ?? sessionId;
        if (typeof message.result === "string") reply = message.result;
        if (backgroundState.pendingBackgrounds.length > 0) {
          await Promise.allSettled(backgroundState.pendingBackgrounds);
          backgroundState.pendingBackgrounds.length = 0;
        }
        sawResult = true;
        if (backgroundState.sawTracked && backgroundState.trackedToolUseIds.size === 0 && typeof query?.close === "function") {
          query.close();
        }
        continue;
      }
      const emittedTaskNotification = emitClaudeTaskNotification(message, commandByToolUseId, backgroundState);
      if (emittedTaskNotification && sawResult && backgroundState.trackedToolUseIds.size === 0 && typeof query?.close === "function") {
        query.close();
      }
      emitClaudeSdkMessage(message);
      emitClaudeToolEvents(message, commandByToolUseId, query, backgroundState);
      const delta = textFromContent(message?.message?.content ?? message?.content);
      if (message?.type === "assistant" && delta) {
        reply += delta;
        write({ type: "delta", text: delta });
      }
    }
    if (backgroundState.pendingBackgrounds.length > 0) {
      await Promise.allSettled(backgroundState.pendingBackgrounds);
    }

    write({ type: "result", thread_id: sessionId, reply_text: reply });
  } catch (err) {
    const stderr = stderrChunks.join("").trim();
    if (stderr) throw new Error(`${err?.message ?? String(err)}\n${stderr}`);
    throw err;
  }
}

async function dispatchClaude(request) {
  const sdk = await loadClaudeSdk();
  switch (request.command) {
    case "auth":
      return handleClaudeAuth(sdk, request);
    case "list_models":
      return handleClaudeListModels(sdk, request);
    case "list_threads":
      return handleClaudeListThreads(sdk, request);
    case "read_thread":
      return handleClaudeReadThread(sdk, request);
    case "send_prompt":
      return handleClaudeSendPrompt(sdk, request);
    default:
      throw new Error(`Unknown Claude command: ${request.command}`);
  }
}

function providerFromRequest(request) {
  if (request?.provider === "claude") return request.provider;
  return "claude";
}

async function dispatch(request) {
  const provider = providerFromRequest(request);
  return dispatchClaude(request);
}

function parseEnvRequest() {
  const raw = process.env.VERDE_PROVIDER_REQUEST;
  if (!raw) return null;
  return JSON.parse(raw);
}

async function main() {
  const envRequest = parseEnvRequest();
  if (envRequest) {
    await dispatch(envRequest);
    return;
  }

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on("line", handleInputLine);
  rl.once("line", async (line) => {
    try {
      await dispatch(JSON.parse(line));
    } catch (err) {
      fail(err?.message ?? String(err));
    } finally {
      if (pendingApprovals.size === 0) rl.close();
    }
  });
}

main().catch((err) => {
  fail(err?.stack || err?.message || String(err));
});
