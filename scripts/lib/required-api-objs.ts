const FWD_API_OBJS = [
  "fmha_fwd_api.obj",
  "fmha_fwd_appendkv_api.obj",
  "fmha_fwd_splitkv_api.obj",
] as const;

const BWD_API_OBJ = "fmha_bwd_api.obj";

export function parseCkFmhaDisableBwd(ckFmhaDisableBwd: string): boolean {
  if (ckFmhaDisableBwd === "1") {
    return true;
  }
  if (ckFmhaDisableBwd === "0") {
    return false;
  }
  throw new Error(
    `CK_FMHA_DISABLE_BWD must be '1' or '0', got ${ckFmhaDisableBwd}`,
  );
}

export function requiredApiObjs(ckFmhaDisableBwd: boolean): ReadonlySet<string> {
  const objs = new Set<string>(FWD_API_OBJS);
  if (!ckFmhaDisableBwd) {
    objs.add(BWD_API_OBJ);
  }
  return objs;
}
