import { runCapture } from "./exec.js";

const PYTHON = "python";

const PY_DISCOVER = `
import importlib.util, os, subprocess, sys

spec = importlib.util.find_spec('_rocm_sdk_core')
if spec is None:
    raise SystemExit('ERROR: _rocm_sdk_core not found. Install torch[device-...] first.')
core_root = os.path.dirname(spec.origin)

proc = subprocess.run(
    [sys.executable, '-m', 'rocm_sdk', 'path', '--root'],
    capture_output=True,
    text=True,
    check=True,
)
devel_root = proc.stdout.strip()

print(f'CORE_ROOT={core_root}')
print(f'DEVEL_ROOT={devel_root}')
`.trim();

type RocmSdkPaths = {
  coreRoot: string;
  develRoot: string;
};

export function getRocmSdkPaths(): RocmSdkPaths {
  const output = runCapture(PYTHON, ["-c", PY_DISCOVER]);
  const coreRootLine = output
    .split(/\r?\n/)
    .find((line) => line.startsWith("CORE_ROOT="));
  const develRootLine = output
    .split(/\r?\n/)
    .find((line) => line.startsWith("DEVEL_ROOT="));

  if (!coreRootLine || !develRootLine) {
    throw new Error(`Failed to parse ROCm SDK paths from ${PYTHON} output`);
  }

  return {
    coreRoot: coreRootLine.slice("CORE_ROOT=".length),
    develRoot: develRootLine.slice("DEVEL_ROOT=".length),
  };
}
