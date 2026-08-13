import { createHash } from "node:crypto";
import {
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import {
  readBuildCaches,
  validateBuildCachesForVariant,
} from "../lib/build-caches.js";
import { run } from "../lib/exec.js";
import {
  requireGithubActionsEnv,
  requireLockEnv,
} from "../lib/require-env.js";

const PYTHON = "python";

const WHEEL_INSPECT_CODE = `
import re
import sys
import zipfile
from pathlib import Path

wheel = sys.argv[1]
ck_opt_dim = sys.argv[2]
expected_local = sys.argv[3]
min_pyd_bytes = 1024 * 1024

def wheel_filename_local(local: str) -> str:
    return local.replace('-', '.').replace('_', '.')

opt_dims = [int(part) for part in ck_opt_dim.split(',') if part.strip()]
if not opt_dims:
    raise SystemExit('ERROR: CK_OPT_DIM is missing or empty')

wheel_name = Path(wheel).name
filename_local = wheel_filename_local(expected_local)
local_tag = f'+{filename_local}'
if local_tag not in wheel_name:
    raise SystemExit(
        f'ERROR: wheel filename missing local version tag {local_tag!r}: {wheel_name}'
    )
print(f'OK wheel local tag {filename_local}')

with zipfile.ZipFile(wheel) as zf:
    names = zf.namelist()
    pyds = [
        name for name in names
        if name.endswith('.pyd') and 'flash_attn_2_cuda' in name
    ]
    if not pyds:
        raise SystemExit('ERROR: flash_attn_2_cuda .pyd not found in wheel archive')
    for name in pyds:
        info = zf.getinfo(name)
        if info.file_size < min_pyd_bytes:
            raise SystemExit(f'ERROR: {name} too small ({info.file_size} bytes)')
        print(f'OK {name} size={info.file_size}')

    meta_paths = [name for name in names if name.endswith('.dist-info/METADATA')]
    if not meta_paths:
        raise SystemExit('ERROR: METADATA not found in wheel archive')
    meta_text = zf.read(meta_paths[0]).decode('utf-8', errors='replace')

    if not re.search(r'^Name: flash_attn\\s*$', meta_text, re.M):
        raise SystemExit('ERROR: wheel METADATA Name is not flash_attn')
    version_match = re.search(r'^Version: (.+)$', meta_text, re.M)
    if not version_match:
        raise SystemExit('ERROR: wheel METADATA missing Version')
    wheel_version = version_match.group(1).strip()
    if not wheel_version:
        raise SystemExit('ERROR: wheel METADATA Version is empty')

    torch_req = [
        line for line in meta_text.splitlines()
        if line.startswith('Requires-Dist: torch')
    ]
    if not torch_req:
        raise SystemExit('ERROR: wheel METADATA missing Requires-Dist: torch')

    print(f'OK METADATA Name=flash_attn Version={wheel_version}')
    print(f'OK METADATA {torch_req[0]}')
`.trim();

function matchesGlob(name: string, pattern: string): boolean {
  const regex = new RegExp(
    `^${pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`,
    "i",
  );
  return regex.test(name);
}

function readWorkflowDispatch(): {
  ninja_workers: number;
  use_cache: boolean;
  ck_disable_bwd: boolean;
} {
  const maxJobs = requireGithubActionsEnv("MAX_JOBS");
  const useCache = requireGithubActionsEnv("USE_CACHE");
  const ckFmhaDisableBwd = requireGithubActionsEnv("CK_FMHA_DISABLE_BWD");
  const ninjaWorkers = Number(maxJobs);
  if (
    !Number.isFinite(ninjaWorkers) ||
    !Number.isInteger(ninjaWorkers) ||
    ninjaWorkers < 1
  ) {
    throw new Error(`MAX_JOBS must be a positive integer, got ${maxJobs}`);
  }
  if (useCache !== "true" && useCache !== "false") {
    throw new Error(
      `USE_CACHE must be 'true' or 'false', got ${useCache}`,
    );
  }
  if (ckFmhaDisableBwd !== "1" && ckFmhaDisableBwd !== "0") {
    throw new Error(
      `CK_FMHA_DISABLE_BWD must be '1' or '0', got ${ckFmhaDisableBwd}`,
    );
  }
  return {
    ninja_workers: ninjaWorkers,
    use_cache: useCache === "true",
    ck_disable_bwd: ckFmhaDisableBwd === "1",
  };
}

export function runVerify(options: {
  distDir: string;
  buildVariant: string;
  buildCaches: string;
}): void {
  const expectedWheelPattern = requireLockEnv("EXPECTED_WHEEL_PATTERN");
  const ckOptDim = requireLockEnv("CK_OPT_DIM");
  const ckFmhaDisableBwd = requireGithubActionsEnv("CK_FMHA_DISABLE_BWD");
  const flashAttentionBuildCommit = requireLockEnv("FLASH_ATTENTION_BUILD_COMMIT");
  const wheelLocalVersion = requireLockEnv("WHEEL_LOCAL_VERSION");
  const pytorchVersion = requireLockEnv("PYTORCH_VERSION");
  const rocmVersion = requireLockEnv("ROCM_VERSION");
  const pythonVersion = requireLockEnv("PYTHON_VERSION");
  const gpuArchs = requireLockEnv("GPU_ARCHS");
  const sourceDateEpoch = requireLockEnv("SOURCE_DATE_EPOCH");
  const githubRunId = requireGithubActionsEnv("GITHUB_RUN_ID");
  const githubRunNumber = requireGithubActionsEnv("GITHUB_RUN_NUMBER");
  const githubSha = requireGithubActionsEnv("GITHUB_SHA");
  const distDir = path.resolve(options.distDir);

  const buildVariant = options.buildVariant.trim().toLowerCase();
  if (buildVariant !== "serial" && buildVariant !== "parallel") {
    throw new Error(
      `--build-variant must be 'serial' or 'parallel', got ${options.buildVariant}`,
    );
  }

  const buildCachesPath = options.buildCaches?.trim();
  if (!buildCachesPath) {
    throw new Error("--build-caches is required");
  }

  const buildCaches = validateBuildCachesForVariant({
    buildCaches: readBuildCaches(buildCachesPath),
    buildVariant,
    ckOptDim,
  });

  const whls = readdirSync(distDir)
    .filter((name) => name.endsWith(".whl"))
    .map((name) => path.join(distDir, name));

  if (whls.length !== 1) {
    throw new Error(
      `Expected exactly one wheel in ${distDir}, found ${whls.length}`,
    );
  }

  const whlPath = whls[0]!;
  const whlName = path.basename(whlPath);
  if (!matchesGlob(whlName, expectedWheelPattern)) {
    throw new Error(
      `Wheel name '${whlName}' does not match expected pattern '${expectedWheelPattern}'`,
    );
  }

  console.log(`Wheel name OK: ${whlName}`);

  const sha256Hex = createHash("sha256")
    .update(readFileSync(whlPath))
    .digest("hex")
    .toLowerCase();
  const checksumPath = path.join(distDir, `${whlName}.sha256`);
  writeFileSync(checksumPath, `${sha256Hex}  ${whlName}\n`, "ascii");

  console.log("=== Wheel structure (pre-install) ===");
  run(PYTHON, [
    "-c",
    WHEEL_INSPECT_CODE,
    whlPath,
    ckOptDim,
    wheelLocalVersion,
  ]);

  const whlStat = statSync(whlPath);
  const manifest = {
    wheel: whlName,
    sha256: sha256Hex,
    size_bytes: whlStat.size,
    flash_attention_build_commit: flashAttentionBuildCommit,
    flash_attention_build_commit_date: requireLockEnv(
      "FLASH_ATTENTION_BUILD_COMMIT_DATE",
    ),
    python: pythonVersion,
    pytorch: pytorchVersion,
    rocm: rocmVersion,
    gpu_archs: gpuArchs,
    ck_opt_dim: ckOptDim,
    fmha_bwd: ckFmhaDisableBwd === "0",
    wheel_local_version: wheelLocalVersion,
    source_date_epoch: Number(sourceDateEpoch),
    build_variant: buildVariant,
    dispatch: readWorkflowDispatch(),
    build_caches: buildCaches,
    build_github_run_id: githubRunId,
    build_github_run_number: githubRunNumber,
    build_repository_commit: githubSha,
  };

  console.log(`Wheel SHA256: ${sha256Hex}`);
  console.log(`Checksum file: ${checksumPath}`);

  run(PYTHON, ["-m", "pip", "install", "--force-reinstall", "--no-deps", whlPath]);

  console.log("=== torch runtime ===");
  run(PYTHON, [
    "-c",
    [
      "import sys",
      "import torch",
      "expected_pytorch = sys.argv[1]",
      "expected_rocm = sys.argv[2]",
      "if not torch._C._GLIBCXX_USE_CXX11_ABI:",
      "    raise SystemExit('ERROR: _GLIBCXX_USE_CXX11_ABI is False; wheel requires cxx11.abi local tag')",
      "if torch.__version__ != expected_pytorch:",
      "    raise SystemExit(f'ERROR: torch version mismatch: {torch.__version__!r} != {expected_pytorch!r}')",
      "if torch.version.rocm != expected_rocm:",
      "    raise SystemExit(f'ERROR: rocm version mismatch: {torch.version.rocm!r} != {expected_rocm!r}')",
      "print('OK torch', torch.__version__)",
      "print('OK rocm', torch.version.rocm)",
      "print('OK CXX11_ABI', torch._C._GLIBCXX_USE_CXX11_ABI)",
    ].join("\n"),
    pytorchVersion,
    rocmVersion,
  ]);

  console.log("=== flash_attn extension ===");
  run(PYTHON, [
    "-c",
    [
      "import importlib.metadata",
      "import importlib.util",
      "import sys",
      "import flash_attn",
      "import flash_attn_2_cuda",
      "from flash_attn import flash_attn_func",
      "def wheel_filename_local(local: str) -> str:",
      "    return local.replace('-', '.').replace('_', '.')",
      "spec = importlib.util.find_spec('flash_attn_2_cuda')",
      "if spec is None or not spec.origin:",
      "    raise SystemExit('ERROR: flash_attn_2_cuda spec/origin missing')",
      "public = [name for name in dir(flash_attn_2_cuda) if not name.startswith('_')]",
      "if len(public) < 1:",
      "    raise SystemExit('ERROR: flash_attn_2_cuda has no public symbols')",
      "installed_version = importlib.metadata.version('flash_attn')",
      "expected_local = sys.argv[1]",
      "if not installed_version:",
      "    raise SystemExit('ERROR: flash_attn package version is empty')",
      "filename_local = wheel_filename_local(expected_local)",
      "local_tag = f'+{filename_local}'",
      "if local_tag not in installed_version:",
      "    raise SystemExit(",
      "        'ERROR: flash_attn metadata missing local version tag '",
      "        f'{local_tag!r}: {installed_version!r}'",
      "    )",
      "if not installed_version.startswith(f'{flash_attn.__version__}+'):",
      "    raise SystemExit(",
      "        'ERROR: flash_attn metadata base version mismatch: '",
      "        f'metadata={installed_version!r} module={flash_attn.__version__!r}'",
      "    )",
      "print('OK flash_attn', flash_attn.__file__)",
      "print('OK flash_attn metadata version', installed_version)",
      "print('OK flash_attn module __version__', flash_attn.__version__)",
      "print('OK flash_attn_2_cuda', spec.origin)",
      "print('symbol_count', len(public))",
      "print('OK flash_attn_func', flash_attn_func)",
    ].join("\n"),
    wheelLocalVersion,
  ]);

  const manifestPath = path.join(distDir, "wheel.manifest.json");
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`Manifest file: ${manifestPath}`);
  console.log("Smoke test complete");
}
