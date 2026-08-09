import { readFileSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

const versionLockSchema = z.object({
  python: z.string().min(1),
  pytorch: z.string().min(1),
  torch_device_extra: z.string().min(1),
  hip: z.string().min(1),
  rocm_index: z.string().min(1),
  gpu_archs: z.string().min(1),
  opt_dim: z.string().min(1),
  flash_attention_repo: z.string().min(1),
  flash_attention_build_commit: z.string().min(1),
  flash_attention_build_commit_date: z.string().min(1),
  expected_wheel_pattern: z.string().min(1),
  wheel_local_version: z.string().min(1),
  wheel_artifact_name: z.string().min(1),
  release_tag_prefix: z.string().min(1),
  release_name: z.string().min(1),
  release_prerelease: z.string().min(1),
});

export type VersionLockVars = {
  PYTHON_VERSION: string;
  PYTORCH_VERSION: string;
  TORCH_DEVICE: string;
  ROCM_INDEX: string;
  GPU_ARCHS: string;
  HIP_VERSION: string;
  LockOptDim: string;
  PRIMARY_OPT_DIM: string;
  OptDimList: string[];
  WHEEL_ARTIFACT_NAME: string;
  EXPECTED_WHEEL_PATTERN: string;
  FLASH_ATTN_LOCAL_VERSION: string;
  FLASH_ATTENTION_REPO: string;
  FLASH_ATTENTION_BUILD_COMMIT: string;
  FLASH_ATTENTION_BUILD_COMMIT_DATE: string;
  SOURCE_DATE_EPOCH: string;
  RELEASE_TAG_PREFIX: string;
  RELEASE_NAME: string;
  RELEASE_PRERELEASE: string;
};

function normalizeCommitDate(raw: string): {
  isoUtc: string;
  epochSeconds: number;
} {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error(
      "VERSION.lock.json flash_attention_build_commit_date is missing",
    );
  }

  const date = new Date(trimmed);
  if (Number.isNaN(date.getTime())) {
    throw new Error(
      `VERSION.lock.json flash_attention_build_commit_date is not valid ISO 8601: ${raw}`,
    );
  }

  const epochSeconds = Math.floor(date.getTime() / 1000);
  if (epochSeconds < 1) {
    throw new Error(
      "VERSION.lock.json flash_attention_build_commit_date must map to a positive Unix epoch",
    );
  }

  const isoUtc = date.toISOString().replace(/\.\d{3}Z$/, "Z");
  return { isoUtc, epochSeconds };
}

export function readVersionLock(workspaceRoot: string): VersionLockVars {
  const lockPath = path.join(workspaceRoot, "VERSION.lock.json");
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(lockPath, "utf8"));
  } catch {
    throw new Error(`VERSION.lock.json not found or invalid JSON: ${lockPath}`);
  }

  const lock = versionLockSchema.parse(parsed);

  const optDimList = lock.opt_dim
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (optDimList.length < 1) {
    throw new Error("VERSION.lock.json opt_dim is missing or empty");
  }

  const { isoUtc, epochSeconds } = normalizeCommitDate(
    lock.flash_attention_build_commit_date,
  );

  const vars: VersionLockVars = {
    PYTHON_VERSION: lock.python,
    PYTORCH_VERSION: lock.pytorch,
    TORCH_DEVICE: lock.torch_device_extra,
    ROCM_INDEX: lock.rocm_index,
    GPU_ARCHS: lock.gpu_archs,
    HIP_VERSION: lock.hip,
    LockOptDim: lock.opt_dim,
    PRIMARY_OPT_DIM: optDimList[0]!,
    OptDimList: optDimList,
    WHEEL_ARTIFACT_NAME: lock.wheel_artifact_name,
    EXPECTED_WHEEL_PATTERN: lock.expected_wheel_pattern,
    FLASH_ATTN_LOCAL_VERSION: lock.wheel_local_version,
    FLASH_ATTENTION_REPO: lock.flash_attention_repo,
    FLASH_ATTENTION_BUILD_COMMIT: lock.flash_attention_build_commit,
    FLASH_ATTENTION_BUILD_COMMIT_DATE: isoUtc,
    SOURCE_DATE_EPOCH: String(epochSeconds),
    RELEASE_TAG_PREFIX: lock.release_tag_prefix,
    RELEASE_NAME: lock.release_name,
    RELEASE_PRERELEASE: lock.release_prerelease,
  };

  console.log(
    `VERSION.lock: python=${vars.PYTHON_VERSION} pytorch=${vars.PYTORCH_VERSION} gpu=${vars.GPU_ARCHS} opt_dim=${vars.LockOptDim}`,
  );

  return vars;
}

export function versionLockEnvRecord(vars: VersionLockVars): Record<string, string> {
  const { OptDimList: _optDimList, ...envVars } = vars;
  return envVars;
}
