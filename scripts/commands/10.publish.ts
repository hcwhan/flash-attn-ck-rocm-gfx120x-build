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
  releaseVariant: string;
}): void {
  const releaseTagPrefix = requireLockEnv("RELEASE_TAG_PREFIX");
  const releaseName = requireLockEnv("RELEASE_NAME");
  const releasePrerelease = requireLockEnv("RELEASE_PRERELEASE");
  const runNumber = requireGithubActionsEnv("GITHUB_RUN_NUMBER");
  const runnerTemp = requireGithubActionsEnv("RUNNER_TEMP");
  const githubSha = requireGithubActionsEnv("GITHUB_SHA");

  const variantSlug = options.releaseVariant
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!variantSlug) {
    throw new Error(
      `ReleaseVariant '${options.releaseVariant}' did not produce a valid slug`,
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
  const tag = `${releaseTagPrefix}-${variantSlug}-build${runNumber}`;
  const displayName = `${releaseName} (${options.releaseVariant})`;
  const releaseTitle = `${displayName} (build ${runNumber})`;
  const bodyPath = path.join(runnerTemp, "release-body.md");

  const manifestPath = path.join(distDir, "wheel.manifest.json");
  const manifestJson = readFileSync(manifestPath, "utf8").trimEnd();
  const manifestBlock = `\n\n### wheel.manifest.json\n\n\`\`\`json\n${manifestJson}\n\`\`\`\n`;

  const body = [
    `## ${releaseName}`,
    "",
    "| 项 | 值 |",
    "|----|-----|",
    `| Workflow | ${options.workflowName} |`,
    `| Build source | ${options.releaseVariant} |`,
    `| Run | ${runNumber} |`,
    `| Repository commit | ${githubSha} |`,
    `| Wheel | ${whlName} |`,
    manifestBlock,
  ].join("\n");

  writeFileSync(bodyPath, body, "utf8");

  appendGithubOutput({
    tag,
    body_path: bodyPath,
    prerelease: releasePrerelease,
    release_title: releaseTitle,
  });

  console.log(`Release tag: ${tag}`);
  console.log(`Release body: ${bodyPath}`);
}
