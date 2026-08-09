export function buildNinjaCacheKey(options: {
  variant: "serial" | "parallel";
  optDim?: string;
  msvcHash: string;
  pipHash: string;
}): string {
  if (options.variant === "serial") {
    return `fa2-ck-gfx1201-serial-v4-msvc${options.msvcHash}-pip${options.pipHash}`;
  }

  if (!options.optDim) {
    throw new Error("optDim is required for parallel ninja cache key");
  }

  return `fa2-ck-gfx1201-parallel-v4-d${options.optDim}-msvc${options.msvcHash}-pip${options.pipHash}`;
}
