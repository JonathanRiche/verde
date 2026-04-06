#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..", "..");

if (process.argv.length !== 5) {
  console.error("usage: node scripts/release/package-npm.mjs <version> <release-assets-dir> <output-dir>");
  process.exit(1);
}

const rawVersion = process.argv[2];
const npmVersion = rawVersion.replace(/^v/, "");
const releaseAssetsDir = path.resolve(process.cwd(), process.argv[3]);
const outputDir = path.resolve(process.cwd(), process.argv[4]);

const tempRoot = mkdtempSync(path.join(os.tmpdir(), "verde-npm-"));
const stagingRoot = path.join(tempRoot, "staging");
mkdirSync(stagingRoot, { recursive: true });
mkdirSync(outputDir, { recursive: true });

const platformPackages = [
  {
    name: "verde-app-darwin-arm64",
    templateDir: path.join(repoRoot, "packages", "npm", "verde-darwin-arm64"),
    archiveName: `verde-${rawVersion}-macos-arm64.zip`,
    copyFromExtracted(extractDir, destDir) {
      cpSync(path.join(extractDir, "Verde.app"), path.join(destDir, "Verde.app"), {
        recursive: true,
        force: true,
      });
      chmodSync(path.join(destDir, "Verde.app", "Contents", "MacOS", "verde"), 0o755);
    },
  },
  {
    name: "verde-app-darwin-x64",
    templateDir: path.join(repoRoot, "packages", "npm", "verde-darwin-x64"),
    archiveName: `verde-${rawVersion}-macos-x86_64.zip`,
    copyFromExtracted(extractDir, destDir) {
      cpSync(path.join(extractDir, "Verde.app"), path.join(destDir, "Verde.app"), {
        recursive: true,
        force: true,
      });
      chmodSync(path.join(destDir, "Verde.app", "Contents", "MacOS", "verde"), 0o755);
    },
  },
  {
    name: "verde-app-linux-x64",
    templateDir: path.join(repoRoot, "packages", "npm", "verde-linux-x64"),
    archiveName: `verde-${rawVersion}-linux-x86_64.tar.gz`,
    copyFromExtracted(extractDir, destDir) {
      const extractedRoot = path.join(extractDir, `verde-${rawVersion}-linux-x86_64`);
      for (const entry of ["bin", "share", "install-local.sh", "README.md"]) {
        const source = path.join(extractedRoot, entry);
        if (!existsSync(source)) continue;
        cpSync(source, path.join(destDir, entry), {
          recursive: true,
          force: true,
        });
      }
      chmodSync(path.join(destDir, "bin", "verde"), 0o755);
    },
  },
];

function extractArchive(archivePath, destDir) {
  mkdirSync(destDir, { recursive: true });
  if (archivePath.endsWith(".zip")) {
    execFileSync(
      "python3",
      [
        "-c",
        "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])",
        archivePath,
        destDir,
      ],
      { stdio: "inherit" },
    );
    return;
  }

  if (archivePath.endsWith(".tar.gz")) {
    execFileSync(
      "python3",
      [
        "-c",
        "import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2])",
        archivePath,
        destDir,
      ],
      { stdio: "inherit" },
    );
    return;
  }

  throw new Error(`unsupported archive type: ${archivePath}`);
}

function rewritePackageJson(packageDir, updater) {
  const packageJsonPath = path.join(packageDir, "package.json");
  const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));
  updater(packageJson);
  writeFileSync(packageJsonPath, JSON.stringify(packageJson, null, 2) + "\n");
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

function packPackage(packageDir) {
  const tarballName = execFileSync(
    "bash",
    [
      "-lc",
      `npm pack ${shellQuote(packageDir)} --pack-destination ${shellQuote(outputDir)}`,
    ],
    {
      encoding: "utf8",
    },
  ).trim();
  return path.join(outputDir, tarballName);
}

const packedTarballs = [];

for (const pkg of platformPackages) {
  const archivePath = path.join(releaseAssetsDir, pkg.archiveName);
  if (!existsSync(archivePath)) {
    throw new Error(`missing release asset: ${archivePath}`);
  }

  const packageDir = path.join(stagingRoot, pkg.name.replace(/[\/@]/g, "_"));
  rmSync(packageDir, { recursive: true, force: true });
  cpSync(pkg.templateDir, packageDir, { recursive: true });

  const extractDir = path.join(tempRoot, "extract", pkg.name.replace(/[\/@]/g, "_"));
  rmSync(extractDir, { recursive: true, force: true });
  extractArchive(archivePath, extractDir);
  pkg.copyFromExtracted(extractDir, packageDir);
  rewritePackageJson(packageDir, (packageJson) => {
    packageJson.version = npmVersion;
  });

  const tarballPath = packPackage(packageDir);
  packedTarballs.push({
    name: pkg.name,
    file: path.basename(tarballPath),
  });
}

const launcherDir = path.join(stagingRoot, "verde");
rmSync(launcherDir, { recursive: true, force: true });
cpSync(path.join(repoRoot, "packages", "npm", "verde"), launcherDir, { recursive: true });
chmodSync(path.join(launcherDir, "bin", "verde.js"), 0o755);
rewritePackageJson(launcherDir, (packageJson) => {
  packageJson.version = npmVersion;
  for (const dependencyName of Object.keys(packageJson.optionalDependencies ?? {})) {
    packageJson.optionalDependencies[dependencyName] = npmVersion;
  }
});
const launcherTarballPath = packPackage(launcherDir);
packedTarballs.push({
    name: "verde-app",
    file: path.basename(launcherTarballPath),
  });

writeFileSync(
  path.join(outputDir, "npm-packages.json"),
  JSON.stringify(
    {
      version: npmVersion,
      packages: packedTarballs,
    },
    null,
    2,
  ) + "\n",
);
