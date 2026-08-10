import { readdirSync, statSync } from "node:fs";
import path from "node:path";

const DIM_PATTERN = /_d(\d+)_/;
const API_OBJ_PATTERN = /^fmha_.*_api\.obj$/;

const REQUIRED_API_OBJS = new Set([
  "fmha_fwd_api.obj",
  "fmha_fwd_appendkv_api.obj",
  "fmha_fwd_splitkv_api.obj",
]);

function isApiDispatchObj(name: string): boolean {
  return API_OBJ_PATTERN.test(name);
}

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

export function parseLockOptDims(optDim: string): readonly string[] {
  const trimmed = optDim.trim();
  if (!trimmed) {
    throw new Error("OPT_DIM env is required");
  }
  if (!trimmed.includes(",")) {
    throw new Error(
      `OPT_DIM must be comma-separated tiers for link, got '${trimmed}'`,
    );
  }
  const dims = trimmed
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (dims.length === 0) {
    throw new Error("OPT_DIM is empty");
  }
  return dims;
}

function resolvePrimaryDim(
  primaryDim: string,
  expectedDims: readonly string[],
): string {
  if (!primaryDim) {
    throw new Error("primary_dim is required");
  }
  if (!expectedDims.includes(primaryDim)) {
    throw new Error(
      `primary_dim ${primaryDim} is not in OPT_DIM list: ${expectedDims.join(", ")}`,
    );
  }
  return primaryDim;
}

export function validateStaging(options: {
  stagingRoot: string;
  expectedDims: readonly string[];
  primaryDim: string;
}): void {
  let stagingRoot: string;
  try {
    stagingRoot = path.resolve(options.stagingRoot);
    if (!statSync(stagingRoot).isDirectory()) {
      throw new Error(`Staging root missing: ${stagingRoot}`);
    }
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("Staging root")) {
      throw error;
    }
    throw new Error(`Staging root missing: ${options.stagingRoot}`);
  }

  const primaryDim = resolvePrimaryDim(
    options.primaryDim,
    options.expectedDims,
  );
  const summary: Record<string, number> = {};

  for (const dim of options.expectedDims) {
    const shard = path.join(stagingRoot, `d${dim}`);
    try {
      if (!statSync(shard).isDirectory()) {
        throw new Error(`Missing OPT_DIM staging dir: ${shard}`);
      }
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("Missing OPT_DIM")) {
        throw error;
      }
      throw new Error(`Missing OPT_DIM staging dir: ${shard}`);
    }

    const objs = walkObjFiles(shard);
    summary[dim] = objs.length;
    if (objs.length === 0) {
      throw new Error(`No .obj files under ${shard}`);
    }

    const dimToken = `_d${dim}_`;
    const dimSpecific = objs.filter(
      (objPath) =>
        DIM_PATTERN.test(path.basename(objPath)) &&
        path.basename(objPath).includes(dimToken),
    );
    if (dimSpecific.length === 0) {
      throw new Error(`Shard d${dim} has no *_d${dim}_* kernel objects`);
    }

    const ninjaLog = path.join(shard, ".ninja_log");
    try {
      statSync(ninjaLog);
    } catch {
      throw new Error(
        `Shard d${dim} missing .ninja_log (upload-artifact must set include-hidden-files: true)`,
      );
    }
  }

  const primary = path.join(stagingRoot, `d${primaryDim}`);
  const primaryObjs = walkObjFiles(primary);
  const shared = primaryObjs.filter((objPath) => {
    const relPosix = path
      .relative(primary, objPath)
      .split(path.sep)
      .join("/");
    return relPosix.includes("csrc/flash_attn_ck/");
  });
  if (shared.length === 0) {
    throw new Error(
      `Primary shard d${primaryDim} missing csrc/flash_attn_ck shared objects`,
    );
  }

  const apiInPrimary = new Set(
    primaryObjs
      .map((objPath) => path.basename(objPath))
      .filter(isApiDispatchObj),
  );
  const missingApi = [...REQUIRED_API_OBJS].filter(
    (name) => !apiInPrimary.has(name),
  );
  if (missingApi.length > 0) {
    throw new Error(
      `Primary shard d${primaryDim} missing API dispatch objs: ${JSON.stringify(missingApi.sort())}`,
    );
  }
  const extraApi = [...apiInPrimary].filter(
    (name) => !REQUIRED_API_OBJS.has(name),
  );
  if (extraApi.length > 0) {
    throw new Error(
      `Primary shard d${primaryDim} unexpected API dispatch objs: ${JSON.stringify(extraApi.sort())}`,
    );
  }

  console.log(
    `Link staging validation OK: ${options.expectedDims
      .map((dim) => `d${dim}=${summary[dim]}`)
      .join(", ")}`,
  );
}
