import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const packageScript = path.join(scriptDir, "package-npm.mjs");

function runPackageScript(args, options = {}) {
  return spawnSync(process.execPath, [packageScript, ...args], {
    encoding: "utf8",
    ...options,
    env: {
      ...process.env,
      ...options.env,
    },
  });
}

test("--help documents default and platform-specific packaging", () => {
  const result = runPackageScript(["--help"]);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Without --platform, all platform packages are included/);
  assert.match(result.stdout, /--platform <platform>/);
  assert.match(result.stdout, /windows-x64/);
});

test("unsupported platform selectors are rejected before packaging", () => {
  const result = runPackageScript([
    "--platform",
    "plan9-x64",
    "v1.2.3",
    "release-assets",
    "output",
  ]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported platform: plan9-x64/);
  assert.match(result.stderr, /windows-x64/);
});

test("windows-x64 selection skips other platform asset lookups", () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), "verde-package-npm-test-"));
  const releaseAssetsDir = path.join(tempRoot, "release-assets");
  const outputDir = path.join(tempRoot, "output");
  mkdirSync(releaseAssetsDir);

  try {
    const result = runPackageScript(
      [
        "--platform",
        "windows-x64",
        "v1.2.3",
        releaseAssetsDir,
        outputDir,
      ],
      { env: { TMPDIR: tempRoot } },
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, /verde-v1\.2\.3-windows-x86_64\.zip/);
    assert.doesNotMatch(result.stderr, /macos|linux/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("omitting --platform retains all-platform asset lookup", () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), "verde-package-npm-test-"));
  const releaseAssetsDir = path.join(tempRoot, "release-assets");
  const outputDir = path.join(tempRoot, "output");
  mkdirSync(releaseAssetsDir);

  try {
    const result = runPackageScript(
      ["v1.2.3", releaseAssetsDir, outputDir],
      { env: { TMPDIR: tempRoot } },
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, /verde-v1\.2\.3-macos-arm64\.zip/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("missing --platform value is rejected", () => {
  const result = runPackageScript(["--platform"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /--platform requires a value/);
});

test("unknown options are rejected", () => {
  const result = runPackageScript([
    "--platfrom",
    "windows-x64",
    "v1.2.3",
    "release-assets",
    "output",
  ]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unknown option: --platfrom/);
});
