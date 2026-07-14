function selectRuntimeExecutable(runtime, platform, args) {
  const useWindowsGui =
    platform === "win32" &&
    args.length === 0 &&
    runtime &&
    typeof runtime.getGuiExecutablePath === "function";

  if (useWindowsGui) {
    return runtime.getGuiExecutablePath();
  }
  if (runtime && typeof runtime.getCliExecutablePath === "function") {
    return runtime.getCliExecutablePath();
  }
  if (runtime && typeof runtime.getExecutablePath === "function") {
    return runtime.getExecutablePath();
  }
  return null;
}

module.exports = {
  selectRuntimeExecutable,
};
