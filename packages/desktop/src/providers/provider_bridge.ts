#!/usr/bin/env node

import readline from "node:readline";
import { Buffer } from "node:buffer";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
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

function powershellQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function powershellInvocation(script) {
  const encoded = Buffer.from(script, "utf16le").toString("base64");
  return `powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}`;
}

function randomTaskId() {
  return `vbg${Math.random().toString(36).slice(2, 10)}`;
}

function detachedTaskPaths(taskId) {
  const base = process.platform === "win32" ? tmpdir() : "/tmp";
  const commandSuffix = process.platform === "win32" ? ".command.ps1" : ".command";
  return {
    command: join(base, `verde-claude-bg-${taskId}${commandSuffix}`),
    log: join(base, `verde-claude-bg-${taskId}.log`),
    pid: join(base, `verde-claude-bg-${taskId}.pid`),
  };
}

function detachedTaskStopCommand(taskId) {
  const { pid } = detachedTaskPaths(taskId);
  if (process.platform === "win32") {
    return powershellInvocation([
      `$rawPid = [System.IO.File]::ReadAllText(${powershellQuote(pid)}).Trim()`,
      "$taskPid = 0",
      "if (-not [int]::TryParse($rawPid, [ref]$taskPid)) { throw 'Invalid Verde background task PID' }",
      "$taskkill = Join-Path $env:SystemRoot 'System32\\taskkill.exe'",
      "& $taskkill '/PID' ([string]$taskPid) '/T' '/F'",
      "if ($LASTEXITCODE -ne 0) { throw 'Failed to stop Verde background task tree' }",
    ].join("; "));
  }
  return `pid=$(cat ${shellQuote(pid)}); kill -TERM -- -$pid 2>/dev/null || kill -TERM "$pid"`;
}

function detachedTaskSummary(taskId) {
  const paths = detachedTaskPaths(taskId);
  return [
    `Verde task ID: ${taskId}`,
    `Output log: ${paths.log}`,
    `PID file: ${paths.pid}`,
    `Stop command: ${detachedTaskStopCommand(taskId)}`,
  ].join("\n");
}

function detachedPosixShellCommand(command, taskId) {
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

function detachedPowerShellCommand(command, taskId) {
  const paths = detachedTaskPaths(taskId);
  const childScript = `& ${powershellQuote(paths.command)} *> ${powershellQuote(paths.log)}`;
  const childEncoded = Buffer.from(childScript, "utf16le").toString("base64");
  const launcher = [
    "$ErrorActionPreference = 'Stop'",
    `$utf8 = New-Object System.Text.UTF8Encoding($false)`,
    `[System.IO.File]::WriteAllText(${powershellQuote(paths.command)}, ${powershellQuote(command)}, $utf8)`,
    `$childArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', '${childEncoded}')`,
    "$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $childArgs -WorkingDirectory (Get-Location).Path -WindowStyle Hidden -PassThru",
    `[System.IO.File]::WriteAllText(${powershellQuote(paths.pid)}, [string]$child.Id, $utf8)`,
    `Write-Output ('Verde background task ${taskId} started. PID: ' + $child.Id + '. Output log: ${String(paths.log).replaceAll("'", "''")}')`,
  ].join("; ");
  return powershellInvocation(launcher);
}

function detachedShellCommand(command, taskId) {
  return process.platform === "win32"
    ? detachedPowerShellCommand(command, taskId)
    : detachedPosixShellCommand(command, taskId);
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

function slashName(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  return raw.startsWith("/") ? raw.slice(1).split(/\s+/, 1)[0] : raw.split(/\s+/, 1)[0];
}

function withSlash(value) {
  const name = slashName(value);
  return name ? `/${name}` : "";
}

function slashPromptFromRequest(request) {
  const raw = typeof request.raw_text === "string" ? request.raw_text.trim() : "";
  if (raw.startsWith("/")) return raw;
  const command = withSlash(request.slash_command);
  const args = typeof request.args === "string" ? request.args.trim() : "";
  return args ? `${command} ${args}` : command;
}

function slashCommandSupported(commands, name) {
  const target = slashName(name);
  if (!target) return false;
  for (const command of Array.isArray(commands) ? commands : []) {
    if (slashName(command?.name) === target) return true;
    for (const alias of Array.isArray(command?.aliases) ? command.aliases : []) {
      if (slashName(alias) === target) return true;
    }
  }
  return false;
}

function serializeSlashCommand(command) {
  return {
    name: withSlash(command?.name),
    description: typeof command?.description === "string" ? command.description : "",
    argument_hint: typeof command?.argumentHint === "string" ? command.argumentHint : "",
    aliases: (Array.isArray(command?.aliases) ? command.aliases : []).map(withSlash).filter(Boolean),
  };
}

function formatUsd(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "unavailable";
  if (value === 0) return "$0.00";
  if (value < 0.01) return `$${value.toFixed(4)}`;
  return `$${value.toFixed(2)}`;
}

function formatInteger(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "unavailable";
  return Math.round(value).toLocaleString("en-US");
}

function formatDurationMs(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "unavailable";
  if (value < 1000) return `${Math.round(value)}ms`;
  if (value < 60_000) return `${(value / 1000).toFixed(1)}s`;
  return `${Math.round(value / 60_000)}m ${Math.round((value % 60_000) / 1000)}s`;
}

function formatPercent(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "unavailable";
  return `${value.toFixed(value < 10 ? 1 : 0)}%`;
}

function formatPercentLeftFromUtilization(utilization) {
  if (typeof utilization !== "number" || !Number.isFinite(utilization)) return null;
  return Math.max(0, Math.min(100, Math.round(100 - utilization)));
}

function formatResetText(value) {
  if (typeof value !== "string" || value.length === 0) return "";
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return `resets ${value}`;
  const diffMs = timestamp - Date.now();
  if (diffMs <= 0) return "resets soon";
  const totalMinutes = Math.max(1, Math.round(diffMs / 60_000));
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return `resets in ${days}d ${hours}h`;
  if (hours > 0) return `resets in ${hours}h ${minutes}m`;
  return `resets in ${minutes}m`;
}

function addClaudeLimitLine(lines, label, window) {
  if (!window || typeof window !== "object") return;
  const left = formatPercentLeftFromUtilization(window.utilization);
  if (left === null) return;
  const reset = formatResetText(window.resets_at);
  lines.push(`• ${label}: ${left}% left${reset ? ` (${reset})` : ""}`);
}

function addClaudeRateLimitLines(lines, usage) {
  const limits = usage?.rate_limits;
  if (!limits || typeof limits !== "object") {
    if (usage?.rate_limits_available === false) lines.push("• Plan rate limits: unavailable for this Claude account/session type.");
    return;
  }
  const beforeCount = lines.length;
  addClaudeLimitLine(lines, "Claude 5h", limits.five_hour);
  addClaudeLimitLine(lines, "Claude weekly", limits.seven_day);
  addClaudeLimitLine(lines, "Claude Opus weekly", limits.seven_day_opus);
  addClaudeLimitLine(lines, "Claude Sonnet weekly", limits.seven_day_sonnet);
  if (lines.length === beforeCount && usage?.rate_limits_available === false) {
    lines.push("• Plan rate limits: unavailable for this Claude account/session type.");
  }
}

function addClaudeExtraUsageSummary(lines, usage) {
  const extra = usage?.rate_limits?.extra_usage;
  if (!extra || typeof extra !== "object") return;
  const used = extra.used_credits ?? "unavailable";
  const currency = extra.currency ? ` ${extra.currency}` : "";
  lines.push(`• Extra usage: ${extra.is_enabled ? "enabled" : "disabled"} · ${formatPercent(extra.utilization)} used · ${used}${currency}`);
}

function addClaudeBehaviorRows(lines, usage) {
  const behaviors = usage?.behaviors;
  if (!behaviors || typeof behaviors !== "object") return;
  const day = behaviors.day;
  const week = behaviors.week;
  if (day && typeof day === "object") {
    lines.push(`• Last 24h: ${formatInteger(day.request_count)} requests · ${formatInteger(day.session_count)} sessions`);
  }
  if (week && typeof week === "object") {
    lines.push(`• Last 7d: ${formatInteger(week.request_count)} requests · ${formatInteger(week.session_count)} sessions`);
  }
}

function formatClaudeUsageSummary(usage, contextUsage) {
  const lines = ["Claude usage", ""];

  const limitLines = [];
  addClaudeRateLimitLines(limitLines, usage);
  if (limitLines.length > 0) lines.push("Limits", ...limitLines, "");

  lines.push("Summary");

  const session = usage?.session;
  if (session && typeof session === "object") {
    lines.push(`• Session cost estimate: ${formatUsd(session.total_cost_usd)}`);
    lines.push(`• API duration: ${formatDurationMs(session.total_api_duration_ms)} · wall time ${formatDurationMs(session.total_duration_ms)}`);
    lines.push(`• Changed lines: +${formatInteger(session.total_lines_added)} / -${formatInteger(session.total_lines_removed)}`);
  }

  if (contextUsage && typeof contextUsage === "object") {
    lines.push(`• Context window: ${formatInteger(contextUsage.totalTokens)} / ${formatInteger(contextUsage.maxTokens)} tokens (${formatPercent(contextUsage.percentage)})`);
    if (typeof contextUsage.model === "string" && contextUsage.model.length > 0) {
      lines.push(`• Context model: ${contextUsage.model}`);
    }
  }

  if (typeof usage?.subscription_type === "string" && usage.subscription_type.length > 0) {
    lines.push(`• Subscription: ${usage.subscription_type}`);
  }
  addClaudeExtraUsageSummary(lines, usage);

  if (!session && !contextUsage) {
    lines.push("• Status: Claude did not return structured usage data for this session.");
  }
  lines.push("• Estimate: SDK costs are not authoritative billing.");

  const behaviorLines = [];
  addClaudeBehaviorRows(behaviorLines, usage);
  if (behaviorLines.length > 0) lines.push("", "Recent daily usage", ...behaviorLines);
  return lines.join("\n");
}

function claudeRejectedRateLimitMessage(message) {
  if (message?.type !== "rate_limit_event" || message?.rate_limit_info?.status !== "rejected") return null;
  switch (message.rate_limit_info.rateLimitType) {
    case "five_hour":
      return "Claude five_hour usage limit has been reached.";
    case "seven_day":
      return "Claude seven_day usage limit has been reached.";
    case "seven_day_opus":
      return "Claude seven_day_opus usage limit has been reached.";
    case "seven_day_sonnet":
      return "Claude seven_day_sonnet usage limit has been reached.";
    case "overage":
      return "Claude overage usage limit has been reached.";
    default:
      return "Claude usage limit has been reached.";
  }
}

function formatClaudeCompactSummary(metadata, fallbackText) {
  const lines = [
    "Claude thread context compacted.",
    "",
    "Future Claude turns will continue from the compacted conversation summary.",
  ];
  if (metadata && typeof metadata === "object") {
    lines.push("", `Trigger: ${metadata.trigger ?? "manual"}`);
    if (typeof metadata.pre_tokens === "number") lines.push(`Before: ${formatInteger(metadata.pre_tokens)} tokens`);
    if (typeof metadata.post_tokens === "number") lines.push(`After: ${formatInteger(metadata.post_tokens)} tokens`);
    if (typeof metadata.duration_ms === "number") lines.push(`Duration: ${formatDurationMs(metadata.duration_ms)}`);
  }
  const trimmed = typeof fallbackText === "string" ? fallbackText.trim() : "";
  if (trimmed) lines.push("", trimmed);
  return lines.join("\n");
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
  const model = (messages ?? []).find((message) => typeof message?.message?.model === "string")?.message?.model ?? null;
  write({
    type: "result",
    thread_id: request.thread_id,
    title: request.thread_id,
    model_id: model,
    messages: (messages ?? []).map((message) => ({
      role: claudeRoleFromSdkMessage(message) ?? "assistant",
      text: textFromContent(message?.message?.content ?? message?.content),
    })).filter((message) => message.text),
  });
}

async function handleClaudeSlashCommands(sdk, request) {
  const options = { ...buildClaudeOptions(request), maxTurns: 0 };
  const query = sdk.query({ prompt: "", options });
  try {
    const commands = typeof query.supportedCommands === "function"
      ? await query.supportedCommands()
      : [];
    write({
      type: "result",
      commands: (commands ?? []).map(serializeSlashCommand).filter((command) => command.name),
    });
  } finally {
    query.close?.();
  }
}

async function handleClaudeUsageSlashCommand(sdk, request) {
  const options = { ...buildClaudeOptions(request), maxTurns: 0 };
  const query = sdk.query({ prompt: "", options });
  let usage = null;
  let contextUsage = null;
  try {
    if (typeof query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET === "function") {
      try {
        usage = await query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET();
      } catch {
        usage = null;
      }
    }
    if (typeof query.getContextUsage === "function") {
      try {
        contextUsage = await query.getContextUsage();
      } catch {
        contextUsage = null;
      }
    }
  } finally {
    query.close?.();
  }

  if (usage || contextUsage) {
    write({
      type: "result",
      handled: true,
      notice: "Claude usage loaded.",
      transcript_title: "Usage",
      transcript_body: formatClaudeUsageSummary(usage, contextUsage),
    });
    return;
  }

  await handleClaudeDispatchSlashCommand(sdk, request);
}

async function handleClaudeDispatchSlashCommand(sdk, request) {
  const prompt = slashPromptFromRequest(request);
  const commandName = slashName(prompt);
  const stderrChunks = [];
  const options = buildClaudeOptions(request);
  options.stderr = (data) => {
    if (typeof data === "string" && data.length > 0) stderrChunks.push(data);
  };

  const query = sdk.query({ prompt, options });
  try {
    const commands = typeof query.supportedCommands === "function"
      ? await query.supportedCommands()
      : null;
    if (!slashCommandSupported(commands, commandName)) {
      query.close?.();
      write({
        type: "result",
        handled: false,
        notice: `Claude Code does not expose /${commandName} for this session.`,
      });
      return;
    }

    let sessionId = request.thread_id ?? null;
    let reply = "";
    let localOutput = "";
    let compactMetadata = null;

    for await (const message of query) {
      if (message?.type === "system" && message?.subtype === "init" && message.session_id) {
        sessionId = message.session_id;
        continue;
      }
      if (message?.type === "system" && message?.subtype === "compact_boundary") {
        compactMetadata = message.compact_metadata ?? null;
        continue;
      }
      if (message?.type === "system" && message?.subtype === "local_command_output") {
        if (typeof message.content === "string") localOutput += message.content;
        continue;
      }
      if (message?.type === "result") {
        sessionId = message.session_id ?? sessionId;
        if (typeof message.result === "string") reply = message.result;
        continue;
      }
      const delta = textFromContent(message?.message?.content ?? message?.content);
      if (message?.type === "assistant" && delta) reply += delta;
    }

    const outputText = localOutput.trim() || reply.trim();
    if (commandName === "compact") {
      write({
        type: "result",
        handled: true,
        thread_id: sessionId,
        notice: "Claude context compacted.",
        transcript_title: "Claude /compact",
        transcript_body: formatClaudeCompactSummary(compactMetadata, outputText),
      });
      return;
    }

    write({
      type: "result",
      handled: true,
      thread_id: sessionId,
      notice: `Claude /${commandName} completed.`,
      transcript_title: `Claude /${commandName}`,
      transcript_body: outputText || `/${commandName} completed.`,
    });
  } catch (err) {
    const stderr = stderrChunks.join("").trim();
    if (stderr) throw new Error(`${err?.message ?? String(err)}\n${stderr}`);
    throw err;
  }
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
      const rateLimitFailure = claudeRejectedRateLimitMessage(message);
      if (rateLimitFailure) throw new Error(rateLimitFailure);
      if (message?.type === "system" && message?.subtype === "init" && message.session_id) {
        sessionId = message.session_id;
        write({ type: "thread_id", thread_id: sessionId });
        continue;
      }
      if (message?.type === "result") {
        sessionId = message.session_id ?? sessionId;
        if (message.is_error) {
          const errors = Array.isArray(message.errors) ? message.errors.filter((item) => typeof item === "string" && item.length > 0) : [];
          throw new Error(errors.join("\n") || message.stop_reason || "Claude request failed during execution.");
        }
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
    case "slash_commands":
      return handleClaudeSlashCommands(sdk, request);
    case "run_slash_command":
      if (slashName(request.slash_command) === "usage") return handleClaudeUsageSlashCommand(sdk, request);
      return handleClaudeDispatchSlashCommand(sdk, request);
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
