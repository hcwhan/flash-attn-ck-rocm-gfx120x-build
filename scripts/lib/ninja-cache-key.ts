export function buildNinjaCacheKey(options: {
  buildVariant: "serial" | "parallel";
  optDim?: string;
  msvcHash: string;
  rocmClangHash: string;
  pipToolchainHash: string;
}): string {
  const toolchain = `msvc${options.msvcHash}-rocmClang${options.rocmClangHash}-pipToolchain${options.pipToolchainHash}`;

  if (options.buildVariant === "serial") {
    return `fa2-ck-gfx1201-serial-v5-${toolchain}`;
  }

  if (!options.optDim) {
    throw new Error("optDim is required for parallel ninja cache key");
  }

  return `fa2-ck-gfx1201-parallel-v5-d${options.optDim}-${toolchain}`;
}
