import { statSync } from "node:fs";
import path from "node:path";

import { appendGithubOutput } from "../lib/github.js";
import { initBuildEnv } from "../lib/init-build-env.js";
import { resolveBuildDir } from "../lib/paths.js";

const PYTHON = "python";

// 初始化编译 env 并输出 command/args（供 watchdog/run spawn）
export function runPrepareCompile(options: {
  optDim: string;
  faSrc: string;
}): void {
  const faSrc = path.resolve(options.faSrc);
  try {
    statSync(faSrc);
  } catch {
    throw new Error(`flash-attention source not found: ${faSrc}`);
  }

  initBuildEnv({ optDim: options.optDim, exportGithubEnv: true });

  console.log(`Preparing compile for OPT_DIM=${options.optDim}`);

  const buildScript = path.join(resolveBuildDir(), "build-fa-steps.py");
  appendGithubOutput({
    command: PYTHON,
    args: JSON.stringify([
      buildScript,
      "--step",
      "compile",
      "--fa-src",
      faSrc,
      "-v",
    ]),
  });
}
