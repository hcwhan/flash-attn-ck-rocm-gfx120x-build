const FWD_API_OBJS = [
  "fmha_fwd_api.obj",
  "fmha_fwd_appendkv_api.obj",
  "fmha_fwd_splitkv_api.obj",
] as const;

const BWD_API_OBJ = "fmha_bwd_api.obj";

export function parseCkDisableBwd(ckDisableBwd: string): boolean {
  if (ckDisableBwd === "true") {
    return true;
  }
  if (ckDisableBwd === "false") {
    return false;
  }
  throw new Error(
    `CK_DISABLE_BWD must be 'true' or 'false', got ${ckDisableBwd}`,
  );
}

export function requiredApiObjs(ckDisableBwd: boolean): ReadonlySet<string> {
  const objs = new Set<string>(FWD_API_OBJS);
  if (!ckDisableBwd) {
    objs.add(BWD_API_OBJ);
  }
  return objs;
}
