export function buildNinjaCacheKey(options: {
  buildVariant: "serial" | "parallel";
  lockHash: string;
  optDim?: string;
  msvcHash: string;
  rocmClangHash: string;
  pipToolchainHash: string;
}): string {
  const lockSegment = options.lockHash;
  const toolchain = `msvc${options.msvcHash}-rocmClang${options.rocmClangHash}-pipToolchain${options.pipToolchainHash}`;

  if (options.buildVariant === "serial") {
    return `fa2-ck-gfx120x-serial-v5-${lockSegment}-${toolchain}`;
  }

  if (!options.optDim) {
    throw new Error("optDim is required for parallel ninja cache key");
  }

  return `fa2-ck-gfx120x-parallel-v5-${lockSegment}-d${options.optDim}-${toolchain}`;
}
