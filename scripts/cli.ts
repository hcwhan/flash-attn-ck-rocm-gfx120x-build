#!/usr/bin/env node
import { Command } from "commander";
import { runConfig } from "./commands/01.config.js";
import { runPlanOptDimMatrix } from "./commands/02.plan-opt-dim-matrix.js";
import { runCompile } from "./commands/06.compile.js";
import { runPatch } from "./commands/04.patch.js";
import { runPrep } from "./commands/03.prep.js";
import { runPublish } from "./commands/10.publish.js";
import { runShard } from "./commands/07.shard.js";
import { runToolchainFingerprint } from "./commands/05.toolchain-fingerprint.js";
import { runVerify } from "./commands/09.verify.js";
import { runWheel } from "./commands/08.wheel.js";

const program = new Command();

program.name("fa-build").description("FlashAttention gfx1201 build CLI");

program
  .command("01.config")
  .description("Read VERSION.lock.json")
  .requiredOption("-w, --workspace-root <path>")
  .option("--export-github-env", "Append lock vars to GITHUB_ENV")
  .action((opts) => {
    runConfig({
      workspaceRoot: opts.workspaceRoot,
      exportGithubEnv: Boolean(opts.exportGithubEnv),
    });
  });

program
  .command("02.plan-opt-dim-matrix")
  .description("Export OPT_DIM matrix outputs for parallel compile")
  .action(() => {
    runPlanOptDimMatrix();
  });

program
  .command("03.prep")
  .description("Clone flash-attention at pinned commit")
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runPrep({ faSrc: opts.faSrc });
  });

program
  .command("04.patch")
  .description("Patch flash-attention for inference-only CK build")
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runPatch({ faSrc: opts.faSrc });
  });

program
  .command("05.toolchain-fingerprint")
  .description("Emit MSVC/clang and pip toolchain cache fingerprints")
  .option("--build-variant <mode>", "serial or parallel (emit cache-key output)")
  .option("--opt-dim <value>", "OPT_DIM shard when --build-variant parallel")
  .action((opts) => {
    runToolchainFingerprint({
      buildVariant: opts.buildVariant,
      optDim: opts.optDim,
    });
  });

program
  .command("06.compile")
  .description("Compile one OPT_DIM shard or full lock opt_dim")
  .requiredOption("--opt-dim <value>")
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runCompile({
      optDim: opts.optDim,
      faSrc: opts.faSrc,
    });
  });

program
  .command("07.shard")
  .description("Validate compile shard and emit SHARD_RELEASE_DIR to GITHUB_ENV")
  .requiredOption("--fa-src <path>")
  .requiredOption("--opt-dim <value>")
  .action((opts) => {
    runShard({
      faSrc: opts.faSrc,
      optDim: opts.optDim,
    });
  });

program
  .command("08.wheel")
  .description("Link and package wheel")
  .requiredOption("--fa-src <path>")
  .requiredOption("--dist-dir <path>")
  .option("--staging-root <path>")
  .option("--primary-dim <value>")
  .action((opts) => {
    runWheel({
      faSrc: opts.faSrc,
      distDir: opts.distDir,
      stagingRoot: opts.stagingRoot,
      primaryDim: opts.primaryDim,
    });
  });

program
  .command("09.verify")
  .description("CPU wheel smoke test")
  .requiredOption("--dist-dir <path>")
  .requiredOption("--build-variant <name>", "serial or parallel")
  .option("--cache-key <key>", "compile cache key (required for serial)")
  .action((opts) => {
    runVerify({
      distDir: opts.distDir,
      buildVariant: opts.buildVariant,
      cacheKey: opts.cacheKey,
    });
  });

program
  .command("10.publish")
  .description("Prepare GitHub Release metadata")
  .requiredOption("--dist-dir <path>")
  .requiredOption("--workflow-name <name>")
  .requiredOption("--build-variant <name>")
  .action((opts) => {
    runPublish({
      distDir: opts.distDir,
      workflowName: opts.workflowName,
      buildVariant: opts.buildVariant,
    });
  });

program.parseAsync(process.argv).catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exit(1);
});
