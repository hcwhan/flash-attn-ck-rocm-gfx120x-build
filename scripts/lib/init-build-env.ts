import path from "node:path";

import { run } from "./exec.js";
import { appendGithubEnv } from "./github.js";
import { requireMaxJobs } from "./max-jobs.js";
import { getRocmSdkPaths } from "./rocm-sdk-paths.js";
import { requireLockEnv } from "./require-env.js";

const PYTHON = "python";

const BUILD_ENV_INITIALIZED = "FA2_BUILD_ENV_INITIALIZED";

// initBuildEnv 写入或覆盖的 env 键（供 export 至 GITHUB_ENV）
const BUILD_ENV_VAR_NAMES = [
  BUILD_ENV_INITIALIZED,
  "MAX_JOBS",
  "OPT_DIM",
  "ROCM_HOME",
  "ROCM_PATH",
  "HIP_PATH",
  "HIP_INCLUDE_PATH",
  "HIP_DEVICE_LIB_PATH",
  "DEVICE_LIB_PATH",
  "CPATH",
  "INCLUDE",
  "PATH",
  "CC",
  "CXX",
  "DISTUTILS_USE_SDK",
  "GPU_ARCHS",
  "BUILD_TARGET",
  "SOURCE_DATE_EPOCH",
  "CFLAGS",
  "CXXFLAGS",
] as const;

// 将编译 env 追加至 GITHUB_ENV（供后续 watchdog/run spawn 继承）
function exportBuildEnvToGithub(): void {
  const vars: Record<string, string> = {};
  for (const name of BUILD_ENV_VAR_NAMES) {
    const value = process.env[name];
    if (value !== undefined) {
      vars[name] = value;
    }
  }
  appendGithubEnv(vars);
}

export function initBuildEnv(options: {
  optDim: string;
  exportGithubEnv?: boolean;
}): void {
  if (process.env[BUILD_ENV_INITIALIZED] === "true") {
    process.env.OPT_DIM = options.optDim;
    console.log(
      `Build env already initialized (${BUILD_ENV_INITIALIZED}=true), skipping duplicate setup (OPT_DIM=${options.optDim})`,
    );
    return;
  }

  const maxJobs = requireMaxJobs();
  process.env.MAX_JOBS = String(maxJobs);
  console.log(`MAX_JOBS=${maxJobs}`);

  run(PYTHON, ["-m", "pip", "install", "numpy", "-q"], { quiet: true });

  // upstream flash-attention setup.py 读取 OPT_DIM；值来自 CK_OPT_DIM 或 shard 档位。
  process.env.OPT_DIM = options.optDim;

  const gpuArchs = requireLockEnv("GPU_ARCHS");
  const sourceDateEpoch = requireLockEnv("SOURCE_DATE_EPOCH");
  const flashAttentionBuildCommitDate = requireLockEnv(
    "FLASH_ATTENTION_BUILD_COMMIT_DATE",
  );
  const { coreRoot, develRoot } = getRocmSdkPaths();

  const llvmBin = path.join(coreRoot, "lib", "llvm", "bin");
  const rocmBin = path.join(develRoot, "bin");
  const rocmInclude = path.join(develRoot, "include");
  const deviceLibPath = path.join(coreRoot, "lib", "llvm", "amdgcn", "bitcode");

  process.env.ROCM_HOME = develRoot;
  process.env.ROCM_PATH = develRoot;
  process.env.HIP_PATH = develRoot;
  process.env.HIP_INCLUDE_PATH = rocmInclude;
  process.env.HIP_DEVICE_LIB_PATH = deviceLibPath;
  process.env.DEVICE_LIB_PATH = deviceLibPath;
  process.env.CPATH = process.env.CPATH
    ? `${rocmInclude};${process.env.CPATH}`
    : rocmInclude;
  process.env.INCLUDE = process.env.INCLUDE
    ? `${rocmInclude};${process.env.INCLUDE}`
    : rocmInclude;
  process.env.PATH = `${llvmBin};${rocmBin};${process.env.PATH ?? ""}`;
  process.env.CC = "clang-cl";
  process.env.CXX = "clang-cl";
  process.env.DISTUTILS_USE_SDK = "1";
  process.env.GPU_ARCHS = gpuArchs;
  process.env.BUILD_TARGET = "rocm";
  process.env.SOURCE_DATE_EPOCH = sourceDateEpoch;

  console.log(
    `SOURCE_DATE_EPOCH=${process.env.SOURCE_DATE_EPOCH} (flash_attention.build_commit_date=${flashAttentionBuildCommitDate})`,
  );
  console.log(`GPU_ARCHS=${process.env.GPU_ARCHS}`);
  console.log(`OPT_DIM=${process.env.OPT_DIM}`);
  console.log(`ROCM_HOME=${process.env.ROCM_HOME}`);

  run(PYTHON, [
    "-c",
    "import torch; print('torch', torch.__version__); print('rocm', torch.version.rocm); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)",
  ]);

  const clangClFlags =
    "-Wno-ignored-attributes -Wno-unknown-argument -Wno-unused-command-line-argument -Wno-unknown-attributes -Wno-inconsistent-dllimport -Wno-cuda-compat -Wno-pass-failed";

  process.env.CFLAGS = process.env.CFLAGS
    ? `${process.env.CFLAGS} ${clangClFlags}`
    : clangClFlags;
  process.env.CXXFLAGS = process.env.CXXFLAGS
    ? `${process.env.CXXFLAGS} ${clangClFlags}`
    : clangClFlags;

  process.env[BUILD_ENV_INITIALIZED] = "true";

  if (options.exportGithubEnv) {
    exportBuildEnvToGithub();
  }

  console.log(
    `Build env ready (GPU_ARCHS=${process.env.GPU_ARCHS}, OPT_DIM=${process.env.OPT_DIM})`,
  );
}
