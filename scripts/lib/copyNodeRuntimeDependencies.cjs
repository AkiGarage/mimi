"use strict";

const fs = require("fs");
const path = require("path");

function copyNodeRuntimeDependencies(sourceProjectDir, destinationProjectDir) {
  const packageJson = readJson(path.join(sourceProjectDir, "package.json"));
  const packageLock = readJson(path.join(sourceProjectDir, "package-lock.json"));
  const dependencies = Object.keys(packageJson.dependencies || {});

  for (const dependency of dependencies) {
    const relativeDependencyPath = path.join("node_modules", ...dependency.split("/"));
    const sourceDependency = path.join(sourceProjectDir, relativeDependencyPath);
    const destinationDependency = path.join(destinationProjectDir, relativeDependencyPath);
    const lockEntry = packageLock.packages?.[relativeDependencyPath.split(path.sep).join("/")];
    const installedPackage = readJson(path.join(sourceDependency, "package.json"));

    if (!lockEntry?.version) {
      throw new Error(`missing_locked_runtime_dependency: ${dependency}`);
    }
    if (installedPackage.version !== lockEntry.version) {
      throw new Error(
        `runtime_dependency_version_mismatch: ${dependency} installed=${installedPackage.version} locked=${lockEntry.version}`,
      );
    }

    fs.mkdirSync(path.dirname(destinationDependency), { recursive: true });
    fs.cpSync(sourceDependency, destinationDependency, {
      recursive: true,
      filter: (source) => path.basename(source) !== ".DS_Store",
    });
  }
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`invalid_runtime_dependency_manifest: ${path.basename(filePath)}: ${error.message}`);
  }
}

module.exports = { copyNodeRuntimeDependencies };
