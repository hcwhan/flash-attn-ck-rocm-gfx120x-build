"""Build flash-attn via in-process setuptools (compile / wheel / merge-and-wheel)."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

_ORIGINAL_RUN_NINJA = None

DIM_PATTERN = re.compile(r"_d(\d+)_")
# Generated API dispatch objects (Windows HIP: fmha_fwd_api.obj, …) are per-shard
# partial: each shard only renders the hdim cases for its own OPT_DIM. Merging the
# primary shard's copy would silently drop the other dims' dispatch, so these must
# always be recompiled in the link job from the regenerated all-dim sources.
# (csrc/flash_attn_ck/flash_api.obj is dim-independent and must still be merged.)
REQUIRED_API_OBJS = frozenset(
    {
        "fmha_fwd_api.obj",
        "fmha_fwd_appendkv_api.obj",
        "fmha_fwd_splitkv_api.obj",
    }
)
API_OBJ_PATTERN = re.compile(r"^fmha_.*_api\.obj$")


def is_api_dispatch_obj(name: str) -> bool:
    return bool(API_OBJ_PATTERN.match(name))

# Ninja's dirty check on Windows HIP (PyTorch cpp_extension) is NOT obj-mtime-only.
# build.ninja rules use neither deps=gcc nor deps=msvc (no .ninja_deps); reuse
# depends on:
#   1. obj.mtime >= newest input (regenerated fmha_*.cu, csrc headers)
#   2. a .ninja_log entry exists, its command hash matches, and
#      entry.mtime >= newest input
# A single stamp value applied to obj mtimes AND .ninja_log entry mtimes satisfies
# both; stamping only the .obj violates 2 and makes ninja rebuild every prebuilt
# object.
#
# .ninja_log: v5+ text lines "start<TAB>end<TAB>mtime<TAB>output<TAB>hash",
# mtime in nanoseconds since log v7 (ninja >= 1.13); the header version must be
# preserved, an unknown version makes ninja unlink the log and rebuild all.
_LOG_HEADER_RE = re.compile(r"^# ninja log v(\d+)$")


def _exec_setup_py(fa_src: Path, command_argv: list[str]) -> None:
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
    argv = ["build_ext"]
    if verbose:
        argv.append("-v")
    _exec_setup_py(fa_src, argv)


def _newest_mtime_under(root: Path) -> int:
    """Newest file mtime (ns) under root (csrc headers included in stamp)."""
    latest = 0
    stack = [root]
    while stack:
        dirpath = stack.pop()
        try:
            with os.scandir(dirpath) as it:
                for entry in it:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(Path(entry.path))
                        elif entry.is_file(follow_symlinks=False):
                            latest = max(latest, entry.stat().st_mtime_ns)
                    except OSError:
                        continue
        except OSError:
            continue
    return latest


def compute_stamp(fa_src: Path) -> int:
    """One stamp value (integer nanoseconds) >= every input ninja may compare
    against: the regenerated build/fmha_*.cu and headers under csrc (freshly
    cloned and patched fa-src on the runner).  Applied to obj mtimes and
    .ninja_log entry mtimes in one consistent value; computed once per ninja
    run.  The value is int ns so os.utime(ns=...) and log records agree
    bit-exactly (a float seconds stamp drifts enough to trip dirty checks)."""
    latest = time.time_ns()
    build_dir = fa_src / "build"
    if build_dir.is_dir():
        for cu in build_dir.glob("fmha_*.cu"):
            latest = max(latest, cu.stat().st_mtime_ns)
    latest = max(latest, _newest_mtime_under(fa_src / "csrc"))
    return latest + 1_000_000_000


def _merge_ninja_log(sources: list[Path], dest: Path, stamp: float) -> int:
    """Merge .ninja_log files, rewriting every entry's mtime to the single
    stamp value so ninja's recorded-mtime check (entry.mtime < input) cannot
    fire.  Command hashes are kept verbatim: shard and link compile the same
    sources with the same flags, so the hashes already match the link job's
    build.ninja commands; a drift degrades to a per-edge rebuild, which the
    post-build verification then fails loudly on.  Duplicate outputs: last
    source wins (matches ninja's loader, which overwrites entry fields per
    line).  The header version is preserved (v7 = ns mtimes, ninja >= 1.13;
    v5/v6 = seconds)."""
    version = 0
    by_output: dict[str, str] = {}
    for src in sources:
        try:
            with open(src, "r", encoding="utf-8", newline="") as fh:
                lines = fh.read().splitlines()
        except OSError as exc:
            raise SystemExit(f"Cannot read ninja log {src}: {exc}")
        for line in lines:
            if not line:
                continue
            m = _LOG_HEADER_RE.match(line)
            if m:
                v = int(m.group(1))
                if version and v != version:
                    raise SystemExit(
                        f"ninja log version mismatch: {src} v{v} vs v{version}"
                    )
                version = v
                continue
            fields = line.split("\t")
            if len(fields) < 4:
                continue
            fields[2] = str(stamp) if version >= 7 else str(stamp // 1_000_000_000)
            by_output[fields[3]] = "\t".join(fields)
    if not version:
        raise SystemExit(f"No ninja log header found in {sources[0]}")
    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"# ninja log v{version}\n")
        for line in by_output.values():
            fh.write(line + "\n")
    return version


def stamp_prebuilt_objects(
    temp_release: Path,
    fa_src: Path,
    log_sources: list[Path] | None = None,
) -> float:
    """Two-way stamp: .obj mtimes and .ninja_log entry mtimes get ONE future
    value (>= newest .cu and csrc header), so ninja's dirty checks pass for
    prebuilt objects on Windows HIP.  Sources default to the file already in
    the build dir (cache-restore / plain rebuild); the link job passes shard
    logs, which are merged into the build dir.  Returns the stamp value used."""
    if not temp_release.is_dir():
        return 0
    stamp = compute_stamp(fa_src)

    obj_count = 0
    for obj in temp_release.rglob("*.obj"):
        os.utime(obj, ns=(stamp, stamp))
        obj_count += 1

    log_dest = temp_release / ".ninja_log"
    log_srcs = (
        log_sources
        if log_sources is not None
        else ([log_dest] if log_dest.is_file() else [])
    )
    if log_srcs:
        _merge_ninja_log(log_srcs, log_dest, stamp)

    print(
        f"Stamped {obj_count} prebuilt .obj files with mtime {stamp / 1e9:.3f} in {temp_release}",
        flush=True,
    )
    return stamp


def merge_prebuilt_objects(
    staging_root: Path,
    temp_release: Path,
    fa_src: Path,
    primary_dim: str,
) -> tuple[list[Path], list[Path], list[Path]]:
    """Merge shard .obj files and .ninja_log into the ninja build dir before link.

    - Primary shard: every .obj except the generated API dispatch objects
      (fmha_*_api.obj) -- those are per-shard partial and must be recompiled in
      the link job from the regenerated all-dim sources.
    - Other shards: dim-specific kernel objects only (build/*_d<N>_*).
    - Ninja logs: every shard's .ninja_log (the link build dir is fresh, so
      without it ninja would rebuild all kernels).

    Returns (merged obj paths, ninja log sources, skipped API dispatch sources).
    """
    primary_dir = staging_root / f"d{primary_dim}"
    if not primary_dir.is_dir():
        raise SystemExit(f"Primary staging dir missing: {primary_dir}")

    staging_dirs = sorted(p for p in staging_root.iterdir() if p.is_dir())
    temp_release.mkdir(parents=True, exist_ok=True)
    copied: list[Path] = []
    skipped_api: list[Path] = []
    log_sources: list[Path] = []

    for staging in staging_dirs:
        log_file = staging / ".ninja_log"
        if not log_file.is_file():
            raise SystemExit(
                f"Staging dir {staging} missing .ninja_log "
                "(upload-artifact must set include-hidden-files: true)"
            )
        log_sources.append(log_file)

    def copy_obj(src: Path, rel: Path) -> None:
        dest = temp_release / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        copied.append(dest)

    for obj in primary_dir.rglob("*.obj"):
        if is_api_dispatch_obj(obj.name):
            skipped_api.append(obj)
            print(
                f"  skip {obj.relative_to(primary_dir).as_posix()} (recompiled in link job)",
                flush=True,
            )
            continue
        copy_obj(obj, obj.relative_to(primary_dir))

    if {p.name for p in skipped_api} != REQUIRED_API_OBJS:
        raise SystemExit(
            "Primary shard API dispatch skip set mismatch: "
            f"expected {sorted(REQUIRED_API_OBJS)}, "
            f"skipped {sorted(p.name for p in skipped_api)}"
        )

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

    return copied, log_sources, skipped_api


def verify_api_objs_absent(build_dir: Path) -> None:
    present = [
        p.relative_to(build_dir).as_posix()
        for p in build_dir.rglob("*.obj")
        if is_api_dispatch_obj(p.name)
    ]
    if present:
        raise SystemExit(
            "API dispatch objs must not be present after merge (link job must "
            f"recompile them from full OPT_DIM sources): {present}"
        )


def precheck_link_ninja_will_build_api_objs(build_dir: Path) -> None:
    result = subprocess.run(
        ["ninja", "-n"], cwd=build_dir, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(
            f"ninja -n API precheck failed in {build_dir}: {result.stderr.strip()}"
        )
    out = result.stdout
    if "no work to do" in out.lower():
        raise SystemExit(
            "ninja -n reported 'no work to do' on parallel link, but the 3 API "
            "dispatch objs must be compiled from full OPT_DIM sources"
        )
    missing = [name for name in REQUIRED_API_OBJS if name not in out]
    if missing:
        tail = out[-800:] if len(out) > 800 else out
        raise SystemExit(
            f"ninja -n did not plan to build API dispatch objs: {missing}. "
            f"Output tail: {tail!r}"
        )


def verify_api_objs_recompiled(build_dir: Path, stamp: int) -> None:
    for name in sorted(REQUIRED_API_OBJS):
        matches = [p for p in build_dir.rglob(name) if p.name == name]
        if len(matches) != 1:
            raise SystemExit(
                f"Expected exactly one {name} after link ninja, found {len(matches)}"
            )
        obj = matches[0]
        if obj.stat().st_mtime_ns == stamp:
            raise SystemExit(
                f"API dispatch obj {obj.relative_to(build_dir).as_posix()} still "
                "has the prebuilt stamp mtime; link job did not recompile it"
            )
        print(
            f"OK recompiled {obj.relative_to(build_dir).as_posix()}",
            flush=True,
        )


def precheck_merged_objects_clean(
    temp_release: Path, merged_objs: list[Path]
) -> None:
    """Dry-run ninja before the real link build: if any merged prebuilt object
    would be recompiled, fail immediately instead of burning hours on a
    from-scratch compile.  The dry run uses ninja's own dirty logic (log and
    mtime state), so it sees exactly what the real run would do, and it writes
    nothing.  Matching is on the object basename followed by a boundary that
    excludes further path characters, so the `-o <obj>` target matches but the
    source .cu does not; works for torch's description-less command lines and
    for rules that do set a description ending in $out.  The post-build verify
    stays as the second line of defense."""
    patterns = [
        re.compile(re.escape(obj.name) + r"(?![.\w])") for obj in merged_objs
    ]
    result = subprocess.run(
        ["ninja", "-n"], cwd=temp_release, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(
            f"ninja -n precheck failed in {temp_release}: {result.stderr.strip()}"
        )
    dirty: list[str] = []
    for line in result.stdout.splitlines():
        if not line.startswith("["):
            continue
        for obj, pat in zip(merged_objs, patterns):
            if obj.name not in dirty and pat.search(line):
                dirty.append(obj.name)
    if dirty:
        examples = ", ".join(dirty[:5])
        raise SystemExit(
            f"Ninja would rebuild {len(dirty)} of {len(merged_objs)} merged "
            f"prebuilt objects (e.g. {examples}) instead of reusing them: the "
            "merge fast path is not honored. Diagnose with 'ninja -d explain' "
            "in the link build dir (missing .ninja_log entries, command hash "
            "drift between shard and link, or stamp inconsistency)."
        )


def verify_merged_objects_reused(
    temp_release: Path, merged_objs: list[Path], stamp: int
) -> None:
    """Fail hard if ninja rebuilt any merged prebuilt object: a rebuild means
    the merge fast path silently degraded to a from-scratch compile (missing
    .ninja_log entries, command hash drift between shard and link, or
    inconsistent stamping) and the link job's whole point is lost.  A reused
    object keeps the stamped mtime bit-exactly (os.utime ns precision); a
    rebuilt one was rewritten by the compiler, so any mtime drift from the
    stamp means the object was recompiled (comparing `> stamp` would miss
    compiles that finish inside the +1s future-stamp window)."""
    rebuilt = [
        p for p in merged_objs if p.is_file() and p.stat().st_mtime_ns != stamp
    ]
    if rebuilt:
        examples = ", ".join(
            p.relative_to(temp_release).as_posix() for p in rebuilt[:5]
        )
        raise SystemExit(
            f"Ninja rebuilt {len(rebuilt)} of {len(merged_objs)} merged prebuilt "
            f"objects (e.g. {examples}) instead of reusing them: the merge fast "
            "path is not honored. Diagnose with 'ninja -d explain' in the link "
            "build dir (missing .ninja_log entries, command hash drift between "
            "shard and link, or stamp inconsistency)."
        )


def require_parallel_link_force_build_true() -> None:
    value = os.environ.get("FLASH_ATTENTION_FORCE_BUILD", "").strip().upper()
    if value != "TRUE":
        raise SystemExit(
            "Parallel link requires FLASH_ATTENTION_FORCE_BUILD=TRUE "
            "(FALSE would make FA's CachedWheelsCommand try to download an "
            "upstream prebuilt wheel and silently bypass the merged objects; "
            f"got {os.environ.get('FLASH_ATTENTION_FORCE_BUILD')!r})"
        )


def install_patch(staging_root: Path | None, fa_src: Path, primary_dim: str) -> None:
    global _ORIGINAL_RUN_NINJA

    import torch.utils.cpp_extension as cpp_ext

    _ORIGINAL_RUN_NINJA = cpp_ext._run_ninja_build

    def patched_run_ninja(build_directory, *args, **kwargs):
        build_dir = Path(build_directory)
        merged_objs: list[Path] = []
        log_sources: list[Path] | None = None
        if staging_root is not None:
            merged_objs, log_sources, skipped_api = merge_prebuilt_objects(
                staging_root, build_dir, fa_src, primary_dim=primary_dim
            )
            print(
                f"Merged {len(merged_objs)} prebuilt .obj files into {build_dir} "
                f"(skipped {len(skipped_api)} API dispatch objs)",
                flush=True,
            )
            verify_api_objs_absent(build_dir)
        stamp = stamp_prebuilt_objects(build_dir, fa_src, log_sources)
        if staging_root is not None and merged_objs:
            precheck_merged_objects_clean(build_dir, merged_objs)
            precheck_link_ninja_will_build_api_objs(build_dir)
        result = _ORIGINAL_RUN_NINJA(build_directory, *args, **kwargs)
        if staging_root is not None and merged_objs:
            verify_merged_objects_reused(build_dir, merged_objs, stamp)
            verify_api_objs_recompiled(build_dir, stamp)
        return result

    cpp_ext._run_ninja_build = patched_run_ninja


def build_wheel(fa_src: Path, dist_dir: Path, *, verbose: bool = False) -> None:
    dist_dir.mkdir(parents=True, exist_ok=True)
    argv = ["bdist_wheel", "--dist-dir", str(dist_dir)]
    if verbose:
        argv.insert(0, "-v")
    _exec_setup_py(fa_src, argv)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--step",
        choices=["compile", "merge-and-wheel", "wheel"],
        required=True,
        help="compile: build_ext only; wheel: stamp + bdist_wheel; "
        "merge-and-wheel: merge prebuilt objs + bdist_wheel",
    )
    parser.add_argument("--fa-src", type=Path, required=True)
    parser.add_argument("--dist-dir", type=Path)
    parser.add_argument("--staging-root", type=Path)
    parser.add_argument("--primary-dim", default="")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if not args.fa_src.is_dir():
        raise SystemExit(f"FA source missing: {args.fa_src}")

    # Stamp restored prebuilt objects in every mode so the ninja cache actually
    # pays off (setup.py refreshes all fmha_*.cu mtimes on each build_ext).
    if args.step == "compile":
        install_patch(None, args.fa_src, primary_dim="")
        build_ext_only(args.fa_src, verbose=args.verbose)
        return

    if args.dist_dir is None:
        raise SystemExit("--dist-dir is required for step wheel/merge-and-wheel")

    if args.step == "wheel":
        install_patch(None, args.fa_src, primary_dim="")
        build_wheel(args.fa_src, args.dist_dir, verbose=args.verbose)
        return

    if args.staging_root is None or not args.staging_root.is_dir():
        raise SystemExit(f"Staging root missing: {args.staging_root}")

    primary_dim = args.primary_dim.strip()
    if not primary_dim:
        raise SystemExit("--primary-dim is required for step merge-and-wheel")

    require_parallel_link_force_build_true()
    install_patch(args.staging_root, args.fa_src, primary_dim=primary_dim)
    build_wheel(args.fa_src, args.dist_dir, verbose=args.verbose)


if __name__ == "__main__":
    main()
