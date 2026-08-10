import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { buildPipToolchainCacheKey } from "./pip-cache-key.js";

const gitShaSchema = z
  .string()
  .regex(/^[0-9a-f]{40}$/i, "must be a 40-character git commit SHA");

const ckOptDimSchema = z
  .string()
  .min(1)
  .refine((value) => {
    const parts = value
      .split(",")
      .map((part) => part.trim())
      .filter(Boolean);
    return (
      parts.length >= 1 &&
      parts.every((part) => /^[1-9]\d*$/.test(part))
    );
  }, "must be comma-separated positive integers (e.g. 32,64,128,256)");

const versionLockSchema = z.object({
  toolchain: z.object({
    python: z.string().min(1),
    pytorch: z.string().min(1),
    torch_device_extra: z.string().min(1),
    rocm_index: z.string().min(1),
    rocm: z.string().min(1),
  }),
  flash_attention: z.object({
    repo: z.string().min(1),
    min_commit: gitShaSchema,
    build_commit: gitShaSchema,
    build_commit_date: z.string().min(1),
  }),
  compile: z.object({
    gpu_archs: z.string().min(1),
    ck_opt_dim: ckOptDimSchema,
    ck_disable_bwd: z.boolean(),
  }),
  wheel: z.object({
    wheel_local_version: z.string().min(1),
    wheel_artifact_name: z.string().min(1),
  }),
  release: z.object({
    release_tag_prefix: z.string().min(1),
    release_title_prefix: z.string().min(1),
  }),
});

export type VersionLockVars = {
  PYTHON_VERSION: string;
  PYTORCH_VERSION: string;
  TORCH_DEVICE_EXTRA: string;
  ROCM_INDEX: string;
  ROCM_VERSION: string;
  PIP_TOOLCHAIN_CACHE_KEY: string;
  GPU_ARCHS: string;
  CK_OPT_DIM: string;
  CK_FMHA_DISABLE_BWD: string;
  PRIMARY_DIM: string;
  ckOptDimList: string[];
  WHEEL_ARTIFACT_NAME: string;
  EXPECTED_WHEEL_PATTERN: string;
  WHEEL_LOCAL_VERSION: string;
  FLASH_ATTENTION_REPO: string;
  FLASH_ATTENTION_BUILD_COMMIT: string;
  FLASH_ATTENTION_BUILD_COMMIT_DATE: string;
  SOURCE_DATE_EPOCH: string;
  RELEASE_TAG_PREFIX: string;
  RELEASE_TITLE_PREFIX: string;
};

function pythonWheelTag(python: string): string {
  const [major, minor = ""] = python.split(".");
  if (!major || !/^\d+$/.test(major) || (minor && !/^\d+$/.test(minor))) {
    throw new Error(
      `VERSION.lock.json toolchain.python must look like major.minor (e.g. 3.12), got ${python}`,
    );
  }
  return `cp${major}${minor}`;
}

export function expectedWheelPattern(
  localVersion: string,
  python: string,
): string {
  const tag = pythonWheelTag(python);
  return `flash_attn-*+${localVersion}-${tag}-${tag}-win_amd64.whl`;
}

export function versionLockFileHash8(workspaceRoot: string): string {
  const lockPath = path.join(workspaceRoot, "VERSION.lock.json");
  let contents: Buffer;
  try {
    contents = readFileSync(lockPath);
  } catch {
    throw new Error(`VERSION.lock.json not found: ${lockPath}`);
  }
  return createHash("sha256").update(contents).digest("hex").slice(0, 8);
}

function normalizeCommitDate(raw: string): {
  isoUtc: string;
  epochSeconds: number;
} {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error(
      "VERSION.lock.json flash_attention.build_commit_date is missing",
    );
  }

  const date = new Date(trimmed);
  if (Number.isNaN(date.getTime())) {
    throw new Error(
      `VERSION.lock.json flash_attention.build_commit_date is not valid ISO 8601: ${raw}`,
    );
  }

  const epochSeconds = Math.floor(date.getTime() / 1000);
  if (epochSeconds < 1) {
    throw new Error(
      "VERSION.lock.json flash_attention.build_commit_date must map to a positive Unix epoch",
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

  const ckOptDimList = lock.compile.ck_opt_dim
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);

  const { isoUtc, epochSeconds } = normalizeCommitDate(
    lock.flash_attention.build_commit_date,
  );

  const wheelLocalVersion = lock.wheel.wheel_local_version;

  const vars: VersionLockVars = {
    PYTHON_VERSION: lock.toolchain.python,
    PYTORCH_VERSION: lock.toolchain.pytorch,
    TORCH_DEVICE_EXTRA: lock.toolchain.torch_device_extra,
    ROCM_INDEX: lock.toolchain.rocm_index,
    ROCM_VERSION: lock.toolchain.rocm,
    PIP_TOOLCHAIN_CACHE_KEY: buildPipToolchainCacheKey({
      pythonVersion: lock.toolchain.python,
      pytorchVersion: lock.toolchain.pytorch,
      torchDeviceExtra: lock.toolchain.torch_device_extra,
      rocmVersion: lock.toolchain.rocm,
      rocmIndex: lock.toolchain.rocm_index,
    }),
    GPU_ARCHS: lock.compile.gpu_archs,
    CK_OPT_DIM: lock.compile.ck_opt_dim,
    CK_FMHA_DISABLE_BWD: lock.compile.ck_disable_bwd ? "1" : "0",
    PRIMARY_DIM: ckOptDimList[0]!,
    ckOptDimList,
    WHEEL_ARTIFACT_NAME: lock.wheel.wheel_artifact_name,
    EXPECTED_WHEEL_PATTERN: expectedWheelPattern(
      wheelLocalVersion,
      lock.toolchain.python,
    ),
    WHEEL_LOCAL_VERSION: wheelLocalVersion,
    FLASH_ATTENTION_REPO: lock.flash_attention.repo,
    FLASH_ATTENTION_BUILD_COMMIT: lock.flash_attention.build_commit,
    FLASH_ATTENTION_BUILD_COMMIT_DATE: isoUtc,
    SOURCE_DATE_EPOCH: String(epochSeconds),
    RELEASE_TAG_PREFIX: lock.release.release_tag_prefix,
    RELEASE_TITLE_PREFIX: lock.release.release_title_prefix,
  };

  console.log(
    `VERSION.lock: python=${vars.PYTHON_VERSION} pytorch=${vars.PYTORCH_VERSION} gpu=${vars.GPU_ARCHS} ck_opt_dim=${vars.CK_OPT_DIM} ck_disable_bwd=${vars.CK_FMHA_DISABLE_BWD}`,
  );

  return vars;
}

export function versionLockEnvRecord(
  vars: VersionLockVars,
): Record<string, string> {
  const { ckOptDimList: _ckOptDimList, ...envVars } = vars;
  return envVars;
}
