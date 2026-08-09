import { appendGithubOutput } from "../lib/github.js";
import { requireLockEnv } from "../lib/require-env.js";

export function runPlanOptDimMatrix(): void {
  const lockOptDim = requireLockEnv("LockOptDim");
  const primaryOptDim = requireLockEnv("PRIMARY_OPT_DIM");
  const optDimList = lockOptDim
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  const json = JSON.stringify(optDimList);

  console.log(`OPT_DIM matrix from lock: ${json}`);
  console.log(`Primary OPT_DIM shard: ${primaryOptDim}`);

  appendGithubOutput({
    opt_dims_json: json,
    primary_opt_dim: primaryOptDim,
  });
}
