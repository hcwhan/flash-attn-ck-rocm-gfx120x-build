import { createHash } from "node:crypto";
import {
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { run } from "../lib/exec.js";
import { requireLockEnv } from "../lib/require-env.js";

const PYTHON = "python";

const WHEEL_INSPECT_CODE = `
import sys, zipfile
wheel = sys.argv[1]
opt_dims = [int(x) for x in sys.argv[2].split(',') if x]
min_pyd_bytes = 1024 * 1024
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
        data = zf.read(name)
        missing = [tok for tok in [f'_d{d}_' for d in opt_dims] if tok.encode('ascii') not in data]
        if missing:
            raise SystemExit(f'ERROR: {name} missing OPT_DIM kernels {missing}')
        dims_str = ','.join(str(d) for d in opt_dims)
        print(f'OK {name} size={info.file_size} dims={dims_str}')
    meta = [name for name in names if name.endswith('.dist-info/METADATA')]
    if not meta:
        raise SystemExit('ERROR: METADATA not found in wheel archive')
    meta_text = zf.read(meta[0]).decode('utf-8', errors='replace')
    if 'Requires-Dist: torch' not in meta_text:
        raise SystemExit('ERROR: wheel METADATA missing Requires-Dist: torch')
    print('OK METADATA Requires-Dist: torch')
`.trim();

function matchesGlob(name: string, pattern: string): boolean {
  const regex = new RegExp(
    `^${pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`,
    "i",
  );
  return regex.test(name);
}

export function runVerify(options: { distDir: string }): void {
  const expectedWheelPattern = requireLockEnv("EXPECTED_WHEEL_PATTERN");
  const lockOptDim = requireLockEnv("LockOptDim");
  const flashAttentionBuildCommit = requireLockEnv("FLASH_ATTENTION_BUILD_COMMIT");
  const pytorchVersion = requireLockEnv("PYTORCH_VERSION");
  const pythonVersion = requireLockEnv("PYTHON_VERSION");
  const gpuArchs = requireLockEnv("GPU_ARCHS");
  const distDir = path.resolve(options.distDir);

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
  run(PYTHON, ["-c", WHEEL_INSPECT_CODE, whlPath, lockOptDim]);

  const whlStat = statSync(whlPath);
  const manifest = {
    wheel: whlName,
    sha256: sha256Hex,
    size_bytes: whlStat.size,
    flash_attention_build_commit: flashAttentionBuildCommit,
    pytorch: pytorchVersion,
    python: pythonVersion,
    gpu_archs: gpuArchs,
    opt_dim: lockOptDim,
  };

  console.log(`Wheel SHA256: ${sha256Hex}`);
  console.log(`Checksum file: ${checksumPath}`);

  run(PYTHON, ["-m", "pip", "install", "--force-reinstall", "--no-deps", whlPath]);

  console.log("=== torch runtime ===");
  run(PYTHON, [
    "-c",
    [
      "import torch",
      "if not torch._C._GLIBCXX_USE_CXX11_ABI:",
      "    raise SystemExit('ERROR: _GLIBCXX_USE_CXX11_ABI is False; wheel requires cxx11abiTRUE')",
      "print('torch', torch.__version__)",
      "print('hip', torch.version.hip)",
      "print('CXX11_ABI', torch._C._GLIBCXX_USE_CXX11_ABI)",
    ].join("\n"),
  ]);

  console.log("=== flash_attn extension ===");
  run(PYTHON, [
    "-c",
    [
      "import importlib.util",
      "import flash_attn",
      "import flash_attn_2_cuda",
      "from flash_attn import flash_attn_func",
      "spec = importlib.util.find_spec('flash_attn_2_cuda')",
      "if spec is None or not spec.origin:",
      "    raise SystemExit('ERROR: flash_attn_2_cuda spec/origin missing')",
      "public = [name for name in dir(flash_attn_2_cuda) if not name.startswith('_')]",
      "if len(public) < 1:",
      "    raise SystemExit('ERROR: flash_attn_2_cuda has no public symbols')",
      "print('OK flash_attn', flash_attn.__file__)",
      "print('OK flash_attn_2_cuda', spec.origin)",
      "print('symbol_count', len(public))",
      "print('OK flash_attn_func', flash_attn_func)",
    ].join("\n"),
  ]);

  const manifestPath = path.join(distDir, "wheel.manifest.json");
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`Manifest file: ${manifestPath}`);
  console.log("Smoke test complete");
}
