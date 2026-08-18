import { cacheKeyToken } from "./cache-key-token.js";

export const NINJA_CACHE_SERIAL_PREFIX = "fa2-ck-gfx120x-serial-v7";
export const NINJA_CACHE_PARALLEL_PREFIX = "fa2-ck-gfx120x-parallel-v7";

interface NinjaCacheFamilyKeyOptions {
  buildVariant: "serial" | "parallel";
  optDim?: string;
}

interface NinjaCacheKeyOptions extends NinjaCacheFamilyKeyOptions {
  lockHash: string;
  fmhaBwd: boolean;
  msvcVersion: string;
  rocmClangVersion: string;
  ninjaMinor: string;
}

// serial：family = prefix；parallel：family = prefix-dim[shard]（各 shard cleanup 隔离）
export function buildNinjaCacheFamilyKey(
  options: NinjaCacheFamilyKeyOptions,
): string {
  if (options.buildVariant === "serial") {
    return NINJA_CACHE_SERIAL_PREFIX;
  }

  const optDim = options.optDim?.trim();
  if (!optDim) {
    throw new Error("optDim is required for parallel ninja cache family key");
  }

  return `${NINJA_CACHE_PARALLEL_PREFIX}-dim[${optDim}]`;
}

export function buildNinjaCacheKey(options: NinjaCacheKeyOptions): string {
  const familyKey = buildNinjaCacheFamilyKey(options);

  return [
    familyKey,
    `lock[${options.lockHash}]`,
    `bwd[${options.fmhaBwd}]`,
    `msvc[${cacheKeyToken(options.msvcVersion)}]`,
    `rocmClang[${cacheKeyToken(options.rocmClangVersion)}]`,
    `ninja[${options.ninjaMinor}]`,
  ].join("-");
}
