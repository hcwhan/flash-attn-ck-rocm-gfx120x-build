import { createHash } from "node:crypto";

function cacheKeyToken(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]+/g, "-");
}

function cacheKeySegment(label: string, value: string): string {
  return `${label}[${cacheKeyToken(value)}]`;
}

export function buildPipToolchainCacheKey(options: {
  pythonVersion: string;
  pytorchVersion: string;
  torchDeviceExtra: string;
  rocmVersion: string;
  rocmIndex: string;
}): string {
  const indexHash = createHash("sha256")
    .update(options.rocmIndex, "utf8")
    .digest("hex")
    .slice(0, 8);

  return [
    "fa-pip-toolchain-v2",
    cacheKeySegment("py", options.pythonVersion),
    cacheKeySegment("pt", options.pytorchVersion),
    cacheKeySegment("dev", options.torchDeviceExtra),
    cacheKeySegment("rocm", options.rocmVersion),
    cacheKeySegment("idx", indexHash),
  ].join("-");
}
