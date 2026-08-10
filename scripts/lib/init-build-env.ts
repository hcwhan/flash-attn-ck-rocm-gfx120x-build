import path from "node:path";
import { run } from "./exec.js";
import { requireMaxJobs } from "./max-jobs.js";
import { getRocmSdkPaths } from "./rocm-sdk-paths.js";
import { requireLockEnv } from "./require-env.js";

const PYTHON = "python";

export function initBuildEnv(options: { optDim: string }): void {
  const maxJobs = requireMaxJobs();
  console.log(`MAX_JOBS=${maxJobs}`);

  run(PYTHON, ["-m", "pip", "install", "numpy", "-q"], { quiet: true });

  // Upstream flash-attention setup.py reads OPT_DIM; value comes from CK_OPT_DIM or a shard tier.
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

  console.log(
    `Build env ready (GPU_ARCHS=${process.env.GPU_ARCHS}, OPT_DIM=${process.env.OPT_DIM})`,
  );
}
