import { cacheKeyToken } from "./cache-key-token.js";

export function buildNinjaCacheKey(options: {
  buildVariant: "serial" | "parallel";
  lockHash: string;
  optDim?: string;
  msvcVersion: string;
  rocmClangVersion: string;
  ninjaMinor: string;
}): string {
  const segments = [
    options.buildVariant === "serial"
      ? "fa2-ck-gfx120x-serial-v6"
      : "fa2-ck-gfx120x-parallel-v6",
    `lock[${options.lockHash}]`,
  ];

  if (options.buildVariant === "parallel") {
    if (!options.optDim) {
      throw new Error("optDim is required for parallel ninja cache key");
    }
    segments.push(`dim[${options.optDim}]`);
  }

  segments.push(
    `msvc[${cacheKeyToken(options.msvcVersion)}]`,
    `rocmClang[${cacheKeyToken(options.rocmClangVersion)}]`,
    `ninja[${options.ninjaMinor}]`,
  );

  return segments.join("-");
}
