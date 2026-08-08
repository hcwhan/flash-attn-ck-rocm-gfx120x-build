"""Build flash-attn via in-process setuptools (compile-only, serial, or parallel link)."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

_PATCHED = False
_ORIGINAL_RUN_NINJA = None

DIM_PATTERN = re.compile(r"_d(\d+)_")


def load_opt_dims(workspace_root: Path | None = None) -> tuple[str, ...]:
    """Resolve full OPT_DIM tiers from env or VERSION.lock.json."""
    opt_dim = os.environ.get("OPT_DIM", "").strip()
    if opt_dim and "," in opt_dim:
        dims = tuple(part.strip() for part in opt_dim.split(",") if part.strip())
        if dims:
            return dims

    if workspace_root is not None:
        lock_path = workspace_root / "VERSION.lock.json"
        if lock_path.is_file():
            lock = json.loads(lock_path.read_text(encoding="utf-8"))
            raw = str(lock.get("opt_dim", "")).strip()
            dims = tuple(part.strip() for part in raw.split(",") if part.strip())
            if dims:
                return dims

    if opt_dim:
        return (opt_dim,)

    raise SystemExit(
        "Cannot resolve OPT_DIM list: set comma-separated OPT_DIM env or pass --workspace-root"
    )


def resolve_primary_dim(primary_dim: str, expected_dims: tuple[str, ...]) -> str:
    if primary_dim:
        if primary_dim not in expected_dims:
            raise SystemExit(
                f"primary_dim {primary_dim} is not in OPT_DIM list: {', '.join(expected_dims)}"
            )
        return primary_dim
    return expected_dims[0]


def _exec_setup_py(fa_src: Path, command_argv: list[str]) -> None:
    """Run setup.py in-process (same invocation model as bdist_wheel / build_ext)."""
    import importlib.util

    os.chdir(fa_src)
    setup_py = fa_src / "setup.py"
    sys.argv = [str(setup_py), *command_argv]
    print("Running:", " ".join(sys.argv), flush=True)

    spec = importlib.util.spec_from_file_location("flash_attn_setup", setup_py)
    if spec is None or spec.loader is None:
        raise SystemExit(f"Failed to load {setup_py}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


def build_ext_only(fa_src: Path, *, verbose: bool = False) -> None:
    """Compile extension objects only (parallel OPT_DIM shard; no --inplace)."""
    argv = ["build_ext"]
    if verbose:
        argv.append("-v")
    _exec_setup_py(fa_src, argv)


def validate_staging(
    staging_root: Path,
    *,
    expected_dims: tuple[str, ...],
    primary_dim: str,
) -> None:
    """Fail fast before link if compile artifacts are missing or cross-contaminated."""
    staging_root = staging_root.resolve()
    if not staging_root.is_dir():
        raise SystemExit(f"Staging root missing: {staging_root}")

    primary_dim = resolve_primary_dim(primary_dim, expected_dims)

    summary: dict[str, int] = {}
    for dim in expected_dims:
        shard = staging_root / f"d{dim}"
        if not shard.is_dir():
            raise SystemExit(f"Missing OPT_DIM staging dir: {shard}")

        objs = list(shard.rglob("*.obj"))
        summary[dim] = len(objs)
        if not objs:
            raise SystemExit(f"No .obj files under {shard}")

        dim_kernel_objs = [obj for obj in objs if DIM_PATTERN.search(obj.name)]
        foreign = [obj for obj in dim_kernel_objs if f"_d{dim}_" not in obj.name]
        if foreign:
            sample = ", ".join(obj.name for obj in foreign[:3])
            raise SystemExit(f"Shard d{dim} contains foreign-dim kernel objs: {sample}")

        dim_specific = [obj for obj in dim_kernel_objs if f"_d{dim}_" in obj.name]
        if not dim_specific:
            raise SystemExit(f"Shard d{dim} has no *_d{dim}_* kernel objects")

    primary = staging_root / f"d{primary_dim}"
    shared = [
        obj
        for obj in primary.rglob("*.obj")
        if "csrc/flash_attn_ck/" in obj.relative_to(primary).as_posix()
    ]
    if not shared:
        raise SystemExit(
            f"Primary shard d{primary_dim} missing csrc/flash_attn_ck shared objects"
        )

    print(
        "Link staging validation OK: "
        + ", ".join(f"d{dim}={summary[dim]}" for dim in expected_dims),
        flush=True,
    )


def _newest_generated_cu_mtime(fa_src: Path) -> float:
    """Return the latest mtime of generate.py outputs under fa_src/build."""
    build_dir = fa_src / "build"
    latest = 0.0
    if build_dir.is_dir():
        for cu in build_dir.glob("fmha_*.cu"):
            latest = max(latest, cu.stat().st_mtime)
    return latest


def _stamp_prebuilt_obj(dest: Path, fa_src: Path) -> None:
    """Mark seeded .obj newer than freshly generated .cu so ninja skips recompile."""
    stamp = max(time.time(), _newest_generated_cu_mtime(fa_src) + 1.0)
    os.utime(dest, (stamp, stamp))


def install_patch(staging_root: Path, fa_src: Path, primary_dim: str = "") -> None:
    """Patch torch cpp_extension to seed prebuilt .obj files before ninja runs."""
    global _PATCHED, _ORIGINAL_RUN_NINJA
    if _PATCHED:
        return

    import torch.utils.cpp_extension as cpp_ext

    _ORIGINAL_RUN_NINJA = cpp_ext._run_ninja_build

    staging_dirs = sorted(p for p in staging_root.iterdir() if p.is_dir())
    if not staging_dirs:
        raise SystemExit(f"No OPT_DIM staging dirs under {staging_root}")

    primary_dir = staging_root / f"d{primary_dim}"
    if not primary_dir.is_dir():
        primary_dir = staging_dirs[0]

    def merge_prebuilt_objects(temp_release: Path) -> int:
        temp_release.mkdir(parents=True, exist_ok=True)
        copied = 0

        def copy_obj(src: Path, rel: Path) -> None:
            nonlocal copied
            dest = temp_release / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            _stamp_prebuilt_obj(dest, fa_src)
            copied += 1

        for obj in primary_dir.rglob("*.obj"):
            copy_obj(obj, obj.relative_to(primary_dir))

        for staging in staging_dirs:
            if staging.resolve() == primary_dir.resolve():
                continue
            for obj in staging.rglob("*.obj"):
                rel = obj.relative_to(staging)
                rel_posix = rel.as_posix()
                if rel_posix.startswith("csrc/flash_attn_ck/"):
                    continue
                if not rel_posix.startswith("build/"):
                    continue
                if not DIM_PATTERN.search(obj.name):
                    continue
                dest = temp_release / rel
                if not dest.exists():
                    copy_obj(obj, rel)

        return copied

    def patched_run_ninja(build_directory, *args, **kwargs):
        build_dir = Path(build_directory)
        count = merge_prebuilt_objects(build_dir)
        print(f"Merged {count} prebuilt .obj files into {build_dir}", flush=True)
        return _ORIGINAL_RUN_NINJA(build_directory, *args, **kwargs)

    cpp_ext._run_ninja_build = patched_run_ninja
    _PATCHED = True


def build_wheel(fa_src: Path, dist_dir: Path, *, verbose: bool = False) -> None:
    dist_dir.mkdir(parents=True, exist_ok=True)
    argv = ["bdist_wheel", "--dist-dir", str(dist_dir)]
    if verbose:
        argv.insert(0, "-v")
    _exec_setup_py(fa_src, argv)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fa-src", type=Path)
    parser.add_argument("--staging-root", type=Path)
    parser.add_argument("--dist-dir", type=Path)
    parser.add_argument("--workspace-root", type=Path)
    parser.add_argument("--primary-dim", default="")
    parser.add_argument(
        "--compile-only",
        action="store_true",
        help="In-process build_ext only (parallel OPT_DIM shard compile)",
    )
    parser.add_argument(
        "--serial",
        action="store_true",
        help="Full single-pass bdist_wheel (no OPT_DIM obj merge)",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate staging layout and exit without building",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Verbose setuptools/ninja output",
    )
    args = parser.parse_args()

    workspace_root = args.workspace_root
    expected_dims = load_opt_dims(workspace_root)
    primary_dim = resolve_primary_dim(args.primary_dim, expected_dims)

    if args.validate_only:
        if args.staging_root is None:
            raise SystemExit("--staging-root is required with --validate-only")
        if not args.staging_root.is_dir():
            raise SystemExit(f"Staging root missing: {args.staging_root}")
        validate_staging(
            args.staging_root,
            expected_dims=expected_dims,
            primary_dim=primary_dim,
        )
        return

    if args.compile_only:
        if args.fa_src is None:
            raise SystemExit("--fa-src is required with --compile-only")
        if not args.fa_src.is_dir():
            raise SystemExit(f"FA source missing: {args.fa_src}")
        build_ext_only(args.fa_src, verbose=args.verbose)
        return

    if args.serial:
        if args.fa_src is None or args.dist_dir is None:
            raise SystemExit("--fa-src and --dist-dir are required with --serial")
        if not args.fa_src.is_dir():
            raise SystemExit(f"FA source missing: {args.fa_src}")
        build_wheel(args.fa_src, args.dist_dir, verbose=args.verbose)
        return

    if args.staging_root is None:
        raise SystemExit(
            "--staging-root is required unless --serial, --compile-only, or --validate-only"
        )
    if args.fa_src is None or args.dist_dir is None:
        raise SystemExit("--fa-src and --dist-dir are required for parallel link")
    if not args.staging_root.is_dir():
        raise SystemExit(f"Staging root missing: {args.staging_root}")
    if not args.fa_src.is_dir():
        raise SystemExit(f"FA source missing: {args.fa_src}")

    validate_staging(
        args.staging_root,
        expected_dims=expected_dims,
        primary_dim=primary_dim,
    )
    install_patch(args.staging_root, args.fa_src, primary_dim=primary_dim)
    build_wheel(args.fa_src, args.dist_dir, verbose=args.verbose)


if __name__ == "__main__":
    main()
