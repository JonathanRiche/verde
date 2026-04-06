#!/usr/bin/env node

const { spawn } = require("node:child_process");

const runtimePackages = {
  "darwin:arm64": "verde-app-darwin-arm64",
  "darwin:x64": "verde-app-darwin-x64",
  "linux:x64": "verde-app-linux-x64",
};

function resolveRuntimePackage() {
  const key = `${process.platform}:${process.arch}`;
  return runtimePackages[key] ?? null;
}

function loadRuntimePackage(packageName) {
  try {
    return require(packageName);
  } catch (error) {
    if (
      error &&
      error.code === "MODULE_NOT_FOUND" &&
      typeof error.message === "string" &&
      error.message.includes(packageName)
    ) {
      console.error(`Verde does not appear to be installed for ${process.platform}/${process.arch}.`);
      console.error(`Try reinstalling the package for this platform: npm install -g verde`);
      process.exit(1);
    }

    throw error;
  }
}

const runtimePackage = resolveRuntimePackage();
if (runtimePackage === null) {
  console.error(`Verde is not currently published for ${process.platform}/${process.arch}.`);
  process.exit(1);
}

const runtime = loadRuntimePackage(runtimePackage);
const executablePath =
  runtime && typeof runtime.getExecutablePath === "function"
    ? runtime.getExecutablePath()
    : null;

if (!executablePath) {
  console.error(`The installed Verde runtime package is invalid: ${runtimePackage}`);
  process.exit(1);
}

const child = spawn(executablePath, process.argv.slice(2), {
  stdio: "inherit",
  env: process.env,
});

child.on("error", (error) => {
  console.error(`Failed to launch Verde: ${error.message}`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
