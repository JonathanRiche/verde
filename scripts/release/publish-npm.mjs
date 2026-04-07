#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const args = process.argv.slice(2);
let otp = process.env.NPM_PUBLISH_OTP ?? null;
const positional = [];

for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];

  if (arg === "--otp") {
    otp = args[i + 1] ?? "";
    i += 1;
    continue;
  }

  positional.push(arg);
}

if (positional.length !== 1) {
  console.error(
    "usage: node scripts/release/publish-npm.mjs [--otp <code>] <manifest-path>",
  );
  process.exit(1);
}

if (otp !== null && !/^\d{6}$/.test(otp)) {
  console.error("error: OTP must be a 6-digit code");
  process.exit(1);
}

const manifestPath = path.resolve(process.cwd(), positional[0]);
const manifestDir = path.dirname(manifestPath);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

for (const pkg of manifest.packages) {
  const tarballPath = path.join(manifestDir, pkg.file);
  const otpArg = otp ? ` --otp=${shellQuote(otp)}` : "";
  execFileSync("bash", ["-lc", `npm publish ${shellQuote(tarballPath)}${otpArg}`], {
    stdio: "inherit",
  });
}
