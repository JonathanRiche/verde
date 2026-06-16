#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { parse, stringify } from "yaml";

const repoRoot = path.resolve(import.meta.dirname, "..", "..");
const workflowsDir = path.join(repoRoot, ".github", "workflows");
const envFilePath = path.join(repoRoot, ".env.agent-ci");
const generatedWorkflowsDir = path.join(repoRoot, ".agent-ci", "local-workflows");

const raw_args = process.argv.slice(2);
const listOnly = raw_args.includes("--list");
const includeSecretWorkflows = raw_args.includes("--include-secret-workflows");
const passThroughArgs = raw_args.filter(
  (arg) => arg !== "--list" && arg !== "--include-secret-workflows",
);

function parseEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return {};

  const entries = {};
  for (const line of fs.readFileSync(filePath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const eq = trimmed.indexOf("=");
    if (eq < 1) continue;

    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    entries[key] = value;
  }
  return entries;
}

function requiredSecrets(source) {
  return [...source.matchAll(/\$\{\{\s*secrets\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/g)]
    .map((match) => match[1])
    .filter((name, index, all) => all.indexOf(name) === index)
    .sort();
}

function isTagOnlyJob(job) {
  const condition = String(job?.if ?? "").replace(/\s+/g, " ");
  return (
    condition.includes("github.event_name == 'push'") &&
    condition.includes("github.ref_type == 'tag'")
  );
}

function jobMissingSecrets(job, machineEnv) {
  return requiredSecrets(JSON.stringify(job)).filter((secret) => !hasSecret(secret, machineEnv));
}

function includesNeedle(value, needle) {
  return JSON.stringify(value ?? "").toLowerCase().includes(needle);
}

function unsupportedHostReason(job) {
  if (process.platform !== "darwin" && includesNeedle(job?.["runs-on"], "macos")) {
    return "macOS runner is not available on this host";
  }
  if (process.platform !== "win32" && includesNeedle(job?.["runs-on"], "windows")) {
    return "Windows runner is not available on this host";
  }
  return null;
}

function normalizeNeeds(needs) {
  if (!needs) return [];
  return Array.isArray(needs) ? needs : [needs];
}

function localWorkflowFor(filePath, machineEnv, options) {
  const workflow = parse(fs.readFileSync(filePath, "utf8"));
  const jobs = workflow?.jobs;
  if (!jobs || typeof jobs !== "object") {
    return { workflow, keptJobs: [], skipped: [["<workflow>", "no jobs found"]] };
  }

  const keptJobs = {};
  const skipped = [];

  for (const [jobName, job] of Object.entries(jobs)) {
    if (isTagOnlyJob(job)) {
      skipped.push([jobName, "tag-only release job"]);
      continue;
    }

    const hostReason = unsupportedHostReason(job);
    if (hostReason) {
      skipped.push([jobName, hostReason]);
      continue;
    }

    const missingSecrets = jobMissingSecrets(job, machineEnv);
    if (!options.includeSecretWorkflows && missingSecrets.length > 0) {
      skipped.push([jobName, `missing ${missingSecrets.join(", ")}`]);
      continue;
    }

    keptJobs[jobName] = job;
  }

  let changed = true;
  while (changed) {
    changed = false;
    for (const [jobName, job] of Object.entries(keptJobs)) {
      const missingNeeds = normalizeNeeds(job.needs).filter((need) => !keptJobs[need]);
      if (missingNeeds.length === 0) continue;

      delete keptJobs[jobName];
      skipped.push([jobName, `depends on skipped job ${missingNeeds.join(", ")}`]);
      changed = true;
    }
  }

  return {
    workflow: { ...workflow, jobs: keptJobs },
    keptJobs: Object.keys(keptJobs),
    skipped,
  };
}

function hasSecret(name, machineEnv) {
  return Boolean(machineEnv[name] || process.env[name]);
}

if (!fs.existsSync(workflowsDir)) {
  console.error(`No GitHub workflow directory found: ${path.relative(repoRoot, workflowsDir)}`);
  process.exit(1);
}

const machineEnv = parseEnvFile(envFilePath);
const workflows = fs
  .readdirSync(workflowsDir)
  .filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
  .sort()
  .map((name) => {
    const filePath = path.join(workflowsDir, name);
    return {
      filePath,
      name,
      ...localWorkflowFor(filePath, machineEnv, { includeSecretWorkflows }),
    };
  });

const runnable = [];
for (const workflow of workflows) {
  const relative = path.relative(repoRoot, workflow.filePath);
  for (const [jobName, reason] of workflow.skipped) {
    console.log(`Skipping ${relative} > ${jobName}: ${reason}`);
  }

  if (workflow.keptJobs.length === 0) {
    continue;
  }

  runnable.push(workflow);
  if (listOnly) {
    console.log(`Would run ${relative}: ${workflow.keptJobs.join(", ")}`);
  }
}

if (listOnly) {
  process.exit(0);
}

if (runnable.length === 0) {
  console.error("No workflows can run with the currently available local secrets.");
  process.exit(1);
}

const agentCiBin = path.join(
  repoRoot,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "agent-ci.cmd" : "agent-ci",
);

for (const workflow of runnable) {
  const relative = path.relative(repoRoot, workflow.filePath);
  const localWorkflowPath = path.join(generatedWorkflowsDir, workflow.name);
  fs.mkdirSync(generatedWorkflowsDir, { recursive: true });
  fs.writeFileSync(localWorkflowPath, stringify(workflow.workflow));

  console.log(`Running ${relative}: ${workflow.keptJobs.join(", ")}`);

  const result = spawnSync(
    agentCiBin,
    [
      "run",
      "--workflow",
      localWorkflowPath,
      "--jobs",
      "1",
      "--no-matrix",
      ...passThroughArgs,
    ],
    { cwd: repoRoot, stdio: "inherit", env: process.env },
  );

  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
