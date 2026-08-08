"""Merge parallel OPT_DIM compile artifacts and build the flash-attn wheel."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

_PATCHED = False
_ORIGINAL_RUN_NINJA = None


def install_patch(staging_root: Path, primary_dim: str = "32") -> None:
    """Patch torch cpp_extension to seed prebuilt .obj files before ninja runs."""
    global _PATCHED, _ORIGINAL_RUN_NINJA
    if _PATCHED:
        return

    import torch.utils.cpp_extension as cpp_ext

    _ORIGINAL_RUN_NINJA = cpp_ext._run_ninja_build
    dim_pattern = re.compile(r"_d(\d+)_")

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
                if not dim_pattern.search(obj.name):
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


def build_wheel(fa_src: Path, dist_dir: Path) -> None:
    import importlib.util

    dist_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(fa_src)

    setup_py = fa_src / "setup.py"
    argv = [str(setup_py), "bdist_wheel", "--dist-dir", str(dist_dir)]
    sys.argv = argv
    print("Running:", " ".join(argv), flush=True)

    spec = importlib.util.spec_from_file_location("flash_attn_setup", setup_py)
    if spec is None or spec.loader is None:
        raise SystemExit(f"Failed to load {setup_py}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fa-src", type=Path, required=True)
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument("--dist-dir", type=Path, required=True)
    parser.add_argument("--primary-dim", default="32")
    args = parser.parse_args()

    if not args.fa_src.is_dir():
        raise SystemExit(f"FA source missing: {args.fa_src}")
    if not args.staging_root.is_dir():
        raise SystemExit(f"Staging root missing: {args.staging_root}")

    install_patch(args.staging_root, primary_dim=args.primary_dim)
    build_wheel(args.fa_src, args.dist_dir)


if __name__ == "__main__":
    main()
