import { statSync } from "node:fs";
import path from "node:path";
import { run } from "../lib/exec.js";
import { initBuildEnv } from "../lib/init-build-env.js";
import { resolveBuildDir } from "../lib/paths.js";

const PYTHON = "python";

export function runCompile(options: {
  optDim: string;
  faSrc: string;
}): void {
  const faSrc = path.resolve(options.faSrc);
  try {
    statSync(faSrc);
  } catch {
    throw new Error(`flash-attention source not found: ${faSrc}`);
  }

  initBuildEnv({ optDim: options.optDim });

  console.log(`Compiling OPT_DIM=${options.optDim} via in-process build_ext`);

  const buildScript = path.join(resolveBuildDir(), "build-fa-steps.py");
  run(PYTHON, [
    buildScript,
    "--step",
    "compile",
    "--fa-src",
    faSrc,
    "-v",
  ]);

  console.log(`Compile done for OPT_DIM=${options.optDim}`);
}
