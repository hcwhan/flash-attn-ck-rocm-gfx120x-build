# flash-attn-ck-rocm-gfx120x-build

**Windows / gfx120x（RDNA4）/ PyTorch 2.12.0+rocm7.14.0 / Python 3.12** FlashAttention 2 CK wheel。版本 pin 见 **`VERSION.lock.json`**。仅 **CI**（`windows-2022` 干净 runner），无本地编译入口。编排脚本为 **TypeScript**（Node 26 + `tsx`；亦可 `npm run fa -- <cmd>`）。

## CI 路径

| Workflow | 链路 |
|----------|------|
| **serial** | `compile-full-and-link-wheel`：A00 bootstrap（含 ninja restore）→ A01 `06.compile` → 看门狗中止时 `07-retry` / 成功 `09.wheel` → `A99`（`10.verify`/`11.publish`） |
| **parallel** | `plan-opt-dim`（A00 轻量）→ `compile-d*`（A00 + A01 + `08.shard`）→ matrix 失败时 `watchdog-retry`（`07-retry`）/ 成功时 `link-wheel`（A00 + `09.wheel` → `A99`） |

### Workflow 步骤顺序（与 pytorch 对齐：`Axx` = workflow 直接 `uses`）

**serial `compile-full-and-link-wheel`**

```
checkout → A00.fa-job-bootstrap（ninja-cache-restore=true, build-variant=serial）
        → A01.fa-build-with-cache（06.compile）
        → 07-retry（看门狗条件）
        → dist/build-caches.json
        → 09.wheel → A99.fa-verify-publish
```

**parallel**

| Job | 步骤 |
|-----|------|
| `plan-opt-dim` | checkout → A00（prep-source=false, setup-toolchain=false）→ `02.plan-opt-dim-matrix` |
| `compile-d{dim}` | checkout → A00（ninja-cache-restore, build-variant=parallel, opt-dim）→ A01 → abort/cache meta + obj artifacts |
| `watchdog-retry` | checkout → A00（prep/toolchain=false）→ `07-retry` |
| `link-wheel` | checkout → A00 → download artifacts → `09.wheel` → A99 |

**Composite 调用树**

```
A00.fa-job-bootstrap
  ├─ A00.1.fa-rocm-toolchain          （setup-toolchain=true）
  ├─ 05.toolchain-fingerprint         （ninja-cache-restore=true）
  └─ A00.2.fa-ninja-cache-restore     （ninja-cache-restore=true）
A01.fa-build-with-cache
  └─ A01.1.fa-post-build-cache        （`hcwhan/actions/cache/save`；verify + cleanup-stale）
A99.fa-verify-publish
```

手动 `workflow_dispatch`；产物相同。setuptools 同进程入口：`build/build-fa-steps.py`。GHA cache 经 **`hcwhan/actions/cache@v1`**（`family-key` + `cache-key` 槽位；实际 key = `cache-key` + UTC 后缀；restore/lookup 取槽位最新 versioned key；save 后 API verify + `cleanup-stale`）。Ninja **family-key**：串行 `fa2-ck-gfx120x-serial-v7`；并行 `fa2-ck-gfx120x-parallel-v7-dim[{ck_opt_dim}]`。**cache-key**：`{family}-lock[{lockHash8}]-bwd[{true|false}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`（`lockHash8` = lock `toolchain`+`flash_attention`+`compile` SHA256 前 8 位；不含 `wheel`/`release` 与 workflow `ck_disable_bwd`；`bwd` = `fmha_bwd`；`msvc`/`rocmClang` = 完整工具链版本号；serial/parallel 互不共用）。Pip **family-key**：`fa-pip-toolchain-v2`；**cache-key**：`fa-pip-toolchain-v2-py[…]-pt[…]-dev[…]-rocm[…]-idx[…]`（`01.config`）。

## 命名约定

| 概念 | 统一名称 | 备注 |
|------|----------|------|
| FA 源码根 | `FA_SRC` / `--fa-src` / composite `fa-src` | 全层一致 |
| parallel staging 根 | `FA_STAGING` / `--staging-root` | artifact `d{dim}` 下载目录；09.wheel parallel link |
| lock CK OPT_DIM | `CK_OPT_DIM` | lock `ck_opt_dim` 逗号列表 |
| workflow CK bwd | `CK_FMHA_DISABLE_BWD` | workflow `ck_disable_bwd`（默认 `false` = 完整编译含 bwd；设为 `true` 跳过 bwd codegen + `FLASHATTENTION_DISABLE_BACKWARD` 推理专用） |
| 第一档 OPT_DIM | `PRIMARY_DIM` / `--primary-dim` / job output `primary-dim` | parallel link 用 |
| 单 shard OPT_DIM | matrix `opt-dim` / CLI `--opt-dim` | parallel compile 单值 |
| 构建模式 | `--build-variant serial\|parallel` | verify / publish / fingerprint 共用 |
| Ninja cache family-key | `cache-family-key` | `05.toolchain-fingerprint` → A00 output；`hcwhan/actions/cache` cleanup 列举范围 |
| Ninja cache key | `cache-key` | A00 output（内嵌 `05.toolchain-fingerprint`）/ manifest `build_caches[].key`（不含 UTC 后缀） |
| Ninja cache exists | `cache-exists` | A00 output / manifest `build_caches[].exists`（lookup 或 restore 探测远端是否有条目） |
| Ninja cache used | `cache-used` | A00 output / manifest `build_caches[].used`（`use_cache=true` 且 restore 命中） |
| Compile cache metadata | `--build-caches` | workflow 写入 JSON（serial 单文件 / parallel 目录）→ 10.verify → manifest `build_caches`（`opt_dim/key/exists/used`） |
| workflow_dispatch 快照 | `dispatch` | manifest 顶层；`10.verify` 从 `MAX_JOBS` / `USE_CACHE` / `CK_FMHA_DISABLE_BWD` / `RETRY_COUNT` 写入 `ninja_workers` / `use_cache` / `ck_disable_bwd` / `retry_count` |
| shard 产物目录 | `SHARD_RELEASE_DIR` | 08.shard 写入；非 GitHub Release |
| wheel local tag | `WHEEL_LOCAL_VERSION` | lock `wheel.wheel_local_version`；wheel 时映射为 upstream `FLASH_ATTN_LOCAL_VERSION` |
| wheel artifact 名 | `WHEEL_ARTIFACT_NAME` | lock `wheel.wheel_artifact_name` |
| release tag 前缀 | `RELEASE_TAG_PREFIX` | lock `release.release_tag_prefix` |
| release title 前缀 | `RELEASE_TITLE_PREFIX` | lock `release.release_title_prefix` |
| FA 相关 env | `FLASH_ATTENTION_*` | repo / commit / force-build 等 |
| Python 包名 | `flash_attn` | wheel / import 名；与本仓库目录名 `flash-attn-*` 有意区分 |

**lock → GITHUB_ENV 映射：** `toolchain.python`→`PYTHON_VERSION`，`toolchain.pytorch`→`PYTORCH_VERSION`，`toolchain.torch_device_extra`→`TORCH_DEVICE_EXTRA`，`toolchain.rocm`→`ROCM_VERSION`，`toolchain.rocm_index`→`ROCM_INDEX`，`compile.ck_opt_dim`→`CK_OPT_DIM`（首档另导出 `PRIMARY_DIM`），`compile.gpu_archs`→`GPU_ARCHS`，`flash_attention.repo`→`FLASH_ATTENTION_REPO`，`flash_attention.build_commit`→`FLASH_ATTENTION_BUILD_COMMIT`，`flash_attention.build_commit_date`→`FLASH_ATTENTION_BUILD_COMMIT_DATE`（另导出 `SOURCE_DATE_EPOCH`），`wheel.wheel_local_version`→`WHEEL_LOCAL_VERSION`，`wheel.wheel_artifact_name`→`WHEEL_ARTIFACT_NAME`，`release.release_tag_prefix`→`RELEASE_TAG_PREFIX`，`release.release_title_prefix`→`RELEASE_TITLE_PREFIX`；`EXPECTED_WHEEL_PATTERN` / `PIP_TOOLCHAIN_CACHE_PREFIX` / `PIP_TOOLCHAIN_CACHE_KEY` 由 `version-lock.ts` 推导。**workflow env（非 lock）：** `ninja_workers`→`MAX_JOBS`，`use_cache`→`USE_CACHE`，`publish_release`→`PUBLISH_RELEASE`，`retry_count`→`RETRY_COUNT`，`ck_disable_bwd`→`CK_FMHA_DISABLE_BWD`（`1`/`0`）。

**缩写对照：** 仓库 `flash-attn-ck-rocm-gfx120x-build`；Ninja cache 前缀 `fa2-ck-gfx120x-*-v7`；Release tag 前缀见 lock `release.release_tag_prefix`（当前 `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x`）；wheel artifact 见 lock `wheel_artifact_name`。HIP 编译目标仅 lock `compile.gpu_archs`（当前 `gfx1200;gfx1201`）。

## 复用入口

同一逻辑只一处实现。改行为时先查下表，勿在 workflow 内联复制 step 块或二次读 lock。

**脚本**

| 入口 | 职责 |
|------|------|
| `scripts/cli.ts` | 统一 CLI（`npx tsx scripts/cli.ts <cmd>` 或 `npm run fa -- <cmd>`） |
| `scripts/lib/version-lock.ts` | **唯一直接读 lock 的 TS 模块**（Zod 校验） |
| `scripts/lib/require-env.ts` | CI env 读取（`requireLockEnv` / `requireGithubActionsEnv`）；缺 env 直接 throw |
| `scripts/lib/rocm-sdk-paths.ts` | ROCm SDK `CoreRoot`/`DevelRoot`（唯一路径发现） |
| `scripts/lib/init-build-env.ts` | numpy + upstream `OPT_DIM`（由 `CK_OPT_DIM`/shard 映射）+ ROCm 编译 env |
| `scripts/lib/watchdog.ts` | 5h deadline 看门狗：`createWatchdog`（3× SIGINT + taskkill；`06.compile` 调用） |
| `scripts/lib/watchdog-abort-meta.ts` | parallel compile abort 元数据读取（`07-retry --abort-meta-dir` / `--cache-meta-dir` / `--all-opt-dims`） |
| `scripts/lib/validate-staging.ts` | parallel link staging 校验（`09.wheel` 前置） |
| `01.config` | 读 lock；`--export-github-env` 写 CI env |
| `02.plan-opt-dim-matrix` | 导出 parallel OPT_DIM matrix（`GITHUB_OUTPUT`：`opt-dims-json` / `primary-dim`） |
| `03.prep` | clone FA 源码（SHA 或 tag）；校验 commit author date 与 lock 一致 |
| `04.patch` | 改 setup.py：`CK_FMHA_DISABLE_BWD=1` 时跳过 bwd + 启用 `FLASHATTENTION_DISABLE_BACKWARD` + 校验 bwd guard；始终 link `spawn` 注入 `/Brepro` |
| `05.toolchain-fingerprint` | MSVC/clang + ninja 指纹；`--build-variant` 输出 `cache-family-key` + `cache-key`（`scripts/lib/ninja-cache-key.ts`） |
| `06.compile` | 任意 `--opt-dim` 编译入口（serial 全量 / parallel 单 dim）；**自 bootstrap 起 5h 看门狗** |
| `07-retry` | 看门狗中断后 dispatch retry（serial：compile job；parallel：独立 `watchdog-retry` job + `--abort-meta-dir` / `--cache-meta-dir` / `--all-opt-dims`） |
| `08.shard` | 校验 compile 产物 .obj；写 `SHARD_RELEASE_DIR` 到 `GITHUB_ENV` |
| `09.wheel` | parallel link staging 校验 + `FLASH_ATTENTION_FORCE_BUILD` + link 脚本 |
| `10.verify` | CI CPU smoke test；wheel 文件名/结构（.pyd 体积 + METADATA）与 torch 运行时校验；读 `--build-caches` 写入 manifest `build_caches` 与 `dispatch`；manifest 顶层含 `fmha_bwd` |
| `11.publish` | 准备 Release 元数据（输出 release-tag / release-title / body-path） |
| `build/build-fa-steps.py` | `--step compile` / `--step wheel` / `--step merge-and-wheel` |
| `test/gpu-smoke-test.py` | 部署前 GPU 校验（gfx120x 真机；CI 不跑；含 fmha_bwd 运行时探测） |

规则：lock 文件只经 `01.config` 读一次并 `--export-github-env`；同 job 其余命令只经 `requireLockEnv` / `requireGithubActionsEnv` 消费 env，**禁止**命令内再调 `readVersionLock` 或 `??` 默认值兜底；`GPU_ARCHS` / `CK_OPT_DIM` / `CK_FMHA_DISABLE_BWD` **禁止**在 patch 内硬编码。ROCm 路径发现只经 `rocm-sdk-paths.ts`；编译/打 wheel 只经 `build-fa-steps.py`。

**依赖方向（强制）**：workflow 直接调用 `scripts/cli.ts` 与官方/第三方 action；`scripts/commands/*` 只 import `scripts/lib/*`。Python 编译逻辑只经 `build/build-fa-steps.py`。禁止薄 one-liner composite。

**Composite**

**Composite 编号**：`Axx` = workflow 直接 `uses`；`Axx.y` = 仅父 composite 内部调用（勿从 workflow 引用）。

| Action | 用途 |
|--------|------|
| `A00.fa-job-bootstrap` | `JOB_START_TIME` + Node/npm + `01.config` + 条件 `03.prep`/`04.patch` + A00.1 + 条件 `05.toolchain-fingerprint` + A00.2 restore；inputs `prep-source` / `setup-toolchain` / `ninja-cache-restore` / `build-variant` / `opt-dim`；outputs `cache-family-key`/`cache-key`/`cache-exists`/`cache-used`（需 job 级 checkout；依赖 env `FA_SRC`/`USE_CACHE`） |
| `A00.1.fa-rocm-toolchain` | Python / MSVC / pip toolchain cache（`PIP_TOOLCHAIN_CACHE_PREFIX` + `PIP_TOOLCHAIN_CACHE_KEY`）/ rocm[devel] / torch[device-*]（仅 A00 调用） |
| `A00.2.fa-ninja-cache-restore` | 恢复 `FA_SRC/build` ninja 增量 cache（`hcwhan/actions/cache/restore` 或 `lookup`；仅 A00 调用） |
| `A01.fa-build-with-cache` | 编译 CLI + 调用 A01.1 post-build cache save |
| `A01.1.fa-post-build-cache` | `hcwhan/actions/cache/save` ninja cache（verify + cleanup-stale 内置） |
| `A99.fa-verify-publish` | `10.verify` + upload wheel artifact + 可选 `11.publish` / GitHub Release；inputs `build-variant` / `build-caches` |

每个 job：**须先** `actions/checkout`，再经 `A00.fa-job-bootstrap`；compile job 设 `ninja-cache-restore=true` 并传 `build-variant`（parallel 另传 `opt-dim`）。随后步骤缺 env / 缺产物直接 throw。

**有意不合并：** compile 阶段 `shard` dim 校验 vs link 阶段 `validate-staging.ts`；四 shard 重复编 shared obj（link 只用 d32）；parallel link-wheel 无 ninja cache；obj artifact 名 `d{dim}` 即 staging 子目录名（勿 normalize）。

## VERSION.lock.json

| 读入逻辑 | 仅人类可读 |
|----------|------------|
| `flash_attention.build_commit`、`flash_attention.build_commit_date`、`flash_attention.repo`、`compile.ck_opt_dim`、`compile.gpu_archs`、`wheel.wheel_artifact_name`、`toolchain.*`、`release.*`… | `flash_attention.min_commit` |

各 compile/link job 内 `03.prep` clone `flash_attention.build_commit` 并校验 author date 与 `flash_attention.build_commit_date` 一致；`SOURCE_DATE_EPOCH` 固定 wheel zip；PE TimeDateStamp 由 patch 注入 link `/Brepro`（内容哈希，serial/parallel 一致）。

## 设计决策

分析 / refactor 时**勿当缺陷**；与本节冲突时以本节为准。

- **不为不可能场景加诊断**
- **干净 runner**：compile 后仅一棵 `temp.win-*`；不为脏 workspace / 人工改目录加兜底。
- **连续 CI 链**：各 compile/link job 内 clone+patch → compile/link → smoke 自动跑完；staging/shard 齐全等流水线检查保留。
- **serial ∥ parallel 产物相同**：共用 link 脚本与 smoke test；parallel link 用 `FLASH_ATTENTION_FORCE_BUILD=TRUE` + prebuilt `.obj` 时间戳 merge；`/Brepro` + `SOURCE_DATE_EPOCH` 使 serial / parallel wheel **byte-identical**。
- **`PRIMARY_DIM`** = lock `ck_opt_dim` 第一档（当前 `32`）；各 shard 均编 shared obj 是预期行为。
- **`ninja_workers` 默认 4**（OOM 改 2）；**`use_cache` 默认 true**（false 时 lookup-only：`cache-exists` 仍探测，`cache-used=false`）
- **ninja cache save**：`use_cache=true` 时 build 非 skipped 即 save；**`use_cache=false` 时仅成功时 save**；`hcwhan/actions/cache` 默认 `cleanup-stale` 在 save/restore 成功后清理同族旧 key；save 内置 API verify（默认最长 180s）
- **看门狗 5h 优雅中断**：A00 第一步写 `JOB_START_TIME`；`watchdog.ts` deadline 到期后写 `ABORT_TRIGGERED`/`COMPILE_COMPLETE=false`，3× SIGINT（1min 间隔；失败则 `ABORT_FORCE_KILLED` + taskkill，**不 save/retry**）；A01.1 save 后 serial 在 compile job 内 `07-retry`；parallel compile 上传 artifact `abort-meta-d{dim}`（文件 `abort-meta/d{dim}.json`），compile matrix **失败**且全部 shard 结束后独立 `watchdog-retry` job 单次 retry；`use_cache=true && retry_count<8`；wheel 等仅在 compile 成功路径（serial 同 job / parallel `link-wheel`）执行（详见 `docs/watchdog-design.md`）
- **全模式 prebuilt obj 两向 stamp** / **link 排除 `fmha_*_api.obj`**：见 `build/build-fa-steps.py` 注释。
- **patch 程序化**（`04.patch`）；`CK_OPT_DIM` / `GPU_ARCHS` / `CK_FMHA_DISABLE_BWD` 只从 env 取
- **workflow 默认 `ck_disable_bwd=false`**（完整包含 fwd + bwd CK FMHA；设为 `true` 时为 ComfyUI 推理专用 wheel）
- **双 gfx12 架构**：`compile.gpu_archs` 为唯一源（当前 `gfx1200;gfx1201`）；经 `GPU_ARCHS` 传给 FA setup.py，无额外 patch。

## 编写规范

1. **单一事实来源** — lock 为准；lock 环境变量仅经 `01.config --export-github-env` 导出一次；`05.toolchain-fingerprint` 可读 lock 算 `lockHash8`（不重复 export）；同 job 其余命令从 `GITHUB_ENV` 取。
2. **信任流水线** — 不为漏传参 / 改目录 / 缺 `GITHUB_ENV`·`GITHUB_OUTPUT` 加 silent fallback；`appendGithubEnv` / `appendGithubOutput` 缺文件即 throw。
3. **最小路径** — 能力一个入口；异常 fail fast（`throw` / `SystemExit`），禁止命令内兜底读 lock、`??` 默认 env、try/catch 吞错继续。
4. **AGENTS 增改须简洁** — 并入现有条目，一句说清；禁长小节、禁复述 README/代码。

**不要添加：** 双源校验、manifest 读回自证、`FA_SKIP_*`、多候选目录排序、git 考古、薄 one-liner 包装、排障用 build-log artifact、lock 只读字段进逻辑、**命令内二次 `readVersionLock`**、**`GITHUB_ENV` 存在却不 export**、**缺 env 时用 `??` 或本地再读 lock 顶上**。

**应当保留：** staging 四目录 + dim kernel + primary shared obj 检查；primary 含 fwd 3 个 `fmha_*_api.obj`（`CK_FMHA_DISABLE_BWD=0` 时再加 `fmha_bwd_api.obj`）；link merge skip + ninja API 重编三重校验；patch before-state；smoke 产物校验；ninja cache family/key 前缀（`NINJA_CACHE_SERIAL_PREFIX` / `NINJA_CACHE_PARALLEL_PREFIX` + parallel `dim[shard]`）+ `lock`/`bwd`/`msvc`/`rocmClang`/`ninja` 槽位。

**cache key 前缀统一定义**：`NINJA_CACHE_SERIAL_PREFIX` / `NINJA_CACHE_PARALLEL_PREFIX`（`ninja-cache-key.ts`）、`PIP_TOOLCHAIN_CACHE_PREFIX`（`pip-cache-key.ts`）经 `05.toolchain-fingerprint` 或 `01.config` 写入 `GITHUB_OUTPUT` / `GITHUB_ENV`，作为 `hcwhan/actions/cache` 的 `family-key`。

## 维护

- 升级 FA：改 `flash_attention.build_commit` 与 `flash_attention.build_commit_date`
- bump PyTorch/ROCm：同步 `wheel.wheel_local_version`、`release.release_tag_prefix`、`wheel.wheel_artifact_name` 等
- 多 GPU 架构：改 lock `compile.gpu_archs`（Windows 分号分隔，如 `gfx1200;gfx1201`）
- 部署前：`python test/gpu-smoke-test.py -w .`（gfx1200/gfx1201 真机，需已 pip install wheel）
