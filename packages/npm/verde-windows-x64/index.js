const path = require("node:path");

function getCliExecutablePath() {
  return path.join(__dirname, "bin", "verde.exe");
}

function getGuiExecutablePath() {
  return path.join(__dirname, "app", "Verde.exe");
}

module.exports = {
  getExecutablePath: getCliExecutablePath,
  getCliExecutablePath,
  getGuiExecutablePath,
};
