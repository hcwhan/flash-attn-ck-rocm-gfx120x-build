import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { run } from "../lib/exec.js";
import { initBuildEnv } from "../lib/init-build-env.js";
import { resolveBuildDir } from "../lib/paths.js";
import { requireLockEnv } from "../lib/require-env.js";
import {
  parseCkOptDims,
  validateStaging,
} from "../lib/validate-staging.js";

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
  // upstream flash-attention setup.py 在 wheel 时读取 FLASH_ATTN_LOCAL_VERSION。
  process.env.FLASH_ATTN_LOCAL_VERSION = requireLockEnv("WHEEL_LOCAL_VERSION");

  if (hasStagingRoot) {
    // parallel link job：独立 runner，须完整初始化 build env。
    initBuildEnv({
      optDim: requireLockEnv("CK_OPT_DIM"),
    });
  } else {
    // serial link：同 job 内 compile 已由 06.prepare 导出 build env；重复
    // initBuildEnv 会叠加 CPATH/INCLUDE，导致 wheel build_ext 命令 hash 漂移。
    console.log(
      "Serial link: reusing compile build env from GITHUB_ENV (skipping initBuildEnv)",
    );
  }

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
    const stagingRoot = path.resolve(options.stagingRoot!);
    validateStaging({
      stagingRoot,
      expectedDims: parseCkOptDims(requireLockEnv("CK_OPT_DIM")),
      primaryDim: options.primaryDim!,
    });

    args.push("--staging-root", stagingRoot, "--primary-dim", options.primaryDim!);
  }

  run(PYTHON, args);

  const distDir = path.resolve(options.distDir);
  console.log(`Dist dir: ${distDir}`);
  for (const name of readdirSync(distDir)) {
    console.log(name);
  }
}
