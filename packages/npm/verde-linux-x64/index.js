const path = require("node:path");

function getExecutablePath() {
  return path.join(__dirname, "bin", "verde");
}

module.exports = {
  getExecutablePath,
};
