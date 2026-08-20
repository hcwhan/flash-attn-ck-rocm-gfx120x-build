import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

const abortMetaSchema = z.object({
  opt_dim: z.string().min(1),
  should_retry: z.boolean(),
});

const cacheMetaSchema = z.object({
  opt_dim: z.string().min(1),
  key: z.string(),
  exists: z.boolean(),
  used: z.boolean(),
});

type WatchdogAbortMetaEntry = z.infer<typeof abortMetaSchema>;

type ParallelWatchdogRetryEvaluation =
  | { eligible: true; entries: WatchdogAbortMetaEntry[] }
  | { eligible: false; reason: string };

function collectJsonFiles(root: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(root)) {
    const fullPath = path.join(root, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      files.push(...collectJsonFiles(fullPath));
      continue;
    }
    if (entry.endsWith(".json")) {
      files.push(fullPath);
    }
  }
  return files;
}

function setsEqual(a: Set<string>, b: Set<string>): boolean {
  if (a.size !== b.size) {
    return false;
  }
  for (const value of a) {
    if (!b.has(value)) {
      return false;
    }
  }
  return true;
}

function parseJsonFiles<T>(
  root: string,
  schema: z.ZodType<T>,
  label: string,
): T[] {
  let jsonFiles: string[];
  try {
    jsonFiles = collectJsonFiles(root);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    throw new Error(`${label} dir not readable (${root}): ${detail}`);
  }

  return jsonFiles.map((filePath) => {
    const raw = readFileSync(filePath, "utf8");
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      throw new Error(`Invalid JSON in ${label} ${filePath}: ${detail}`);
    }
    return schema.parse(parsed);
  });
}

function readWatchdogAbortMetaEntries(watchdogAbortMetaDir: string): WatchdogAbortMetaEntry[] {
  const root = path.resolve(watchdogAbortMetaDir);
  let jsonFiles: string[];
  try {
    jsonFiles = collectJsonFiles(root);
  } catch {
    return [];
  }

  if (jsonFiles.length === 0) {
    return [];
  }

  const entries = parseJsonFiles(root, abortMetaSchema, "watchdog abort metadata");

  const noRetryDims = entries
    .filter((entry) => !entry.should_retry)
    .map((entry) => entry.opt_dim);
  if (noRetryDims.length > 0) {
    throw new Error(
      `Watchdog abort without retry on shard(s): ${noRetryDims.join(", ")}; cannot retry`,
    );
  }

  return entries;
}

function readCompileSuccessMetaOptDims(compileSuccessMetaDir: string): string[] {
  const root = path.resolve(compileSuccessMetaDir);
  let jsonFiles: string[];
  try {
    jsonFiles = collectJsonFiles(root);
  } catch {
    return [];
  }

  if (jsonFiles.length === 0) {
    return [];
  }

  return parseJsonFiles(root, cacheMetaSchema, "compile success metadata").map(
    (entry) => entry.opt_dim,
  );
}

export function evaluateParallelWatchdogRetry(options: {
  allOptDims: string[];
  watchdogAbortMetaDir: string;
  compileSuccessMetaDir: string;
}): ParallelWatchdogRetryEvaluation {
  const allDimsSet = new Set(options.allOptDims);
  if (allDimsSet.size !== options.allOptDims.length) {
    throw new Error("allOptDims contains duplicates");
  }
  if (allDimsSet.size === 0) {
    throw new Error("allOptDims is empty");
  }

  const successDims = new Set(readCompileSuccessMetaOptDims(options.compileSuccessMetaDir));
  const failedDims = [...allDimsSet].filter((dim) => !successDims.has(dim));

  if (failedDims.length === 0) {
    return {
      eligible: false,
      reason:
        "compile matrix reported failure but every OPT_DIM has compile-success metadata",
    };
  }

  const abortEntries = readWatchdogAbortMetaEntries(options.watchdogAbortMetaDir);
  const watchdogDims = new Set(abortEntries.map((entry) => entry.opt_dim));
  const failedSet = new Set(failedDims);

  if (!setsEqual(failedSet, watchdogDims)) {
    const nonWatchdog = failedDims.filter((dim) => !watchdogDims.has(dim));
    const orphanWatchdog = [...watchdogDims].filter((dim) => !failedSet.has(dim));
    const parts: string[] = [];
    if (nonWatchdog.length > 0) {
      parts.push(
        `non-watchdog failed shard(s): ${nonWatchdog.sort().join(", ")}`,
      );
    }
    if (orphanWatchdog.length > 0) {
      parts.push(
        `watchdog metadata for non-failed shard(s): ${orphanWatchdog.sort().join(", ")}`,
      );
    }
    return {
      eligible: false,
      reason: parts.join("; "),
    };
  }

  return { eligible: true, entries: abortEntries };
}
