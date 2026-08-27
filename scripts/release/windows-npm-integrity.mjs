import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import path from "node:path";

export const WINDOWS_NPM_PAYLOAD_ENTRIES = Object.freeze([
  "app",
  "bin",
  "share",
  "README.md",
  "LICENSE",
  "WINDOWS-RUNTIME.txt",
  "WINDOWS-SIGNING.json",
  "PACKAGE-MANIFEST.json",
  "SHA256SUMS.txt",
  "test-terminal.ps1",
  "install.ps1",
]);

const REQUIRED_MANIFEST_PATHS = Object.freeze([
  "test-terminal.ps1",
]);
const SHA256_PATTERN = /^[0-9a-f]{64}$/;

function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function resolvePayloadPath(packageRoot, relativePath, sourceName) {
  if (
    typeof relativePath !== "string" ||
    relativePath.length === 0 ||
    relativePath.includes("\\") ||
    relativePath.includes(":") ||
    path.posix.isAbsolute(relativePath) ||
    path.posix.normalize(relativePath) !== relativePath ||
    relativePath === "." ||
    relativePath.startsWith("../")
  ) {
    throw new Error(`${sourceName} contains unsafe payload path: ${String(relativePath)}`);
  }

  const resolvedRoot = path.resolve(packageRoot);
  const resolvedPath = path.resolve(resolvedRoot, ...relativePath.split("/"));
  if (!resolvedPath.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`${sourceName} payload path escapes package root: ${relativePath}`);
  }
  return resolvedPath;
}

function requireRegularFile(filePath, sourceName, relativePath) {
  let metadata;
  try {
    metadata = lstatSync(filePath);
  } catch {
    throw new Error(`${sourceName} references missing payload: ${relativePath}`);
  }
  if (!metadata.isFile()) {
    throw new Error(`${sourceName} payload is not a regular file: ${relativePath}`);
  }
  return metadata;
}

function addUniquePath(paths, caseFoldedPaths, relativePath, sourceName) {
  const folded = relativePath.toLowerCase();
  if (paths.has(relativePath) || caseFoldedPaths.has(folded)) {
    throw new Error(`${sourceName} contains a duplicate or case-colliding path: ${relativePath}`);
  }
  paths.add(relativePath);
  caseFoldedPaths.add(folded);
}

function parseManifest(packageRoot) {
  const manifestPath = path.join(packageRoot, "PACKAGE-MANIFEST.json");
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`could not parse PACKAGE-MANIFEST.json: ${error.message}`);
  }
  if (manifest?.schema_version !== 1 || !Array.isArray(manifest.files) || manifest.files.length === 0) {
    throw new Error("PACKAGE-MANIFEST.json must contain a non-empty schema_version 1 files array");
  }

  const paths = new Set();
  const caseFoldedPaths = new Set();
  const hashes = new Map();
  for (const entry of manifest.files) {
    const relativePath = entry?.path;
    const filePath = resolvePayloadPath(packageRoot, relativePath, "PACKAGE-MANIFEST.json");
    addUniquePath(paths, caseFoldedPaths, relativePath, "PACKAGE-MANIFEST.json");
    if (!Number.isSafeInteger(entry.size) || entry.size < 0 || !SHA256_PATTERN.test(entry.sha256)) {
      throw new Error(`PACKAGE-MANIFEST.json has invalid metadata for ${relativePath}`);
    }
    const metadata = requireRegularFile(filePath, "PACKAGE-MANIFEST.json", relativePath);
    const actualHash = sha256File(filePath);
    if (metadata.size !== entry.size || actualHash !== entry.sha256) {
      throw new Error(`PACKAGE-MANIFEST.json does not match copied payload: ${relativePath}`);
    }
    hashes.set(relativePath, actualHash);
  }

  for (const requiredPath of REQUIRED_MANIFEST_PATHS) {
    if (!paths.has(requiredPath)) {
      throw new Error(`PACKAGE-MANIFEST.json does not retain required payload: ${requiredPath}`);
    }
  }
  return { paths, hashes };
}

function verifyChecksums(packageRoot, manifestPaths, knownHashes) {
  const checksumPath = path.join(packageRoot, "SHA256SUMS.txt");
  let checksumSource;
  try {
    checksumSource = readFileSync(checksumPath, "utf8");
  } catch (error) {
    throw new Error(`could not read SHA256SUMS.txt: ${error.message}`);
  }

  const paths = new Set();
  const caseFoldedPaths = new Set();
  for (const line of checksumSource.split(/\r?\n/)) {
    if (line.length === 0) continue;
    const match = /^([0-9a-f]{64})  (.+)$/.exec(line);
    if (match === null) {
      throw new Error(`SHA256SUMS.txt contains an invalid line: ${line}`);
    }
    const [, expectedHash, relativePath] = match;
    const filePath = resolvePayloadPath(packageRoot, relativePath, "SHA256SUMS.txt");
    addUniquePath(paths, caseFoldedPaths, relativePath, "SHA256SUMS.txt");
    requireRegularFile(filePath, "SHA256SUMS.txt", relativePath);
    const actualHash = knownHashes.get(relativePath) ?? sha256File(filePath);
    if (actualHash !== expectedHash) {
      throw new Error(`SHA256SUMS.txt does not match copied payload: ${relativePath}`);
    }
  }

  const expectedPaths = new Set([...manifestPaths, "PACKAGE-MANIFEST.json"]);
  const missingPaths = [...expectedPaths].filter((entry) => !paths.has(entry));
  const unexpectedPaths = [...paths].filter((entry) => !expectedPaths.has(entry));
  if (missingPaths.length !== 0 || unexpectedPaths.length !== 0) {
    throw new Error(
      `SHA256SUMS.txt coverage mismatch; missing=[${missingPaths.sort().join(", ")}], ` +
        `unexpected=[${unexpectedPaths.sort().join(", ")}]`,
    );
  }
  return paths;
}

export function verifyWindowsNpmPayload(packageRoot) {
  const { paths: manifestPaths, hashes } = parseManifest(packageRoot);
  const checksumPaths = verifyChecksums(packageRoot, manifestPaths, hashes);
  return {
    manifestFiles: manifestPaths.size,
    checksummedFiles: checksumPaths.size,
  };
}
