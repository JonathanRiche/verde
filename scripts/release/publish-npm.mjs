#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

if (process.argv.length !== 3) {
  console.error("usage: node scripts/release/publish-npm.mjs <manifest-path>");
  process.exit(1);
}

const manifestPath = path.resolve(process.cwd(), process.argv[2]);
const manifestDir = path.dirname(manifestPath);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

for (const pkg of manifest.packages) {
  const tarballPath = path.join(manifestDir, pkg.file);
  execFileSync("bash", ["-lc", `npm publish ${shellQuote(tarballPath)}`], {
    stdio: "inherit",
  });
}
