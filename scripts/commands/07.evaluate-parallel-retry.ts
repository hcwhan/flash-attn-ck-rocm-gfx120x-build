import { evaluateParallelWatchdogRetry } from "../lib/watchdog-abort-meta.js";

// parallel watchdog-retry job：校验失败 shard 是否均可 retry（不含 force-killed / 非看门狗失败）
export function runEvaluateParallelWatchdogRetry(options: {
  allOptDims: string[];
  watchdogAbortMetaDir: string;
  compileSuccessMetaDir: string;
}): void {
  const evaluation = evaluateParallelWatchdogRetry({
    allOptDims: options.allOptDims,
    watchdogAbortMetaDir: options.watchdogAbortMetaDir,
    compileSuccessMetaDir: options.compileSuccessMetaDir,
  });

  if (!evaluation.eligible) {
    throw new Error(
      `Compile failed without eligible watchdog retry: ${evaluation.reason}`,
    );
  }

  console.log(
    `Watchdog abort metadata: ${evaluation.entries.map((entry) => entry.opt_dim).join(", ")}`,
  );
}
