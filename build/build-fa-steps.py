"""同进程 setuptools 构建 flash-attn（compile / wheel / merge-and-wheel）。

由 TS CLI（06.compile / 08.wheel）调用；直接运行须自行设置 OPT_DIM、GPU_ARCHS、ROCM_* 等 env。
"""
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
# 生成的 API dispatch 对象（Windows HIP：fmha_fwd_api.obj 等）按 shard 分片：
# 每个 shard 仅渲染自身 OPT_DIM 的 hdim 分支。若合并 primary shard 的副本会
# 静默丢失其他 dim 的 dispatch，因此 link job 必须基于重新生成的全 dim 源码重编。
# （csrc/flash_attn_ck/ 下 dim 无关 shared obj，如 flash_api.obj 等，仍需从 primary 合并。）
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

# Windows HIP（PyTorch cpp_extension）下 Ninja 的 dirty 判定并非仅看 obj mtime。
# build.ninja 规则既无 deps=gcc 也无 deps=msvc（无 .ninja_deps）；复用需同时满足：
#   1. obj.mtime >= 最新输入（重新生成的 fmha_*.cu、csrc 头文件）
#   2. .ninja_log 存在对应条目、命令 hash 匹配，且 entry.mtime >= 最新输入
# 同一 stamp 值同时写入 obj mtime 与 .ninja_log entry mtime 可满足二者；仅 stamp
# .obj 会违反 2，导致 ninja 重编所有预构建对象。
#
# .ninja_log：v5+ 文本行 "start<TAB>end<TAB>mtime<TAB>output<TAB>hash"，
# log v7 起（ninja >= 1.13）mtime 为纳秒；须保留 header 版本，未知版本会使
# ninja 删除 log 并重编全部。
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
    """root 下最新文件 mtime（纳秒；stamp 含 csrc 头文件）。"""
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
    """单一 stamp 值（整数纳秒）>= ninja 可能比较的所有输入：重新生成的
    build/fmha_*.cu 与 csrc 下头文件（runner 上 freshly clone+patch 的 fa-src）。
    以同一值写入 obj mtime 与 .ninja_log entry mtime；每次 ninja 运行计算一次。
    使用 int 纳秒使 os.utime(ns=...) 与 log 记录 bit-exact 一致（float 秒级
    stamp 漂移足以触发 dirty 判定）。"""
    latest = time.time_ns()
    build_dir = fa_src / "build"
    if build_dir.is_dir():
        for cu in build_dir.glob("fmha_*.cu"):
            latest = max(latest, cu.stat().st_mtime_ns)
    latest = max(latest, _newest_mtime_under(fa_src / "csrc"))
    return latest + 1_000_000_000


def _merge_ninja_log(sources: list[Path], dest: Path, stamp: float) -> int:
    """合并 .ninja_log，将每条 entry 的 mtime 重写为单一 stamp，使 ninja 的
    recorded-mtime 检查（entry.mtime < input）不触发。命令 hash 原样保留：shard
    与 link 以相同 flags 编译相同源码，hash 已与 link job 的 build.ninja 匹配；
    漂移会退化为逐边重编，由构建后校验 loudly fail。重复 output：后者覆盖（与
    ninja loader 按行覆盖 entry 字段一致）。保留 header 版本（v7 = 纳秒 mtime，
    ninja >= 1.13；v5/v6 = 秒）。"""
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
    """双向 stamp：.obj mtime 与 .ninja_log entry mtime 设为同一未来值（>= 最新
    .cu 与 csrc 头文件），使 Windows HIP 上预构建对象通过 ninja dirty 检查。
    默认源为 build 目录已有文件（cache-restore / 普通重编）；link job 传入 shard
    log 并合并进 build 目录。返回所用 stamp 值。"""
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
    """link 前将 shard .obj 与 .ninja_log 合并进 ninja build 目录。

    - Primary shard：除生成的 API dispatch 对象（fmha_*_api.obj）外的全部 .obj——
      后者为 per-shard 分片，须在 link job 基于全 dim 源码重编。
    - 其他 shard：仅 dim 特定 kernel 对象（build/*_d<N>_*）。
    - Ninja log：各 shard 的 .ninja_log（link build 目录为全新，无 log 会重编全部 kernel）。

    返回 (merged obj 路径, ninja log 源, 跳过的 API dispatch 源)。
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
    """真实 link 构建前 dry-run ninja：若任一已合并预构建对象将被重编，立即
    fail，避免数小时从零编译。dry-run 使用 ninja 自身 dirty 逻辑（log 与 mtime
    状态），所见即真实运行，且不写入任何内容。匹配 obj 基名加边界（排除后续路径
    字符），使 `-o <obj>` 目标命中而源 .cu 不命中；适用于 torch 无 description
    的命令行及 description 以 $out 结尾的规则。构建后校验为第二道防线。"""
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
    """若 ninja 重编了任一已合并预构建对象则 hard fail：重编表示 merge 快路径
    静默退化为从零编译（缺 .ninja_log entry、shard/link 命令 hash 漂移或 stamp
    不一致），link job 意义丧失。复用对象保持 stamp mtime bit-exact（os.utime
    纳秒精度）；重编对象被编译器重写，mtime 偏离 stamp 即表示已重编（比较 `> stamp`
    会漏掉在 +1s future-stamp 窗口内完成的编译）。"""
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
        help="compile：build_ext + stamp 预构建 obj；wheel：stamp + bdist_wheel；"
        "merge-and-wheel：merge obj + stamp + bdist_wheel（须 FLASH_ATTENTION_FORCE_BUILD=TRUE）",
    )
    parser.add_argument("--fa-src", type=Path, required=True)
    parser.add_argument("--dist-dir", type=Path)
    parser.add_argument("--staging-root", type=Path)
    parser.add_argument("--primary-dim", default="")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if not args.fa_src.is_dir():
        raise SystemExit(f"FA source missing: {args.fa_src}")

    # 各模式均 stamp 恢复的预构建对象，使 ninja cache 真正生效
    # （setup.py 每次 build_ext 会刷新全部 fmha_*.cu mtime）。
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
