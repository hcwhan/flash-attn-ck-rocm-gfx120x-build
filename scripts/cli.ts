#!/usr/bin/env node
import { Command } from "commander";
import { runConfig } from "./commands/01.config.js";
import { runPlanOptDimMatrix } from "./commands/02.plan-opt-dim-matrix.js";
import { runPrep } from "./commands/03.prep.js";
import { runPatch } from "./commands/04.patch.js";
import { runToolchainFingerprint } from "./commands/05.toolchain-fingerprint.js";
import { runCompile } from "./commands/06.compile.js";
import { runShard } from "./commands/07.shard.js";
import { runWheel } from "./commands/08.wheel.js";
import { runVerify } from "./commands/09.verify.js";
import { runPublish } from "./commands/10.publish.js";

const program = new Command();

program.name("fa-build").description("FlashAttention gfx120x 构建 CLI");

program
  .command("01.config")
  .description("读取 VERSION.lock.json")
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
  .description("导出 parallel compile 用的 OPT_DIM matrix 输出")
  .action(() => {
    runPlanOptDimMatrix();
  });

program
  .command("03.prep")
  .description("按 pin 的 SHA 或 tag clone flash-attention 源码")
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runPrep({ faSrc: opts.faSrc });
  });

program
  .command("04.patch")
  .description("为推理专用 CK 构建 patch flash-attention")
  .requiredOption("--fa-src <path>")
  .action((opts) => {
    runPatch({ faSrc: opts.faSrc });
  });

program
  .command("05.toolchain-fingerprint")
  .description("输出 MSVC/clang 与 pip 工具链 cache 指纹")
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
  .description("编译单个 OPT_DIM shard 或 lock 全量 ck_opt_dim")
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
  .command("08.wheel")
  .description("link 并打 wheel")
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
  .requiredOption("--build-variant <name>", "serial 或 parallel")
  .requiredOption(
    "--build-caches <path>",
    "各 shard compile cache 元数据的 JSON 数组文件或目录",
  )
  .action((opts) => {
    runVerify({
      distDir: opts.distDir,
      buildVariant: opts.buildVariant,
      buildCaches: opts.buildCaches,
    });
  });

program
  .command("10.publish")
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
