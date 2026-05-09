#!/usr/bin/env node

import readline from "node:readline";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { randomUUID } from "node:crypto";

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

  const content = [];
  if (request.prompt) content.push({ type: "text", text: request.prompt });
  for (const image of images) {
    const path = image?.path;
    if (typeof path !== "string" || path.length === 0) {
      throw new Error("Claude image attachment is missing a local path.");
    }
    const mediaType = mimeTypeForPath(path);
    if (!mediaType) {
      throw new Error(`Claude image attachment has an unsupported file type: ${path}`);
    }
    const bytes = await readFile(path);
    content.push({
      type: "image",
      source: {
        type: "base64",
        media_type: mediaType,
        data: bytes.toString("base64"),
      },
    });
  }

  return (async function* promptMessages() {
    yield {
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      uuid: randomUUID(),
    };
  })();
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

function emitToolEvents(message, commandByToolUseId) {
  const content = message?.message?.content ?? message?.content;
  if (!Array.isArray(content)) return;
  for (const item of content) {
    const command = commandFromToolUse(item);
    if (typeof command === "string" && command.length > 0) {
      if (typeof item.id === "string") commandByToolUseId.set(item.id, command);
      write({ type: "stream_event", title: "Ran command", body: command });
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

function permissionMode(approvalPolicy, sandboxMode) {
  if (approvalPolicy === "never" && sandboxMode === "danger_full_access") {
    return "bypassPermissions";
  }
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
    maxThinkingTokens: request.reasoning_effort === "xhigh" ? 31999 : undefined,
    pathToClaudeCodeExecutable: pathToClaudeCodeExecutable(request),
  };

  const mode = permissionMode(request.approval_policy, request.sandbox_mode);
  if (mode) {
    options.permissionMode = mode;
    if (mode === "bypassPermissions") options.allowDangerouslySkipPermissions = true;
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
      name: model.displayName ?? model.name ?? model.value ?? model.id ?? String(model),
    })),
  });
}

async function handleListThreads(sdk, request) {
  if (typeof sdk.listSessions !== "function") {
    write({ type: "result", threads: [] });
    return;
  }
  const sessions = await sdk.listSessions({ cwd: request.cwd ?? undefined });
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
  const messages = await sdk.getSessionMessages(request.thread_id, { cwd: request.cwd ?? undefined });
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
  const query = sdk.query({
    prompt: await buildPrompt(request),
    options: buildOptions(request),
  });

  let sessionId = request.thread_id ?? null;
  let reply = "";
  const commandByToolUseId = new Map();
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
    emitToolEvents(message, commandByToolUseId);
    const delta = textFromContent(message?.message?.content ?? message?.content);
    if (message?.type === "assistant" && delta) {
      reply += delta;
      write({ type: "delta", text: delta });
    }
  }

  write({ type: "result", thread_id: sessionId, reply_text: reply });
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
rl.once("line", async (line) => {
  try {
    await dispatch(JSON.parse(line));
  } catch (err) {
    write({ type: "error", message: err?.message ?? String(err) });
    process.exitCode = 1;
  } finally {
    rl.close();
  }
});
