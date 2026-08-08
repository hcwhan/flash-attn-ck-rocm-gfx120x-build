"""Build flash-attn via in-process setuptools (compile / wheel / merge-and-wheel)."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

_ORIGINAL_RUN_NINJA = None

DIM_PATTERN = re.compile(r"_d(\d+)_")
# Generated API dispatch objects (fmha_fwd_api.cu.obj, fmha_fwd_appendkv_api.cu.obj,
# fmha_fwd_splitkv_api.cu.obj) are per-shard partial: each shard only renders the
# hdim cases for its own OPT_DIM. Merging the primary shard's copy would silently
# drop the other dims' dispatch, so these must always be recompiled in the link job
# from the regenerated all-dim sources. (csrc/flash_attn_ck/flash_api.cu.obj is a
# fixed dim-independent source and must still be merged.)
API_OBJ_PATTERN = re.compile(r"^fmha_.*_api\.cu\.obj$")

# Ninja's dirty check for an output is NOT mtime-only.  With torch's rules
# (depfile = $out.d, deps = gcc, restat = 1) a prebuilt object is reused only
# when ALL of these hold (src/graph.cc RecomputeOutputDirty + dep_loader.cc
# LoadDepsFromLog):
#   1. a .ninja_deps record exists for the output and obj.mtime <= deps.mtime
#   2. obj.mtime >= newest input (regenerated fmha_*.cu, depfile headers from
#      the prep artifact)
#   3. a .ninja_log entry exists, its command hash matches, and
#      entry.mtime >= newest input
# A single stamp value applied to obj mtimes AND the deps/log records satisfies
# all three; stamping only the .obj (as done before) violates 1 and 3 and makes
# ninja rebuild every prebuilt object.
#
# .ninja_log: v5+ text lines "start<TAB>end<TAB>mtime<TAB>output<TAB>hash",
# mtime in nanoseconds since log v7 (ninja >= 1.13); the header version must be
# preserved, an unknown version makes ninja unlink the log and rebuild all.
# .ninja_deps: v4 binary; records are 4-byte-size-prefixed, high bit = deps
# record.  Path records carry the path padded to 4 bytes plus a ~id checksum;
# deps records carry out_id + 64-bit mtime + dep ids.  Node ids are positional
# (first-seen order per file), so shard files have independent id spaces and
# must be re-emitted with a rebuilt unified table, not concatenated.
_LOG_HEADER_RE = re.compile(r"^# ninja log v(\d+)$")
_DEPS_HEADER = b"# ninjadeps\n"
_DEPS_VERSION = 4


def load_opt_dims() -> tuple[str, ...]:
    opt_dim = os.environ.get("OPT_DIM", "").strip()
    if not opt_dim:
        raise SystemExit("OPT_DIM env is required")
    if "," not in opt_dim:
        raise SystemExit(
            f"OPT_DIM must be comma-separated tiers for link, got {opt_dim!r}"
        )
    dims = tuple(part.strip() for part in opt_dim.split(",") if part.strip())
    if not dims:
        raise SystemExit("OPT_DIM is empty")
    return dims


def resolve_primary_dim(primary_dim: str, expected_dims: tuple[str, ...]) -> str:
    if not primary_dim:
        raise SystemExit("primary_dim is required")
    if primary_dim not in expected_dims:
        raise SystemExit(
            f"primary_dim {primary_dim} is not in OPT_DIM list: {', '.join(expected_dims)}"
        )
    return primary_dim


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


def validate_staging(
    staging_root: Path,
    *,
    expected_dims: tuple[str, ...],
    primary_dim: str,
) -> None:
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

        dim_specific = [obj for obj in objs if DIM_PATTERN.search(obj.name) and f"_d{dim}_" in obj.name]
        if not dim_specific:
            raise SystemExit(f"Shard d{dim} has no *_d{dim}_* kernel objects")

        for fname in (".ninja_log", ".ninja_deps"):
            if not (shard / fname).is_file():
                raise SystemExit(
                    f"Shard d{dim} missing {fname} (upload-artifact must set "
                    "include-hidden-files: true)"
                )

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


def _newest_mtime_under(root: Path) -> int:
    """Newest file mtime (ns) under root (depfile headers live under fa_src/csrc)."""
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
    against: the regenerated build/fmha_*.cu and the depfile headers under csrc
    (freshly extracted from the prep artifact on the runner).  Applied to obj
    mtimes, .ninja_deps record mtimes and .ninja_log entry mtimes in one
    consistent value; computed once per ninja run (a later re-stamp with a
    larger value would break obj <= deps again).  The value is an int ns so
    os.utime(ns=...) and the deps/log records agree bit-exactly (a float
    seconds stamp drifts a few ns between the file mtime and the records,
    which is enough to trip ninja's `obj.mtime > deps.mtime` check)."""
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


def _parse_ninja_deps(path: Path) -> list[tuple[str, list[str]]]:
    """Parse a v4 binary .ninja_deps file into (output, [dep paths]) records,
    resolving the file's own positional id space to paths."""
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise SystemExit(f"Cannot read ninja deps {path}: {exc}")
    if not data.startswith(_DEPS_HEADER):
        raise SystemExit(f"{path}: missing '# ninjadeps' header")
    (version,) = struct.unpack_from("<I", data, len(_DEPS_HEADER))
    if version != _DEPS_VERSION:
        raise SystemExit(f"{path}: unsupported ninja deps version {version}")
    pos = len(_DEPS_HEADER) + 4
    node_paths: list[str] = []
    records: list[tuple[str, list[str]]] = []
    n = len(data)
    while pos + 4 <= n:
        (size,) = struct.unpack_from("<I", data, pos)
        pos += 4
        is_deps = bool(size & 0x80000000)
        size &= 0x7FFFFFFF
        if pos + size > n:
            raise SystemExit(f"{path}: truncated deps record at offset {pos - 4}")
        blob = data[pos : pos + size]
        pos += size
        if is_deps:
            if size < 12 or size % 4 != 0:
                raise SystemExit(f"{path}: malformed deps record")
            out_id, mtime_lo, mtime_hi = struct.unpack_from("<III", blob, 0)
            if out_id >= len(node_paths):
                raise SystemExit(f"{path}: deps record out_id {out_id} has no path record")
            dep_count = size // 4 - 3
            dep_ids = struct.unpack_from(f"<{dep_count}I", blob, 12)
            deps = []
            for i in dep_ids:
                if i >= len(node_paths):
                    raise SystemExit(f"{path}: dep id {i} has no path record")
                deps.append(node_paths[i])
            records.append((node_paths[out_id], deps))
        else:
            raw = blob[:-4]  # trailing ~id checksum
            while raw and raw[-1] == 0:
                raw = raw[:-1]
            node_paths.append(raw.decode("utf-8", errors="replace"))
    return records


def _merge_ninja_deps(
    sources: list[Path], dest: Path, stamp: float, *, mtime_ns: bool
) -> int:
    """Merge shard .ninja_deps files into one file with a unified id table.

    Each shard file has its own positional id space, so byte-wise
    concatenation would resolve ids to the wrong paths; records are parsed,
    deduped by output (last source wins) and re-emitted with a rebuilt table
    (path records first, then deps records, each with the ~id checksum ninja
    validates).  Record mtimes are rewritten to the same stamp value as the
    .obj files, otherwise ninja's `obj.mtime > deps.mtime` check fires and
    every prebuilt object is rebuilt."""
    merged: dict[str, list[str]] = {}
    for src in sources:
        for out, deps in _parse_ninja_deps(src):
            merged[out] = deps

    paths: dict[str, int] = {}
    order: list[str] = []
    for out, deps in merged.items():
        for p in (out, *deps):
            if p not in paths:
                paths[p] = len(order)
                order.append(p)

    mtime = stamp if mtime_ns else stamp // 1_000_000_000
    with open(dest, "wb") as fh:
        fh.write(_DEPS_HEADER)
        fh.write(struct.pack("<I", _DEPS_VERSION))
        for pid, p in enumerate(order):
            raw = p.encode("utf-8")
            pad = (4 - len(raw) % 4) % 4
            payload = raw + b"\0" * pad + struct.pack("<I", (~pid) & 0xFFFFFFFF)
            fh.write(struct.pack("<I", len(payload)))
            fh.write(payload)
        for out, deps in merged.items():
            dep_ids = [paths[d] for d in deps]
            fh.write(struct.pack("<I", (12 + 4 * len(dep_ids)) | 0x80000000))
            fh.write(
                struct.pack(
                    "<III",
                    paths[out],
                    mtime & 0xFFFFFFFF,
                    (mtime >> 32) & 0xFFFFFFFF,
                )
            )
            for i in dep_ids:
                fh.write(struct.pack("<I", i))
    return len(merged)


def stamp_prebuilt_objects(
    temp_release: Path,
    fa_src: Path,
    log_sources: list[Path] | None = None,
    deps_sources: list[Path] | None = None,
) -> float:
    """Three-way stamp: .obj mtimes, .ninja_deps record mtimes and .ninja_log
    entry mtimes all get ONE future value (>= newest .cu and csrc header), so
    ninja's dirty checks all pass for prebuilt objects.  Sources default to
    the files already in the build dir (cache-restore / plain rebuild); the
    link job passes the shard files, which are merged into the build dir.
    Returns the stamp value used."""
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
    log_version = 0
    if log_srcs:
        log_version = _merge_ninja_log(log_srcs, log_dest, stamp)

    deps_dest = temp_release / ".ninja_deps"
    deps_srcs = (
        deps_sources
        if deps_sources is not None
        else ([deps_dest] if deps_dest.is_file() else [])
    )
    if deps_srcs:
        # deps record mtimes follow the same unit as the log's mtime column;
        # unknown version (no log) assumes ns, matching the pip ninja (>= 1.13)
        # this pipeline installs.
        _merge_ninja_deps(
            deps_srcs, deps_dest, stamp, mtime_ns=log_version == 0 or log_version >= 7
        )

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
    """Merge shard .obj files and their .ninja_log/.ninja_deps into the ninja
    build dir before the link build.

    - Primary shard: every .obj except the generated API dispatch objects
      (fmha_*_api.cu.obj) -- those are per-shard partial and must be recompiled
      in the link job from the regenerated all-dim sources.
    - Other shards: dim-specific kernel objects only (build/*_d<N>_*).
    - Ninja logs: every shard's .ninja_log/.ninja_deps (the link build dir is
      fresh, so without them ninja would rebuild all 924 kernels).

    Returns (merged obj paths, ninja log sources, ninja deps sources).
    """
    primary_dir = staging_root / f"d{primary_dim}"
    if not primary_dir.is_dir():
        raise SystemExit(f"Primary staging dir missing: {primary_dir}")

    staging_dirs = sorted(p for p in staging_root.iterdir() if p.is_dir())
    temp_release.mkdir(parents=True, exist_ok=True)
    copied: list[Path] = []
    log_sources: list[Path] = []
    deps_sources: list[Path] = []

    for staging in staging_dirs:
        log_file = staging / ".ninja_log"
        deps_file = staging / ".ninja_deps"
        if not log_file.is_file() or not deps_file.is_file():
            raise SystemExit(
                f"Staging dir {staging} missing .ninja_log/.ninja_deps "
                "(upload-artifact must set include-hidden-files: true)"
            )
        log_sources.append(log_file)
        deps_sources.append(deps_file)

    def copy_obj(src: Path, rel: Path) -> None:
        dest = temp_release / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        copied.append(dest)

    for obj in primary_dir.rglob("*.obj"):
        if API_OBJ_PATTERN.match(obj.name):
            print(
                f"  skip {obj.relative_to(primary_dir).as_posix()} (recompiled in link job)",
                flush=True,
            )
            continue
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

    return copied, log_sources, deps_sources


def precheck_merged_objects_clean(
    temp_release: Path, merged_objs: list[Path]
) -> None:
    """Dry-run ninja before the real link build: if any merged prebuilt object
    would be recompiled, fail immediately instead of burning hours on a
    from-scratch compile.  The dry run uses ninja's own dirty logic (log,
    deps and mtime state), so it sees exactly what the real run would do, and
    it writes nothing.  Matching is on the object basename followed by a
    boundary that excludes further path characters, so the `-o <obj>` target
    matches but the `$out.d` depfile occurrence (obj + ".d") and the source
    .cu do not; works for torch's description-less command lines and for
    rules that do set a description ending in $out.  The post-build verify
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
            "in the link build dir (missing .ninja_log/.ninja_deps entries, "
            "command hash drift between shard and link, or stamp inconsistency)."
        )


def verify_merged_objects_reused(
    temp_release: Path, merged_objs: list[Path], stamp: int
) -> None:
    """Fail hard if ninja rebuilt any merged prebuilt object: a rebuild means
    the merge fast path silently degraded to a from-scratch compile (missing
    .ninja_log/.ninja_deps entries, command hash drift between shard and link,
    or inconsistent stamping) and the link job's whole point is lost.  A
    reused object keeps the stamped mtime bit-exactly (os.utime ns precision);
    a rebuilt one was rewritten by the compiler, so any mtime drift from the
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
            "build dir (missing .ninja_log/.ninja_deps entries, command hash "
            "drift between shard and link, or stamp inconsistency)."
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
        deps_sources: list[Path] | None = None
        if staging_root is not None:
            merged_objs, log_sources, deps_sources = merge_prebuilt_objects(
                staging_root, build_dir, fa_src, primary_dim=primary_dim
            )
            print(
                f"Merged {len(merged_objs)} prebuilt .obj files into {build_dir}",
                flush=True,
            )
        stamp = stamp_prebuilt_objects(build_dir, fa_src, log_sources, deps_sources)
        if staging_root is not None and merged_objs:
            precheck_merged_objects_clean(build_dir, merged_objs)
        result = _ORIGINAL_RUN_NINJA(build_directory, *args, **kwargs)
        if staging_root is not None and merged_objs:
            verify_merged_objects_reused(build_dir, merged_objs, stamp)
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
        "merge-and-wheel: staging validation + merge prebuilt objs + bdist_wheel",
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

    expected_dims = load_opt_dims()
    primary_dim = resolve_primary_dim(args.primary_dim, expected_dims)

    validate_staging(
        args.staging_root,
        expected_dims=expected_dims,
        primary_dim=primary_dim,
    )
    require_parallel_link_force_build_true()
    install_patch(args.staging_root, args.fa_src, primary_dim=primary_dim)
    build_wheel(args.fa_src, args.dist_dir, verbose=args.verbose)


if __name__ == "__main__":
    main()
