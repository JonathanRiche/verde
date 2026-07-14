const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");

const windowsRuntime = require("../../verde-windows-x64");
const { selectRuntimeExecutable } = require("../lib/runtime-executable");

test("argument-free Windows launch selects the GUI subsystem executable", () => {
  assert.equal(
    selectRuntimeExecutable(windowsRuntime, "win32", []),
    path.join(__dirname, "..", "..", "verde-windows-x64", "app", "Verde.exe"),
  );
});

test("Windows CLI arguments select the console executable", () => {
  assert.equal(
    selectRuntimeExecutable(windowsRuntime, "win32", ["version", "--json"]),
    path.join(__dirname, "..", "..", "verde-windows-x64", "bin", "verde.exe"),
  );
});
