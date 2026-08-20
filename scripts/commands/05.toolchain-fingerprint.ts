import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { runCapture } from "../lib/exec.js";
import { appendGithubOutput } from "../lib/github.js";
import { buildNinjaCacheFamilyKey, buildNinjaCacheKey } from "../lib/ninja-cache-key.js";
import {
  parseRocmClangFullVersion,
  resolveNinjaMinorVersion,
} from "../lib/build-tool-minor.js";
import { getRocmSdkPaths } from "../lib/rocm-sdk-paths.js";
import { requireGithubActionsEnv } from "../lib/require-env.js";
import { versionLockFileHash8 } from "../lib/version-lock.js";

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

function resolveRocmClangVersionLine(coreRoot: string): string {
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

export function runToolchainFingerprint(options?: {
  workspaceRoot?: string;
  buildVariant?: string;
  optDim?: string;
}): void {
  const msvcVersion = resolveMsvcToolset();
  const { coreRoot } = getRocmSdkPaths();
  const rocmClangLine = resolveRocmClangVersionLine(coreRoot);
  const rocmClangVersion = parseRocmClangFullVersion(rocmClangLine);

  console.log(`MSVC toolset (cache key): ${msvcVersion}`);
  console.log(`ROCm clang: ${rocmClangLine}`);
  console.log(`ROCm clang (cache key): ${rocmClangVersion}`);

  const ninjaMinor = resolveNinjaMinorVersion();
  console.log(`ninja minor (cache key): ${ninjaMinor}`);

  if (options?.buildVariant) {
    const buildVariant = options.buildVariant.trim().toLowerCase();
    if (buildVariant !== "serial" && buildVariant !== "parallel") {
      throw new Error(
        `--build-variant must be 'serial' or 'parallel', got ${options.buildVariant}`,
      );
    }

    if (buildVariant === "parallel" && !options.optDim?.trim()) {
      throw new Error("--opt-dim is required when --build-variant parallel");
    }

    const workspaceRoot = options.workspaceRoot?.trim();
    if (!workspaceRoot) {
      throw new Error(
        "--workspace-root is required when --build-variant is set",
      );
    }

    const lockHash = versionLockFileHash8(workspaceRoot);
    console.log(
      `VERSION.lock compile fingerprint (toolchain+flash_attention+compile): ${lockHash}`,
    );

    const ckDisableBwd = requireGithubActionsEnv("CK_DISABLE_BWD");
    if (ckDisableBwd !== "true" && ckDisableBwd !== "false") {
      throw new Error(
        `CK_DISABLE_BWD must be 'true' or 'false', got ${ckDisableBwd}`,
      );
    }
    const fmhaBwd = ckDisableBwd === "false";
    console.log(`fmha_bwd (cache key): ${fmhaBwd}`);

    const cacheKeyOptions = {
      buildVariant: buildVariant as "serial" | "parallel",
      lockHash,
      fmhaBwd,
      optDim: options.optDim?.trim(),
      msvcVersion,
      rocmClangVersion,
      ninjaMinor,
    };
    const cacheFamilyKey = buildNinjaCacheFamilyKey(cacheKeyOptions);
    const cacheKey = buildNinjaCacheKey(cacheKeyOptions);
    console.log(`Ninja cache family-key: ${cacheFamilyKey}`);
    console.log(`Ninja cache key: ${cacheKey}`);
    appendGithubOutput({
      "cache-family-key": cacheFamilyKey,
      "cache-key": cacheKey,
    });
    return;
  }

  console.log("Toolchain fingerprint complete (cache-key not requested)");
}
