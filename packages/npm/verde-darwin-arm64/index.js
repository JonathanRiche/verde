const path = require("node:path");

function getExecutablePath() {
  return path.join(__dirname, "Verde.app", "Contents", "MacOS", "verde");
}

module.exports = {
  getExecutablePath,
};
