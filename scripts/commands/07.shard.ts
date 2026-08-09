import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { appendGithubEnv } from "../lib/github.js";

function walkObjFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...walkObjFiles(fullPath));
    } else if (entry.isFile() && entry.name.endsWith(".obj")) {
      results.push(fullPath);
    }
  }
  return results;
}

export function runShard(options: {
  faSrc: string;
  optDim: string;
}): string {
  const faSrc = path.resolve(options.faSrc);
  const buildDir = path.join(faSrc, "build");
  try {
    statSync(buildDir);
  } catch {
    throw new Error(`flash-attention build directory missing: ${buildDir}`);
  }

  const candidates = readdirSync(buildDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("temp.win-"))
    .map((entry) => path.join(buildDir, entry.name));

  if (candidates.length !== 1) {
    throw new Error(
      `Expected exactly one build/temp.win-* directory under ${buildDir}, found ${candidates.length}`,
    );
  }

  const releaseDir = path.join(candidates[0]!, "Release");
  try {
    statSync(releaseDir);
  } catch {
    throw new Error(`Release directory missing: ${releaseDir}`);
  }

  const dimToken = `_d${options.optDim}_`;
  const objFiles = walkObjFiles(releaseDir);
  const dimKernelCount = objFiles.filter((filePath) =>
    path.basename(filePath).includes(dimToken),
  ).length;

  if (objFiles.length < 1) {
    throw new Error(`No .obj files under ${releaseDir}`);
  }
  if (dimKernelCount < 1) {
    throw new Error(
      `No *_d${options.optDim}_* kernel objects under ${releaseDir}`,
    );
  }

  const ninjaLog = path.join(releaseDir, ".ninja_log");
  try {
    statSync(ninjaLog);
  } catch {
    throw new Error(
      `Release dir missing .ninja_log: ${releaseDir} (upload-artifact must set include-hidden-files: true)`,
    );
  }

  console.log(
    `Release dir: ${releaseDir} (${objFiles.length} objs, ${dimKernelCount} dim-kernel)`,
  );

  appendGithubEnv({ RELEASE_DIR: releaseDir });
  console.log(`Uploading object files from ${releaseDir}`);

  return releaseDir;
}
