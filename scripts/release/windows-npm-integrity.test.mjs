import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  verifyWindowsNpmPayload,
  WINDOWS_NPM_PAYLOAD_ENTRIES,
} from "./windows-npm-integrity.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..", "..");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function createFixture(root) {
  const files = new Map([
    ["test-terminal.ps1", Buffer.from("Write-Host 'terminal smoke'\n")],
    ["app/Verde.exe", Buffer.from("gui fixture\n")],
  ]);
  for (const [relativePath, contents] of files) {
    const destination = path.join(root, ...relativePath.split("/"));
    mkdirSync(path.dirname(destination), { recursive: true });
    writeFileSync(destination, contents);
  }

  const manifest = {
    schema_version: 1,
    files: [...files].map(([relativePath, contents]) => ({
      path: relativePath,
      size: contents.length,
      sha256: sha256(contents),
    })),
  };
  const manifestContents = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  writeFileSync(path.join(root, "PACKAGE-MANIFEST.json"), manifestContents);
  const checksums = [
    ...[...files].map(([relativePath, contents]) => `${sha256(contents)}  ${relativePath}`),
    `${sha256(manifestContents)}  PACKAGE-MANIFEST.json`,
  ];
  writeFileSync(path.join(root, "SHA256SUMS.txt"), `${checksums.join("\n")}\n`);
}

function withFixture(callback) {
  const root = mkdtempSync(path.join(os.tmpdir(), "verde-windows-npm-integrity-"));
  try {
    createFixture(root);
    callback(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("Windows npm payload retains the terminal smoke test", () => {
  assert.ok(WINDOWS_NPM_PAYLOAD_ENTRIES.includes("test-terminal.ps1"));
  const packageJson = JSON.parse(
    readFileSync(
      path.join(repoRoot, "packages", "npm", "verde-windows-x64", "package.json"),
      "utf8",
    ),
  );
  assert.ok(packageJson.files.includes("test-terminal.ps1"));
});

test("valid copied payload passes manifest and checksum verification", () => {
  withFixture((root) => {
    assert.deepEqual(verifyWindowsNpmPayload(root), {
      manifestFiles: 2,
      checksummedFiles: 3,
    });
  });
});

test("copied payload corruption is rejected", () => {
  withFixture((root) => {
    writeFileSync(path.join(root, "app", "Verde.exe"), "corrupt\n");
    assert.throws(
      () => verifyWindowsNpmPayload(root),
      /PACKAGE-MANIFEST\.json does not match copied payload: app\/Verde\.exe/,
    );
  });
});

test("checksum coverage omissions are rejected", () => {
  withFixture((root) => {
    const checksumPath = path.join(root, "SHA256SUMS.txt");
    const lines = readFileSync(checksumPath, "utf8")
      .split("\n")
      .filter((line) => !line.endsWith("  PACKAGE-MANIFEST.json"));
    writeFileSync(checksumPath, lines.join("\n"));
    assert.throws(() => verifyWindowsNpmPayload(root), /coverage mismatch/);
  });
});

test("unsafe manifest paths are rejected before file access", () => {
  withFixture((root) => {
    const manifestPath = path.join(root, "PACKAGE-MANIFEST.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.files[0].path = "../test-terminal.ps1";
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    assert.throws(() => verifyWindowsNpmPayload(root), /unsafe payload path/);
  });
});
