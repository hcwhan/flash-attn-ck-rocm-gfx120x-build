#!/usr/bin/env node
import { Command } from "commander";
import { runConfig } from "./commands/01.config.js";
import { runPlanOptDimMatrix } from "./commands/02.plan-opt-dim-matrix.js";
import { runPrep } from "./commands/03.prep.js";
import { runPatch } from "./commands/04.patch.js";
import { runToolchainFingerprint } from "./commands/05.toolchain-fingerprint.js";
import { runCompile } from "./commands/06.compile.js";
import { runWatchdogRetry } from "./commands/07-retry.js";
import { runShard } from "./commands/08.shard.js";
import { runWheel } from "./commands/09.wheel.js";
import { runVerify } from "./commands/10.verify.js";
import { runPublish } from "./commands/11.publish.js";

const program = new Command();

program.name("fa-build").description("FlashAttention gfx120x 构建 CLI");

program
  .command("01.config")
  .description("读取并校验 VERSION.lock.json；CI 须 --export-github-env")
  .requiredOption("-w, --workspace-root <path>")
  .option("--export-github-env", "将 lock 变量追加到 GITHUB_ENV")
  .action((opts) => {
    runConfig({
      workspaceRoot: opts.workspaceRoot,
      exportGithubEnv: Boolean(opts.exportGithubEnv),
    });
  });

program
  .command("02.plan-opt-dim-matrix")
  .description(
    "导出 parallel OPT_DIM matrix 到 GITHUB_OUTPUT（opt-dims-json / primary-dim）",
  )
  .action(() => {
    runPlanOptDimMatrix();
  });

program
  .command("03.prep")
  .description(
    "clone flash_attention.build_commit（SHA/tag）；init 子模块；校验 build_commit_date",
  )
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runPrep({ faSrc: opts.faSrc });
  });

program
  .command("04.patch")
  .description(
    "patch flash-attention：workflow CK_FMHA_DISABLE_BWD=1 时跳过 bwd；始终注入 link /Brepro",
  )
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runPatch({ faSrc: opts.faSrc });
  });

program
  .command("05.toolchain-fingerprint")
  .description(
    "输出 MSVC/clang/ninja 指纹；--build-variant 时写入 Ninja cache-key",
  )
  .option("-w, --workspace-root <path>", "仓库根目录（与 --build-variant 联用必填）")
  .option("--build-variant <mode>", "serial 或 parallel（输出 cache-key）")
  .option("--opt-dim <value>", "--build-variant parallel 时的 OPT_DIM shard")
  .action((opts) => {
    runToolchainFingerprint({
      workspaceRoot: opts.workspaceRoot,
      buildVariant: opts.buildVariant,
      optDim: opts.optDim,
    });
  });

program
  .command("06.compile")
  .description("编译单个 OPT_DIM shard 或 lock 全量 ck_opt_dim（含 5h 看门狗）")
  .requiredOption("--opt-dim <value>")
  .requiredOption("--fa-src <path>")
  .action(async (opts) => {
    await runCompile({
      optDim: opts.optDim,
      faSrc: opts.faSrc,
    });
  });

program
  .command("07-retry")
  .description("看门狗中断后 dispatch retry workflow（gh api + 等 concurrency cancel）")
  .requiredOption("--build-variant <mode>", "serial 或 parallel")
  .option(
    "--abort-meta-dir <path>",
    "parallel watchdog-retry job：读取 compile shard 上传的 abort 元数据目录",
  )
  .option(
    "--cache-meta-dir <path>",
    "parallel watchdog-retry job：读取成功 shard 的 cache-meta 目录",
  )
  .option(
    "--all-opt-dims <json>",
    "parallel watchdog-retry job：plan 导出的全部 OPT_DIM JSON 数组",
  )
  .action(async (opts) => {
    const buildVariant = opts.buildVariant as "serial" | "parallel";
    if (buildVariant !== "serial" && buildVariant !== "parallel") {
      throw new Error(`build-variant must be serial or parallel, got ${opts.buildVariant}`);
    }

    let allOptDims: string[] | undefined;
    if (opts.allOptDims !== undefined) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(opts.allOptDims);
      } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        throw new Error(`Invalid --all-opt-dims JSON: ${detail}`);
      }
      if (!Array.isArray(parsed) || parsed.some((dim) => typeof dim !== "string" || dim.length === 0)) {
        throw new Error("--all-opt-dims must be a JSON array of non-empty strings");
      }
      allOptDims = parsed;
    }

    await runWatchdogRetry({
      buildVariant,
      abortMetaDir: opts.abortMetaDir,
      cacheMetaDir: opts.cacheMetaDir,
      allOptDims,
    });
  });

program
  .command("08.shard")
  .description("校验 compile shard 并将 SHARD_RELEASE_DIR 写入 GITHUB_ENV")
  .requiredOption("--fa-src <path>")
  .requiredOption("--opt-dim <value>")
  .action((opts) => {
    runShard({
      faSrc: opts.faSrc,
      optDim: opts.optDim,
    });
  });

program
  .command("09.wheel")
  .description("link 并打 wheel（parallel 须同时传 --staging-root 与 --primary-dim）")
  .requiredOption("--fa-src <path>")
  .requiredOption("--dist-dir <path>")
  .option("--staging-root <path>", "parallel link：FA_STAGING 根目录")
  .option("--primary-dim <value>", "parallel link：lock ck_opt_dim 首档（PRIMARY_DIM）")
  .action((opts) => {
    runWheel({
      faSrc: opts.faSrc,
      distDir: opts.distDir,
      stagingRoot: opts.stagingRoot,
      primaryDim: opts.primaryDim,
    });
  });

program
  .command("10.verify")
  .description(
    "CPU wheel smoke test；写 .sha256 / wheel.manifest.json；校验 --build-caches",
  )
  .requiredOption("--dist-dir <path>")
  .requiredOption("--build-variant <name>", "serial 或 parallel")
  .requiredOption(
    "--build-caches <path>",
    "compile cache 元数据：JSON 数组文件（serial）或含 per-shard JSON 的目录（parallel）",
  )
  .action((opts) => {
    runVerify({
      distDir: opts.distDir,
      buildVariant: opts.buildVariant,
      buildCaches: opts.buildCaches,
    });
  });

program
  .command("11.publish")
  .description("准备 GitHub Release 元数据")
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
