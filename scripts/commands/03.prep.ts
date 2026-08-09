import { rmSync, mkdirSync } from "node:fs";
import path from "node:path";
import { run, runCapture } from "../lib/exec.js";
import { requireLockEnv } from "../lib/require-env.js";

export function runPrep(options: { faSrc: string }): void {
  const flashAttentionRepo = requireLockEnv("FLASH_ATTENTION_REPO");
  const flashAttentionBuildCommit = requireLockEnv("FLASH_ATTENTION_BUILD_COMMIT");
  const flashAttentionBuildCommitDate = requireLockEnv(
    "FLASH_ATTENTION_BUILD_COMMIT_DATE",
  );
  const root = path.resolve(options.faSrc);

  console.log(`Using flash-attention repo: ${flashAttentionRepo}`);
  console.log(
    `Using flash-attention build commit: ${flashAttentionBuildCommit}`,
  );

  const parent = path.dirname(root);
  mkdirSync(parent, { recursive: true });
  rmSync(root, { recursive: true, force: true });

  console.log(
    `Cloning flash-attention at commit ${flashAttentionBuildCommit}`,
  );
  run("git", [
    "-c",
    "core.longpaths=true",
    "clone",
    "--filter=blob:none",
    "--no-checkout",
    flashAttentionRepo,
    root,
  ]);
  run(
    "git",
    [
      "-c",
      "core.longpaths=true",
      "-C",
      root,
      "fetch",
      "--depth",
      "1",
      "origin",
      flashAttentionBuildCommit,
    ],
  );
  run("git", ["-C", root, "checkout", "FETCH_HEAD"]);
  run("git", [
    "-C",
    root,
    "submodule",
    "update",
    "--init",
    "--depth",
    "1",
    "csrc/composable_kernel",
    "csrc/cutlass",
  ]);

  const gitAuthorDate = runCapture("git", [
    "-C",
    root,
    "log",
    "-1",
    "--format=%aI",
  ]).trim();
  if (!gitAuthorDate) {
    throw new Error(
      `prep: failed to read author date for commit ${flashAttentionBuildCommit}`,
    );
  }

  const gitAuthorMs = Date.parse(gitAuthorDate);
  const lockCommitMs = Date.parse(flashAttentionBuildCommitDate);
  if (Number.isNaN(gitAuthorMs) || Number.isNaN(lockCommitMs)) {
    throw new Error(
      `prep: failed to parse commit author date '${gitAuthorDate}' or lock date '${flashAttentionBuildCommitDate}'`,
    );
  }
  if (gitAuthorMs !== lockCommitMs) {
    throw new Error(
      [
        `flash_attention_build_commit_date mismatch for commit ${flashAttentionBuildCommit}.`,
        ` lock=${flashAttentionBuildCommitDate} git author=${gitAuthorDate}`,
        " Update VERSION.lock.json when bumping flash_attention_build_commit.",
      ].join(""),
    );
  }

  console.log(
    `Commit author date OK: ${gitAuthorDate} (lock=${flashAttentionBuildCommitDate})`,
  );

  rmSync(path.join(root, ".git"), { recursive: true, force: true });

  console.log(
    `Prepared flash-attention at ${root} (commit=${flashAttentionBuildCommit})`,
  );
}
