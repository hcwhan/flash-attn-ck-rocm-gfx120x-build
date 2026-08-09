import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { appendGithubOutput } from "../lib/github.js";
import {
  requireGithubActionsEnv,
  requireLockEnv,
} from "../lib/require-env.js";

export function runPublish(options: {
  distDir: string;
  workflowName: string;
  buildVariant: string;
}): void {
  const releaseTagPrefix = requireLockEnv("RELEASE_TAG_PREFIX");
  const releaseTitlePrefix = requireLockEnv("RELEASE_TITLE_PREFIX");
  const runNumber = requireGithubActionsEnv("GITHUB_RUN_NUMBER");
  const runnerTemp = requireGithubActionsEnv("RUNNER_TEMP");
  const githubSha = requireGithubActionsEnv("GITHUB_SHA");

  const variantSlug = options.buildVariant
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!variantSlug) {
    throw new Error(
      `buildVariant '${options.buildVariant}' did not produce a valid slug`,
    );
  }

  const distDir = path.resolve(options.distDir);
  const whls = readdirSync(distDir)
    .filter((name) => name.endsWith(".whl"))
    .map((name) => path.join(distDir, name));

  if (whls.length !== 1) {
    throw new Error(
      `Expected exactly one wheel in ${distDir} for release, found ${whls.length}`,
    );
  }

  const whlName = path.basename(whls[0]!);
  const releaseTag = `${releaseTagPrefix}-${variantSlug}-build${runNumber}`;
  const displayName = `${releaseTitlePrefix} (${options.buildVariant})`;
  const releaseTitle = `${displayName} (build ${runNumber})`;
  const bodyPath = path.join(runnerTemp, "release-body.md");

  const manifestPath = path.join(distDir, "wheel.manifest.json");
  const manifestJson = readFileSync(manifestPath, "utf8").trimEnd();
  const manifestBlock = `\n\n### wheel.manifest.json\n\n\`\`\`json\n${manifestJson}\n\`\`\`\n`;

  const body = [
    `## ${releaseTitlePrefix}`,
    "",
    "| Field | Value |",
    "|-------|-------|",
    `| Workflow | ${options.workflowName} |`,
    `| Build variant | ${options.buildVariant} |`,
    `| Run | ${runNumber} |`,
    `| Repository commit | ${githubSha} |`,
    `| Wheel | ${whlName} |`,
    manifestBlock,
  ].join("\n");

  writeFileSync(bodyPath, body, "utf8");

  appendGithubOutput({
    "release-tag": releaseTag,
    "body-path": bodyPath,
    "release-title": releaseTitle,
  });

  console.log(`Release tag: ${releaseTag}`);
  console.log(`Release body: ${bodyPath}`);
}
