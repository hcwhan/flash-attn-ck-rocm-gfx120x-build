import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { requireGithubActionsEnv } from "../lib/require-env.js";

type StringPatchPoint = {
  name: string;
  before: string;
  after: string;
  regex: false;
};

type RegexPatchPoint = {
  name: string;
  before: RegExp;
  after: string;
  regex: true;
};

type PatchPoint = StringPatchPoint | RegexPatchPoint;

const bwdPatchPoints: PatchPoint[] = [
  {
    name: "generate-loop-skip-bwd",
    before:
      'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv", "bwd"]:',
    after: 'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv"]:',
    regex: false,
  },
  {
    name: "enable-disable-backward-flag",
    before:
      /(-DUSE_PROF_API=1",\r?\n\s*)# "-DFLASHATTENTION_DISABLE_BACKWARD",/,
    after: '$1"-DFLASHATTENTION_DISABLE_BACKWARD",',
    regex: true,
  },
];

const breproPatchPoint: StringPatchPoint = {
  name: "link-spawn-brepro",
  before: `                cmd = [str(arg) for arg in cmd]
                if len(subprocess.list2cmdline(cmd)) <= 32767:`,
  after: `                cmd = [str(arg) for arg in cmd]
                if "/Brepro" not in cmd and "-Brepro" not in cmd:
                    cmd.append("/Brepro")
                if len(subprocess.list2cmdline(cmd)) <= 32767:`,
  regex: false,
};

function readNormalized(filePath: string): { content: string; eol: "\n" | "\r\n" } {
  const raw = readFileSync(filePath, "utf8");
  const eol: "\n" | "\r\n" = raw.includes("\r\n") ? "\r\n" : "\n";
  return { content: raw.replace(/\r\n/g, "\n"), eol };
}

function writeNormalized(
  filePath: string,
  content: string,
  eol: "\n" | "\r\n",
): void {
  const out = eol === "\r\n" ? content.replace(/\n/g, "\r\n") : content;
  writeFileSync(filePath, out, "utf8");
}

function spawnBreproAlreadyPatched(content: string): boolean {
  return (
    content.includes('if "/Brepro" not in cmd and "-Brepro" not in cmd:') &&
    content.includes('cmd.append("/Brepro")')
  );
}

function applyPatchPoint(content: string, point: PatchPoint): string {
  if (point.name === "link-spawn-brepro" && spawnBreproAlreadyPatched(content)) {
    return content;
  }
  return point.regex
    ? content.replace(point.before, point.after)
    : content.replace(point.before, point.after);
}

function validatePatchPoint(content: string, point: PatchPoint): void {
  if (point.name === "link-spawn-brepro" && spawnBreproAlreadyPatched(content)) {
    console.log(`  OK ${point.name}: already patched`);
    return;
  }
  const matched = point.regex
    ? point.before.test(content)
    : content.includes(point.before);
  if (!matched) {
    throw new Error(`patch: before-state not found for '${point.name}'`);
  }
  console.log(`  OK ${point.name}: before-state found`);
}

export function runPatch(options: { faSrc: string }): void {
  const disableBwd = requireGithubActionsEnv("CK_FMHA_DISABLE_BWD") === "1";
  const patchPoints: PatchPoint[] = disableBwd
    ? [...bwdPatchPoints, breproPatchPoint]
    : [breproPatchPoint];

  const setup = path.join(path.resolve(options.faSrc), "setup.py");
  let content: string;
  let setupEol: "\n" | "\r\n";
  try {
    ({ content, eol: setupEol } = readNormalized(setup));
  } catch {
    throw new Error(`setup.py not found: ${setup}`);
  }

  for (const point of patchPoints) {
    validatePatchPoint(content, point);
  }

  for (const point of patchPoints) {
    const next = applyPatchPoint(content, point);
    if (next !== content) {
      content = next;
      console.log(`  OK ${point.name}: patched`);
    }
  }

  writeNormalized(setup, content, setupEol);
  console.log(
    `Patched ${setup} (CK_FMHA_DISABLE_BWD=${disableBwd ? "1" : "0"})`,
  );

  if (!disableBwd) {
    return;
  }

  const ckSrcDir = path.join(
    path.resolve(options.faSrc),
    "csrc",
    "flash_attn_ck",
  );
  for (const bwdFile of ["mha_bwd.cpp", "mha_varlen_bwd.cpp"] as const) {
    const bwdPath = path.join(ckSrcDir, bwdFile);
    let bwdContent: string;
    try {
      bwdContent = readFileSync(bwdPath, "utf8");
    } catch {
      throw new Error(
        `patch: before-state not found: ${bwdFile} missing at ${bwdPath}`,
      );
    }
    const guardIdx = bwdContent.indexOf("TORCH_CHECK(false");
    const launcherIdx = bwdContent.indexOf("fmha_bwd_launcher launcher(");
    if (guardIdx < 0 || launcherIdx < 0 || guardIdx > launcherIdx) {
      throw new Error(
        `patch: before-state not found for '${bwdFile}' (TORCH_CHECK(false) guard must precede fmha_bwd_launcher construction)`,
      );
    }
    console.log(`  OK ${bwdFile}: backward guard precedes launcher`);
  }
}
