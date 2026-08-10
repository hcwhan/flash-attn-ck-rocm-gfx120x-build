import { appendGithubOutput } from "../lib/github.js";
import { requireLockEnv } from "../lib/require-env.js";

export function runPlanOptDimMatrix(): void {
  const ckOptDim = requireLockEnv("CK_OPT_DIM");
  const primaryDim = requireLockEnv("PRIMARY_DIM");
  const optDimList = ckOptDim
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  const json = JSON.stringify(optDimList);

  console.log(`OPT_DIM matrix from lock: ${json}`);
  console.log(`Primary OPT_DIM shard: ${primaryDim}`);

  appendGithubOutput({
    "opt-dims-json": json,
    "primary-dim": primaryDim,
  });
}
