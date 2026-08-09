import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { run } from "../lib/exec.js";
import { initBuildEnv } from "../lib/init-build-env.js";
import { resolveBuildDir } from "../lib/paths.js";
import { requireLockEnv } from "../lib/require-env.js";

const PYTHON = "python";

export function runWheel(options: {
  faSrc: string;
  distDir: string;
  stagingRoot?: string;
  primaryDim?: string;
}): void {
  const faSrc = path.resolve(options.faSrc);
  try {
    statSync(faSrc);
  } catch {
    throw new Error(`flash-attention source not found: ${faSrc}`);
  }

  const hasStagingRoot = Boolean(options.stagingRoot);
  const hasPrimaryDim = Boolean(options.primaryDim);

  if (hasStagingRoot !== hasPrimaryDim) {
    throw new Error(
      "stagingRoot and primaryDim must both be set (parallel link) or both be omitted (serial link)",
    );
  }

  process.env.FLASH_ATTENTION_FORCE_BUILD = "TRUE";
  process.env.FLASH_ATTN_LOCAL_VERSION = requireLockEnv("FLASH_ATTN_LOCAL_VERSION");

  initBuildEnv({
    optDim: requireLockEnv("LockOptDim"),
  });

  const buildScript = path.join(resolveBuildDir(), "build-fa-steps.py");
  const step = hasStagingRoot ? "merge-and-wheel" : "wheel";

  const args = [
    buildScript,
    "--step",
    step,
    "--fa-src",
    faSrc,
    "--dist-dir",
    path.resolve(options.distDir),
    "-v",
  ];

  if (hasStagingRoot) {
    args.push(
      "--staging-root",
      path.resolve(options.stagingRoot!),
      "--primary-dim",
      options.primaryDim!,
    );
  }

  run(PYTHON, args);

  const distDir = path.resolve(options.distDir);
  console.log(`Dist dir: ${distDir}`);
  for (const name of readdirSync(distDir)) {
    console.log(name);
  }
}
