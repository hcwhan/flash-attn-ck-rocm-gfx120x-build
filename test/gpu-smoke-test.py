#!/usr/bin/env python3
"""部署前 GPU smoke test（gfx120x 真机；CI 不跑）。"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from flash_attn import flash_attn_func, flash_attn_with_kvcache


def load_lock(workspace_root: Path) -> dict:
    lock_path = workspace_root / "VERSION.lock.json"
    with lock_path.open(encoding="utf-8") as handle:
        return json.load(handle)


def parse_ck_opt_dims(ck_opt_dim: str) -> list[int]:
    dims = [int(part.strip()) for part in ck_opt_dim.split(",") if part.strip()]
    if not dims:
        raise SystemExit("VERSION.lock.json compile.ck_opt_dim is missing or empty")
    return dims


def parse_gpu_archs(gpu_archs: str) -> list[str]:
    parts = [
        part.strip().lower()
        for part in gpu_archs.replace(",", ";").split(";")
        if part.strip()
    ]
    if not parts:
        raise SystemExit("VERSION.lock.json compile.gpu_archs is missing or empty")
    return parts


def main() -> None:
    parser = argparse.ArgumentParser(description="flash_attn wheel 的 GPU smoke test")
    parser.add_argument(
        "-w",
        "--workspace-root",
        required=True,
        help="含 VERSION.lock.json 的仓库根目录",
    )
    args = parser.parse_args()

    lock = load_lock(Path(args.workspace_root).resolve())
    compile_lock = lock.get("compile")
    if not isinstance(compile_lock, dict):
        raise SystemExit("VERSION.lock.json compile section is missing")

    gpu_archs = compile_lock.get("gpu_archs")
    ck_opt_dim = compile_lock.get("ck_opt_dim")
    if not isinstance(gpu_archs, str) or not gpu_archs.strip():
        raise SystemExit("VERSION.lock.json compile.gpu_archs is missing")
    if not isinstance(ck_opt_dim, str) or not ck_opt_dim.strip():
        raise SystemExit("VERSION.lock.json compile.ck_opt_dim is missing")

    expected_archs = parse_gpu_archs(gpu_archs)
    head_dims = parse_ck_opt_dims(ck_opt_dim)

    print(f"GPU smoke test on {gpu_archs} (requires ROCm PyTorch + GPU)")
    print(f"CK OPT_DIM tiers: {', '.join(str(dim) for dim in head_dims)}")

    if not torch.cuda.is_available():
        raise SystemExit("ERROR: torch.cuda.is_available() is False; need ROCm GPU")

    device = torch.device("cuda")
    props = torch.cuda.get_device_properties(0)
    arch = (getattr(props, "gcnArchName", None) or "").lower()
    print(f"GPU: {props.name} (gcnArchName={arch or 'unknown'})")

    if not any(expected in arch for expected in expected_archs):
        raise SystemExit(
            "ERROR: gcnArchName "
            f"{arch!r} does not match lock compile.gpu_archs {expected_archs!r}"
        )
    matched = next(expected for expected in expected_archs if expected in arch)
    print(f"OK GPU arch matches lock entry {matched!r}")

    batch, seqlen, nheads = 1, 64, 4
    for headdim in head_dims:
        q = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
        k = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
        v = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
        out = flash_attn_func(q, k, v, causal=True)
        if out.shape != q.shape:
            raise SystemExit(f"ERROR: headdim={headdim} unexpected output shape {out.shape}")
        if not torch.isfinite(out).all():
            raise SystemExit(f"ERROR: headdim={headdim} output has non-finite values")
        torch.cuda.synchronize()
        print(f"GPU forward OK headdim={headdim} shape={tuple(out.shape)}")

    seqlen_q_kv, seqlen_k, seqlen_knew, cache_seqlen = 8, 16, 8, 8
    for headdim in head_dims:
        q = torch.randn(batch, seqlen_q_kv, nheads, headdim, device=device, dtype=torch.float16)
        kcache = torch.randn(batch, seqlen_k, nheads, headdim, device=device, dtype=torch.float16)
        vcache = torch.randn(batch, seqlen_k, nheads, headdim, device=device, dtype=torch.float16)
        k_new = torch.randn(batch, seqlen_knew, nheads, headdim, device=device, dtype=torch.float16)
        v_new = torch.randn(batch, seqlen_knew, nheads, headdim, device=device, dtype=torch.float16)
        cache_seqlens = torch.full((batch,), cache_seqlen, dtype=torch.int32, device=device)
        if seqlen_q_kv > seqlen_k:
            raise SystemExit(
                f"ERROR: kvcache smoke requires seqlen_q <= kcache.size(1): "
                f"{seqlen_q_kv} > {seqlen_k}"
            )
        if cache_seqlen + seqlen_knew > seqlen_k:
            raise SystemExit(
                f"ERROR: kvcache smoke params overflow cache: "
                f"{cache_seqlen} + {seqlen_knew} > {seqlen_k}"
            )
        out = flash_attn_with_kvcache(
            q,
            kcache,
            vcache,
            k_new,
            v_new,
            cache_seqlens=cache_seqlens,
            causal=True,
        )
        if out.shape != q.shape:
            raise SystemExit(
                f"ERROR: headdim={headdim} unexpected kvcache output shape {out.shape}"
            )
        if not torch.isfinite(out).all():
            raise SystemExit(
                f"ERROR: headdim={headdim} kvcache output has non-finite values"
            )
        torch.cuda.synchronize()
        print(f"GPU kvcache OK headdim={headdim} shape={tuple(out.shape)}")


if __name__ == "__main__":
    main()
