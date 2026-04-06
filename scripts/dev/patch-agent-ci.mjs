import fs from "node:fs";
import path from "node:path";

const repoRoot = path.resolve(import.meta.dirname, "..", "..");
const agentCiRoot = path.join(repoRoot, "node_modules", "@redwoodjs", "agent-ci");

if (!fs.existsSync(agentCiRoot)) {
  process.exit(0);
}

const patchFile = (relativePath, transforms) => {
  const filePath = path.join(agentCiRoot, relativePath);
  let source = fs.readFileSync(filePath, "utf8");
  let changed = false;

  for (const { from, to } of transforms) {
    if (source.includes(to)) {
      continue;
    }
    if (!source.includes(from)) {
      throw new Error(`Expected snippet not found in ${relativePath}`);
    }
    source = source.replace(from, to);
    changed = true;
  }

  if (changed) {
    fs.writeFileSync(filePath, source);
  }
};

patchFile("dist/runner/directory-setup.js", [
  {
    from: '    const workspaceDir = path.resolve(containerWorkDir, repoName, repoName);\n',
    to: '    const workspaceDir = path.resolve(containerWorkDir, repoName, repoName);\n    const containerPnpmMountDir = path.resolve(containerWorkDir, ".pnpm-store");\n',
  },
  {
    from: "        workspaceDir,\n        containerWorkDir,\n",
    to: "        workspaceDir,\n        containerWorkDir,\n        containerPnpmMountDir,\n",
  },
  {
    from: "        workspaceDir,\n        containerWorkDir,\n",
    to: "        workspaceDir,\n        containerWorkDir,\n        containerPnpmMountDir,\n",
  },
]);

patchFile("dist/runner/local-job.js", [
  {
    from: `        if (jobSucceeded && fs.existsSync(dirs.containerWorkDir)) {\n            fs.rmSync(dirs.containerWorkDir, { recursive: true, force: true });\n        }\n`,
    to: `        if (jobSucceeded && fs.existsSync(dirs.containerWorkDir)) {\n            try {\n                fs.rmSync(dirs.containerWorkDir, { recursive: true, force: true });\n            }\n            catch (error) {\n                if (error?.code !== "EACCES" && error?.code !== "EPERM") {\n                    throw error;\n                }\n                debugRunner(\`Ignoring containerWorkDir cleanup error: \${String(error)}\`);\n            }\n        }\n`,
  },
]);
