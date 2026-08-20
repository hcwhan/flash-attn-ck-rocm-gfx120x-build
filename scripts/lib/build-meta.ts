import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

const buildMetaEntrySchema = z.object({
  opt_dim: z.string().min(1),
  key: z.string().min(1),
  exists: z.boolean(),
  used: z.boolean(),
});

type BuildMetaEntry = z.infer<typeof buildMetaEntrySchema>;

const buildMetaSchema = z.array(buildMetaEntrySchema).min(1);

function parseBuildMetaEntry(raw: unknown, source: string): BuildMetaEntry {
  const parsed = buildMetaEntrySchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(`Invalid build meta entry in ${source}: ${parsed.error.message}`);
  }
  return parsed.data;
}

function readJsonFilesRecursive(dir: string): BuildMetaEntry[] {
  const entries: BuildMetaEntry[] = [];
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
    entries.push(parseBuildMetaEntry(raw, fullPath));
  }
  return entries;
}

function readBuildMetaFromFile(resolved: string): BuildMetaEntry[] {
  const raw = JSON.parse(readFileSync(resolved, "utf8")) as unknown;
  if (Array.isArray(raw)) {
    return buildMetaSchema.parse(raw);
  }
  return [parseBuildMetaEntry(raw, resolved)];
}

function sortBuildMeta(entries: BuildMetaEntry[]): BuildMetaEntry[] {
  return [...entries].sort((left, right) => {
    const leftFirst = Number(left.opt_dim.split(",")[0]?.trim());
    const rightFirst = Number(right.opt_dim.split(",")[0]?.trim());
    if (!Number.isFinite(leftFirst) || !Number.isFinite(rightFirst)) {
      throw new Error(
        `Cannot sort build meta by opt_dim: ${left.opt_dim} vs ${right.opt_dim}`,
      );
    }
    return leftFirst - rightFirst;
  });
}

export function readBuildMeta(inputPath: string): BuildMetaEntry[] {
  const resolved = path.resolve(inputPath);
  const stat = statSync(resolved);
  const entries = stat.isDirectory()
    ? readJsonFilesRecursive(resolved)
    : readBuildMetaFromFile(resolved);

  if (entries.length < 1) {
    throw new Error(`No build meta entries found at ${resolved}`);
  }

  return sortBuildMeta(entries);
}

export function validateBuildMetaForVariant(options: {
  buildMeta: BuildMetaEntry[];
  buildVariant: string;
  ckOptDim: string;
}): BuildMetaEntry[] {
  const expectedDims = options.ckOptDim
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  if (expectedDims.length < 1) {
    throw new Error("CK_OPT_DIM must contain at least one CK FMHA opt_dim tier");
  }

  const buildVariant = options.buildVariant.trim().toLowerCase();
  if (buildVariant === "serial") {
    if (options.buildMeta.length !== 1) {
      throw new Error(
        `serial build expects exactly one build meta entry, got ${options.buildMeta.length}`,
      );
    }
    const entry = options.buildMeta[0]!;
    if (entry.opt_dim !== options.ckOptDim) {
      throw new Error(
        `serial build meta opt_dim mismatch: ${entry.opt_dim} != ${options.ckOptDim}`,
      );
    }
    return options.buildMeta;
  }

  if (buildVariant !== "parallel") {
    throw new Error(
      `build variant must be 'serial' or 'parallel', got ${options.buildVariant}`,
    );
  }

  if (options.buildMeta.length !== expectedDims.length) {
    throw new Error(
      `parallel build expects ${expectedDims.length} build meta entries, got ${options.buildMeta.length}`,
    );
  }

  const actualDims = options.buildMeta.map((entry) => entry.opt_dim);
  for (let index = 0; index < expectedDims.length; index += 1) {
    const expected = expectedDims[index]!;
    const actual = actualDims[index]!;
    if (actual !== expected) {
      throw new Error(
        `parallel build meta opt_dim order mismatch at index ${index}: ${actual} != ${expected}`,
      );
    }
  }

  return options.buildMeta;
}
