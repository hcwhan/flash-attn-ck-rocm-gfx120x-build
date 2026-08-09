import { createHash } from "node:crypto";
import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { runCapture } from "../lib/exec.js";
import { appendGithubOutput } from "../lib/github.js";
import { buildNinjaCacheKey } from "../lib/ninja-cache-key.js";
import { getRocmSdkPaths } from "../lib/rocm-sdk-paths.js";

const PYTHON = "python";

function resolveMsvcToolset(): string {
  const programFilesX86 = process.env["ProgramFiles(x86)"];
  if (!programFilesX86) {
    throw new Error(
      "ProgramFiles(x86) env is not set; cannot locate MSVC toolset",
    );
  }

  const vswhere = path.join(
    programFilesX86,
    "Microsoft Visual Studio",
    "Installer",
    "vswhere.exe",
  );
  if (!existsSync(vswhere)) {
    throw new Error(`vswhere.exe not found: ${vswhere}`);
  }

  const vcRoot = runCapture(vswhere, [
    "-latest",
    "-products",
    "*",
    "-requires",
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "-property",
    "installationPath",
  ]).trim();

  const toolsDir = path.join(vcRoot, "VC", "Tools", "MSVC");
  if (!vcRoot || !existsSync(toolsDir)) {
    throw new Error(
      `MSVC tools directory not found under ${vcRoot || "(empty vcRoot)"}`,
    );
  }

  const toolsets = readdirSync(toolsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((a, b) => {
      const parse = (value: string) => {
        const parts = value.split(".").map(Number);
        return parts[0]! * 1_000_000 + (parts[1] ?? 0) * 1_000 + (parts[2] ?? 0);
      };
      try {
        return parse(b) - parse(a);
      } catch {
        return 0;
      }
    });

  const toolset = toolsets[0];
  if (!toolset) {
    throw new Error(`No MSVC toolset directories under ${toolsDir}`);
  }

  return toolset;
}

function resolveClangVersion(coreRoot: string): string {
  const clangExe = path.join(coreRoot, "lib", "llvm", "bin", "clang.exe");
  if (!existsSync(clangExe)) {
    throw new Error(`ROCm clang not found: ${clangExe}`);
  }

  const firstLine = runCapture(clangExe, ["--version"])
    .split(/\r?\n/)[0]
    ?.trim();
  if (!firstLine) {
    throw new Error(`ROCm clang --version returned no output from ${clangExe}`);
  }

  return firstLine;
}

function fingerprintHash(payload: string): string {
  return createHash("sha256").update(payload, "utf8").digest("hex").slice(0, 12);
}

export function runToolchainFingerprint(options?: {
  cacheVariant?: string;
  optDim?: string;
}): void {
  const toolset = resolveMsvcToolset();
  const { coreRoot } = getRocmSdkPaths();
  const clangVersion = resolveClangVersion(coreRoot);

  const msvcHash = fingerprintHash(`${toolset}|${clangVersion}`);
  console.log(
    `MSVC toolset: ${toolset} | clang: ${clangVersion} (cache fingerprint ${msvcHash})`,
  );

  const pipPkgs = ["pip", "setuptools", "wheel", "ninja", "packaging", "psutil"];
  const pipFreeze = runCapture(PYTHON, ["-m", "pip", "list", "--format=freeze"]);
  const pipVersions = pipPkgs.map((pkg) => {
    const line = pipFreeze
      .split(/\r?\n/)
      .find((entry) => entry.startsWith(`${pkg}==`));
    if (!line) {
      throw new Error(`pip toolchain package not found: ${pkg}`);
    }
    return line;
  });

  const pipHash = fingerprintHash(pipVersions.sort().join(";"));
  console.log(
    `pip toolchain: ${pipVersions.join(";")} (fingerprint ${pipHash})`,
  );

  const outputs: Record<string, string> = {
    "toolchain-msvc-hash": msvcHash,
    "toolchain-pip-hash": pipHash,
  };

  if (options?.cacheVariant) {
    const variant = options.cacheVariant.trim().toLowerCase();
    if (variant !== "serial" && variant !== "parallel") {
      throw new Error(
        `--cache-variant must be 'serial' or 'parallel', got ${options.cacheVariant}`,
      );
    }

    if (variant === "parallel" && !options.optDim?.trim()) {
      throw new Error("--opt-dim is required when --cache-variant parallel");
    }

    const cacheKey = buildNinjaCacheKey({
      variant,
      optDim: options.optDim?.trim(),
      msvcHash,
      pipHash,
    });
    outputs["cache-key"] = cacheKey;
    console.log(`Ninja cache key: ${cacheKey}`);
  }

  appendGithubOutput(outputs);
}
