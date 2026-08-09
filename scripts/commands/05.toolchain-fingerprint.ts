import { createHash } from "node:crypto";
import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { runCapture } from "../lib/exec.js";
import { appendGithubOutput } from "../lib/github.js";
import { getRocmSdkPaths } from "../lib/rocm-sdk-paths.js";

const PYTHON = "python";

function resolveMsvcToolset(): string {
  const programFilesX86 = process.env["ProgramFiles(x86)"];
  if (!programFilesX86) {
    return "unknown";
  }

  const vswhere = path.join(
    programFilesX86,
    "Microsoft Visual Studio",
    "Installer",
    "vswhere.exe",
  );
  if (!existsSync(vswhere)) {
    return "unknown";
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
    return "unknown";
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

  return toolsets[0] ?? "unknown";
}

function fingerprintHash(payload: string): string {
  return createHash("sha256").update(payload, "utf8").digest("hex").slice(0, 12);
}

export function runToolchainFingerprint(): void {
  const toolset = resolveMsvcToolset();

  const { coreRoot } = getRocmSdkPaths();
  const clangExe = path.join(coreRoot, "lib", "llvm", "bin", "clang.exe");
  let clangVersion = "unknown";
  if (existsSync(clangExe)) {
    try {
      clangVersion = runCapture(clangExe, ["--version"])
        .split(/\r?\n/)[0]
        ?.trim() ?? "unknown";
    } catch {
      clangVersion = "unknown";
    }
  }

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

  appendGithubOutput({
    "msvc-hash": msvcHash,
    "pip-hash": pipHash,
  });
}
