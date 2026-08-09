# flash-attn-rocm-gfx1201-build

**Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0 / Python 3.12** 推理专用 FlashAttention 2 CK wheel。版本 pin 见 **`VERSION.lock.json`**。仅 **CI**（`windows-2022` 干净 runner），无本地编译入口。

## CI 路径

| Workflow | 链路 |
|----------|------|
| **serial** | prep → 全量 build_ext → 原地 `bdist_wheel`（同 job 同目录，stamp 跳过重编）→ smoke test |
| **parallel** | prep → compile-d32\|d64\|d128\|d256 → link-wheel → smoke test |

手动 `workflow_dispatch`；产物相同。setuptools 同进程入口：`base/build-fa-steps.py`。Cache 前缀：`serial-v4` / `parallel-v4-d{dim}`（精确 key，无 `restore-keys`；key 含仓库 commit-id + 工具链指纹（MSVC+clang）+ pip 工具链指纹）。

## 复用入口

同一逻辑只一处实现。改行为时先查下表，勿在 workflow 内联复制 step 块或二次读 lock。

**脚本**

| 入口 | 职责 |
|------|------|
| `read-version-lock.ps1`（base 目录） | **唯一直接读 lock 的 PS1**；`$script:` 变量 + `VersionLockVars` 暴露 |
| `1.config - read-version-lock.ps1` | 调 base 版 + `-ExportToGitHubEnv` 写 CI env（`01.fa-read-version-lock` 专用） |
| `2.prep - prep-flash-attention.ps1` | clone FA 源码（读 lock 取 repo/commit） |
| `3.patch - patch-fa-inference.ps1` | 改 setup.py：跳过 bwd + 启用 CK 禁用 backward 标志（`02.fa-prep-src` 第二步调） |
| `get-build-paths.ps1`（base 目录） | `BuildRoot`；`-LoadVersionLock` 供测试脚本 |
| `get-rocm-sdk-paths.ps1`（base 目录） | 输出 `CoreRoot`/`DevelRoot`（init-fa-build-env 与 msvc 指纹共用；唯一 ROCm 路径发现） |
| `4.sdk - get-rocm-sdk-paths.ps1` | 调 base 版（`06.fa-toolchain-fingerprint` 专用适配） |
| `init-fa-build-env.ps1`（base 目录） | numpy + `OPT_DIM` + ROCm 编译 env（内部 dot-source lock） |
| `build-fa-steps.py`（base 目录） | `--step compile` / `--step wheel` / `--step merge-and-wheel`（parallel link+staging 校验） |
| `5.compile - compile-opt-dim.ps1` | 任意 `-OptDim` 编译入口（serial 全量 / parallel 单 dim） |
| `6.shard - validate-shard.ps1` | 校验 compile 产物 .obj（含 `_d{dim}_` kernel）并输出 `RELEASE_DIR`（parallel 专用；workflow 内单独调） |
| `7.wheel - build-bdist-wheel.ps1` | 设 `FLASH_ATTENTION_FORCE_BUILD`，调 link 脚本 |
| `8.verify - wheel-smoke-test.ps1` | CI CPU smoke test（wheel 结构 / pip 安装 / import） |
| `9.publish - github-release.ps1` | 准备 Release 元数据（tag / body；`11.fa-upload-release` 调用） |
| `test/gpu-smoke-test.ps1` | 部署前 GPU 校验（gfx1201 真机；fwd + kvcache，CI 不跑） |

规则：lock 经 `read-version-lock.ps1`（唯一；或 get-build-paths/init-fa-build-env 间接）；ROCm 路径发现只经 `get-rocm-sdk-paths.ps1`；编译/打 wheel 只经 `build-fa-steps.py`。

**依赖方向（强制）**：action/workflow 只能引用 `build/`；`build/` 只能引用 `base/`；`base/` 只能引用 `base/`（同层）。新增引用违反此方向即拒绝。base 共享工具（read-version-lock / get-rocm-sdk-paths）需经 build 适配层（`1.config` / `4.sdk`）暴露给 action。

**Composite**（封装重复 step 序列；单行转发脚本仍禁止）

| Action | 用途 |
|--------|------|
| `00.fa-plan-opt-dim-matrix` | 规划 parallel OPT_DIM 矩阵 |
| `01.fa-read-version-lock` | 读 lock 注入 CI 环境 |
| `02.fa-prep-src` | 克隆、打补丁、上传源码 |
| `03.fa-rocm-toolchain` | 安装 Python / MSVC / PyTorch / ROCm |
| `04.fa-download-src` | 下载 prep 源码包 |
| `05.fa-job-bootstrap` | 01+03+04 复合引导 |
| `06.fa-toolchain-fingerprint` | 生成工具链指纹（缓存 key） |
| `07.fa-ninja-cache-restore` | 恢复 ninja 增量缓存 |
| `08.fa-build-with-cache` | 07+编译+09 带缓存构建 |
| `09.fa-ninja-cache-save` | 保存 ninja 增量缓存 |
| `10.fa-smoke-test-upload-wheel` | 冒烟测试并上传 wheel |
| `11.fa-upload-release` | 上传 GitHub Release（tag = `{prefix}-{variant}-build{N}`，variant 由 workflow 传入） |

缓存 key 含仓库 commit-id（覆盖 build 脚本/lock/action 全部仓内输入）+ 工具链指纹（MSVC+clang，镜像更新）+ pip 工具链指纹（pip/setuptools/wheel/ninja/packaging/psutil，运行时 `pip freeze` 观测）。Workflow `env`：`MAX_JOBS`/`FA_SRC`/`FA_ARTIFACT`/`FA_STAGING`/`SKIP_CACHE_RESTORE`。

**有意不合并：** compile 阶段 `validate-shard.ps1` dim 校验 vs link 阶段 `validate_staging`；四 shard 重复编 shared obj（link 只用 d32）；parallel link-wheel 无 ninja cache；obj artifact 名 `d{dim}` 即 staging 子目录名（勿 normalize）。

## VERSION.lock.json

| 读入逻辑 | 仅人类可读 |
|----------|------------|
| `flash_attention_build_commit`、`flash_attention_repo`、`opt_dim`、`expected_wheel_pattern`、`wheel_artifact_name`、`python`、`pytorch`、`hip`、`gpu_archs`… | `flash_attention_min_commit`、`flash_attention_build_commit_date` |

prep clone `flash_attention_build_commit`；不参与逻辑的字段不得进脚本分支。

## 设计决策

分析 / refactor 时**勿当缺陷**；与本节冲突时以本节为准。

- **不为不可能场景加诊断**
- **干净 runner**：compile 后仅一棵 `temp.win-*`；不为脏 workspace / 人工改目录加兜底。
- **连续 CI 链**：prep → compile/link → smoke 自动跑完；staging/shard 齐全等流水线检查保留。
- **serial ∥ parallel 产物相同**：共用 link 脚本与 smoke test；parallel link 用 `FLASH_ATTENTION_FORCE_BUILD=TRUE`（避免 FA `CachedWheelsCommand` 下载上游 wheel 短路）+ prebuilt `.obj` 时间戳 merge。
- **`PRIMARY_OPT_DIM`** = lock `opt_dim` 第一档（当前 `32`）；各 shard 均编 shared obj 是预期行为。
- **`ninja_workers` 默认 4**（OOM 改 2）；**`skip_cache_restore` 默认 false**（命中时构建成功后先删旧缓存再重存刷新，构建失败保留旧缓存；设为 true 时 lookup-only 探测）。
- **全模式 prebuilt obj 两向 stamp**：compile/serial 恢复缓存后、link 合并后，用单一未来时间戳（`max(now, 最新 fmha_*.cu, 最新 csrc 头文件)+1s`）同时写 `.obj` mtime 与 `.ninja_log` 条目 mtime（Windows HIP 无 `deps=` 规则、不生成 `.ninja_deps`；只 stamp obj 会触发 ninja `entry<input` 脏检查，缓存与 merge 均全量重编；`.ninja_log` 版本头必须保留，否则 ninja unlink 日志全量重编）。link 合并四 shard 的 `.ninja_log`（上传需 `include-hidden-files: true`），真实 ninja 运行前先 `ninja -n` dry-run 预检 merged obj 是否会被重编，违者立即退出；运行后再校验 merged obj mtime，违者报错退出。
- **link 排除 `fmha_*_api.obj`**（Windows HIP 产物名，非 `.cu.obj`）：各 shard 分发表只含本 shard hdim；merge 必须 skip 这 3 个 obj 并在 link ninja 重编（`verify_api_objs_absent` → `precheck_link_ninja_will_build_api_objs` → `verify_api_objs_recompiled`）。`validate_staging` 断言 primary shard 含且仅含这 3 个 api obj。

## 编写规范

1. **单一事实来源** — lock 为准，不交叉验算同一含义。
2. **信任流水线** — 不为漏传参 / 改目录加 silent fallback。
3. **最小路径** — 能力一个入口；fail fast（`throw` / `SystemExit`）。
4. **AGENTS 增改须简洁** — 并入现有条目，一句说清；禁长小节、禁复述 README/代码。

**不要添加：** 双源校验、manifest 读回自证、`FA_SKIP_*`、多候选目录排序、git 考古、薄 one-liner 包装、排障用 build-log artifact、lock 只读字段进逻辑。

**应当保留：** staging 四目录 + dim kernel + primary shared obj 检查；primary 含 3 个 `fmha_*_api.obj`；link merge skip + ninja API 重编三重校验；patch before-state（含 mha_bwd guard 前置校验）；smoke 产物校验（.pyd 体积 / CXX11_ABI / dim 符号 / METADATA）；cache 精确 key 含仓库 commit-id。

**改代码前：** 连续 CI 是否必发生？信息是否已在 lock/env/上游 output？能否复用上表入口？能删则删。

## 维护

- 升级 FA：改 `flash_attention_build_commit`
- bump PyTorch/ROCm：同步 `expected_wheel_pattern`、`wheel_local_version` 等
- 部署前：`test/gpu-smoke-test.ps1`（gfx1201 真机，需已 pip install wheel）
