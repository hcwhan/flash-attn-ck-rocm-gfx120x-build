import { statSync } from "node:fs";
import path from "node:path";
import { spawnAsync } from "../lib/exec.js";
import { appendGithubEnv } from "../lib/github.js";
import { initBuildEnv } from "../lib/init-build-env.js";
import { resolveBuildDir } from "../lib/paths.js";
import { createWatchdog } from "../lib/watchdog.js";

const PYTHON = "python";

export async function runCompile(options: {
  optDim: string;
  faSrc: string;
}): Promise<void> {
  const faSrc = path.resolve(options.faSrc);
  try {
    statSync(faSrc);
  } catch {
    throw new Error(`flash-attention source not found: ${faSrc}`);
  }

  initBuildEnv({ optDim: options.optDim });

  const jobStartRaw = Number(process.env.JOB_START_TIME);
  const jobStartMs = Number.isFinite(jobStartRaw) ? jobStartRaw : Date.now();
  if (!Number.isFinite(jobStartRaw)) {
    console.warn("JOB_START_TIME not set; using current time as job start");
  }

  console.log(`Compiling OPT_DIM=${options.optDim} via in-process build_ext`);

  const buildScript = path.join(resolveBuildDir(), "build-fa-steps.py");
  const compileHandle = spawnAsync(PYTHON, [
    buildScript,
    "--step",
    "compile",
    "--fa-src",
    faSrc,
    "-v",
  ]);

  const watchdog = createWatchdog(compileHandle.child, jobStartMs);

  let exitCode: number | null;
  try {
    ({ exitCode } = await compileHandle.completed);
  } finally {
    await watchdog.whenAbortSettled();
    watchdog.stop();
  }

  if (exitCode === 0) {
    appendGithubEnv({ COMPILE_COMPLETE: "true" });
    console.log(`Compile done for OPT_DIM=${options.optDim}`);
    return;
  }

  if (watchdog.wasAborted()) {
    throw new Error("Compile interrupted by watchdog");
  }

  throw new Error(`compile failed (exit ${exitCode})`);
}
