import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

const buildCacheEntrySchema = z.object({
  opt_dim: z.string().min(1),
  key: z.string().min(1),
  hit: z.boolean(),
  restore_skipped: z.boolean(),
});

export type BuildCacheEntry = z.infer<typeof buildCacheEntrySchema>;

const buildCachesSchema = z.array(buildCacheEntrySchema).min(1);

function parseBuildCacheEntry(raw: unknown, source: string): BuildCacheEntry {
  const parsed = buildCacheEntrySchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(`Invalid build cache entry in ${source}: ${parsed.error.message}`);
  }
  return parsed.data;
}

function readJsonFilesRecursive(dir: string): BuildCacheEntry[] {
  const entries: BuildCacheEntry[] = [];
  for (const name of readdirSync(dir)) {
    const fullPath = path.join(dir, name);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      entries.push(...readJsonFilesRecursive(fullPath));
      continue;
    }
    if (!stat.isFile() || !name.endsWith(".json")) {
      continue;
    }
    const raw = JSON.parse(readFileSync(fullPath, "utf8")) as unknown;
    entries.push(parseBuildCacheEntry(raw, fullPath));
  }
  return entries;
}

function sortBuildCaches(entries: BuildCacheEntry[]): BuildCacheEntry[] {
  return [...entries].sort((left, right) => {
    const leftFirst = Number(left.opt_dim.split(",")[0]?.trim());
    const rightFirst = Number(right.opt_dim.split(",")[0]?.trim());
    if (!Number.isFinite(leftFirst) || !Number.isFinite(rightFirst)) {
      throw new Error(
        `Cannot sort build caches by opt_dim: ${left.opt_dim} vs ${right.opt_dim}`,
      );
    }
    return leftFirst - rightFirst;
  });
}

export function readBuildCaches(inputPath: string): BuildCacheEntry[] {
  const resolved = path.resolve(inputPath);
  const stat = statSync(resolved);
  const entries = stat.isDirectory()
    ? readJsonFilesRecursive(resolved)
    : buildCachesSchema.parse(JSON.parse(readFileSync(resolved, "utf8")));

  if (entries.length < 1) {
    throw new Error(`No build cache entries found at ${resolved}`);
  }

  return sortBuildCaches(entries);
}

export function validateBuildCachesForVariant(options: {
  buildCaches: BuildCacheEntry[];
  buildVariant: string;
  lockOptDim: string;
}): BuildCacheEntry[] {
  const expectedDims = options.lockOptDim
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  if (expectedDims.length < 1) {
    throw new Error("LOCK_OPT_DIM must contain at least one OPT_DIM");
  }

  const buildVariant = options.buildVariant.trim().toLowerCase();
  if (buildVariant === "serial") {
    if (options.buildCaches.length !== 1) {
      throw new Error(
        `serial build expects exactly one build cache entry, got ${options.buildCaches.length}`,
      );
    }
    const entry = options.buildCaches[0]!;
    if (entry.opt_dim !== options.lockOptDim) {
      throw new Error(
        `serial build cache opt_dim mismatch: ${entry.opt_dim} != ${options.lockOptDim}`,
      );
    }
    return options.buildCaches;
  }

  if (buildVariant !== "parallel") {
    throw new Error(
      `build variant must be 'serial' or 'parallel', got ${options.buildVariant}`,
    );
  }

  if (options.buildCaches.length !== expectedDims.length) {
    throw new Error(
      `parallel build expects ${expectedDims.length} build cache entries, got ${options.buildCaches.length}`,
    );
  }

  const actualDims = options.buildCaches.map((entry) => entry.opt_dim);
  for (let index = 0; index < expectedDims.length; index += 1) {
    const expected = expectedDims[index]!;
    const actual = actualDims[index]!;
    if (actual !== expected) {
      throw new Error(
        `parallel build cache opt_dim order mismatch at index ${index}: ${actual} != ${expected}`,
      );
    }
  }

  return options.buildCaches;
}
