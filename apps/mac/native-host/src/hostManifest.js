const os = require("os");
const path = require("path");
const { normalizeExtensionOrigin } = require("../../shared/extensionOrigin.cjs");

const HOST_NAME = "com.akigarage.jp_dub";
const HOST_DESCRIPTION = "Mimi on-demand local server launcher";

function chromeManifestPath(homeDir = os.homedir()) {
  return path.join(
    homeDir,
    "Library",
    "Application Support",
    "Google",
    "Chrome",
    "NativeMessagingHosts",
    `${HOST_NAME}.json`,
  );
}

function nativeHostWrapperPath(homeDir = os.homedir()) {
  return path.join(homeDir, "Library", "Application Support", "JP Dub", "NativeHost", "jp-dub-native-host");
}

function buildHostManifest({ hostPath, extensionOrigin }) {
  if (!path.isAbsolute(hostPath)) throw new Error("native_host_path_must_be_absolute");
  return {
    name: HOST_NAME,
    description: HOST_DESCRIPTION,
    path: hostPath,
    type: "stdio",
    allowed_origins: [normalizeExtensionOrigin(extensionOrigin, { trailingSlash: true })],
  };
}

module.exports = {
  HOST_DESCRIPTION,
  HOST_NAME,
  buildHostManifest,
  chromeManifestPath,
  nativeHostWrapperPath,
  normalizeExtensionOrigin,
};
