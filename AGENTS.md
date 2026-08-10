# flash-attn-rocm-gfx1201-build

**Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0 / Python 3.12** 推理专用 FlashAttention 2 CK wheel。版本 pin 见 **`VERSION.lock.json`**。仅 **CI**（`windows-2022` 干净 runner），无本地编译入口。编排脚本为 **TypeScript**（Node 26 + `tsx`；亦可 `npm run fa -- <cmd>`）。

## CI 路径

| Workflow | 链路 |
|----------|------|
| **serial** | `compile-full-and-link`（clone+patch → 全量 build_ext → 原地 `bdist_wheel`）→ smoke test |
| **parallel** | `plan-opt-dim` → compile-d32\|d64\|d128\|d256（各 job 内 clone+patch）→ link-wheel → smoke test |

手动 `workflow_dispatch`；产物相同。setuptools 同进程入口：`build/build-fa-steps.py`。Cache 前缀：`serial-v5-{lockHash8}` / `parallel-v5-{lockHash8}-d{dim}`（`lockHash8` = `VERSION.lock.json` SHA256 前 8 位；精确 key，无 `restore-keys`；key 含 `msvc` + `rocmClang` + `pipToolchain` 三段指纹）。

## 命名约定

| 概念 | 统一名称 | 备注 |
|------|----------|------|
| FA 源码根 | `FA_SRC` / `--fa-src` / composite `fa-src` | 全层一致 |
| lock 全量 OPT_DIM | `LOCK_OPT_DIM` | lock `opt_dim` 逗号列表 |
| 第一档 OPT_DIM | `PRIMARY_DIM` / `--primary-dim` / job output `primary-dim` | parallel link 用 |
| 单 shard OPT_DIM | matrix `opt-dim` / CLI `--opt-dim` | parallel compile 单值 |
| 构建模式 | `--build-variant serial\|parallel` | verify / publish / fingerprint 共用 |
| Ninja cache key | `cache-key` | 05.toolchain-fingerprint output / 03.fa-build-with-cache input / manifest `build_caches[].key` |
| Ninja cache hit | `cache-hit` | 03.fa-build-with-cache output / manifest `build_caches[].hit` |
| Compile cache metadata | `--build-caches` | workflow 写入 JSON（serial 单文件 / parallel 目录）→ 09.verify → manifest `build_caches`（仅 `opt_dim/key/hit`） |
| workflow_dispatch 快照 | `dispatch` | manifest 顶层；`09.verify` 从 `MAX_JOBS` / `SKIP_CACHE_RESTORE` 写入 `ninja_workers` / `skip_cache_restore` |
| shard 产物目录 | `SHARD_RELEASE_DIR` | 07.shard 写入；非 GitHub Release |
| wheel local tag | `WHEEL_LOCAL_VERSION` | lock `wheel.wheel_local_version`；wheel 时映射为 upstream `FLASH_ATTN_LOCAL_VERSION` |
| wheel artifact 名 | `WHEEL_ARTIFACT_NAME` | lock `wheel.wheel_artifact_name` |
| release tag 前缀 | `RELEASE_TAG_PREFIX` | lock `release.release_tag_prefix` |
| release title 前缀 | `RELEASE_TITLE_PREFIX` | lock `release.release_title_prefix` |
| FA 相关 env | `FLASH_ATTENTION_*` | repo / commit / force-build 等 |
| Python 包名 | `flash_attn` | wheel / import 名；与本仓库目录名 `flash-attn-*` 有意区分 |

**lock → GITHUB_ENV 映射：** `toolchain.python`→`PYTHON_VERSION`，`toolchain.pytorch`→`PYTORCH_VERSION`，`toolchain.torch_device_extra`→`TORCH_DEVICE_EXTRA`，`toolchain.rocm`→`ROCM_VERSION`，`toolchain.rocm_index`→`ROCM_INDEX`，`compile.opt_dim`→`LOCK_OPT_DIM`（首档另导出 `PRIMARY_DIM`），`compile.gpu_archs`→`GPU_ARCHS`，`flash_attention.repo`→`FLASH_ATTENTION_REPO`，`flash_attention.build_commit`→`FLASH_ATTENTION_BUILD_COMMIT`，`flash_attention.build_commit_date`→`FLASH_ATTENTION_BUILD_COMMIT_DATE`（另导出 `SOURCE_DATE_EPOCH`），`wheel.wheel_local_version`→`WHEEL_LOCAL_VERSION`，`wheel.wheel_artifact_name`→`WHEEL_ARTIFACT_NAME`，`release.release_tag_prefix`→`RELEASE_TAG_PREFIX`，`release.release_title_prefix`→`RELEASE_TITLE_PREFIX`；`EXPECTED_WHEEL_PATTERN` / `PIP_TOOLCHAIN_CACHE_KEY` 由 `version-lock.ts` 推导。

**缩写对照：** 仓库 `flash-attn-rocm-gfx1201-build`；cache/release 前缀 `fa2-ck-gfx1201`；wheel artifact 见 lock `wheel_artifact_name`。

## 复用入口

同一逻辑只一处实现。改行为时先查下表，勿在 workflow 内联复制 step 块或二次读 lock。

**脚本**

| 入口 | 职责 |
|------|------|
| `scripts/cli.ts` | 统一 CLI（`npx tsx scripts/cli.ts <cmd>` 或 `npm run fa -- <cmd>`） |
| `scripts/lib/version-lock.ts` | **唯一直接读 lock 的 TS 模块**（Zod 校验） |
| `scripts/lib/require-env.ts` | CI env 读取（`requireLockEnv` / `requireGithubActionsEnv`）；缺 env 直接 throw |
| `scripts/lib/rocm-sdk-paths.ts` | ROCm SDK `CoreRoot`/`DevelRoot`（唯一路径发现） |
| `scripts/lib/init-build-env.ts` | numpy + `OPT_DIM` + ROCm 编译 env（lock 字段只经 `requireLockEnv`） |
| `01.config` | 读 lock；`--export-github-env` 写 CI env |
| `02.plan-opt-dim-matrix` | 导出 parallel OPT_DIM matrix（`GITHUB_OUTPUT`：`opt-dims-json` / `primary-dim`） |
| `03.prep` | clone FA 源码；校验 commit author date 与 lock 一致 |
| `04.patch` | 改 setup.py：跳过 bwd + 启用 CK 禁用 backward 标志 + link `spawn` 注入 `/Brepro` |
| `05.toolchain-fingerprint` | MSVC/clang + pip 工具链指纹；`--build-variant` 输出 `cache-key`（`scripts/lib/ninja-cache-key.ts`） |
| `06.compile` | 任意 `--opt-dim` 编译入口（serial 全量 / parallel 单 dim） |
| `07.shard` | 校验 compile 产物 .obj；写 `SHARD_RELEASE_DIR` 到 `GITHUB_ENV` |
| `08.wheel` | 设 `FLASH_ATTENTION_FORCE_BUILD`，调 link 脚本 |
| `09.verify` | CI CPU smoke test；读 `--build-caches` 写入 manifest `build_caches` 与 `dispatch` |
| `10.publish` | 准备 Release 元数据（workflow 内联 + `softprops/action-gh-release`） |
| `build/build-fa-steps.py` | `--step compile` / `--step wheel` / `--step merge-and-wheel` |
| `test/gpu-smoke-test.py` | 部署前 GPU 校验（gfx1201 真机；CI 不跑） |

规则：lock 文件只经 `01.config` 读一次并 `--export-github-env`；同 job 其余命令只经 `requireLockEnv` / `requireGithubActionsEnv` 消费 env，**禁止**命令内再调 `readVersionLock` 或 `??` 默认值兜底。ROCm 路径发现只经 `rocm-sdk-paths.ts`；编译/打 wheel 只经 `build-fa-steps.py`。

**依赖方向（强制）**：workflow 直接调用 `scripts/cli.ts` 与官方/第三方 action；`scripts/commands/*` 只 import `scripts/lib/*`。Python 编译逻辑只经 `build/build-fa-steps.py`。禁止薄 one-liner composite。

**Composite**（仅多步编排）

| Action | 用途 |
|--------|------|
| `01.fa-rocm-toolchain` | 安装 Python / MSVC / PyTorch / ROCm（pip toolchain cache：`PIP_TOOLCHAIN_CACHE_KEY`） |
| `02.fa-ninja-cache-restore` | 恢复 ninja 增量缓存 |
| `03.fa-build-with-cache` | 02+编译+04 带缓存构建 |
| `04.fa-ninja-cache-save` | 保存 ninja 增量缓存 |

每个 job：`actions/setup-node@v7`（Node 26）+ `npm ci`，然后**必须**跑 `01.config --export-github-env`（`GITHUB_ENV` 已设时不得省略 `--export-github-env`）；随后步骤缺 env / 缺产物直接 throw。

**有意不合并：** compile 阶段 `shard` dim 校验 vs link 阶段 `validate_staging`；四 shard 重复编 shared obj（link 只用 d32）；parallel link-wheel 无 ninja cache；obj artifact 名 `d{dim}` 即 staging 子目录名（勿 normalize）。

## VERSION.lock.json

| 读入逻辑 | 仅人类可读 |
|----------|------------|
| `flash_attention.build_commit`、`flash_attention.build_commit_date`、`flash_attention.repo`、`compile.opt_dim`、`compile.gpu_archs`、`wheel.wheel_artifact_name`、`toolchain.*`、`release.*`… | `flash_attention.min_commit` |

各 compile/link job 内 `03.prep` clone `flash_attention.build_commit` 并校验 author date 与 `flash_attention.build_commit_date` 一致；`SOURCE_DATE_EPOCH` 固定 wheel zip；PE TimeDateStamp 由 patch 注入 link `/Brepro`（内容哈希，serial/parallel 一致）。

## 设计决策

分析 / refactor 时**勿当缺陷**；与本节冲突时以本节为准。

- **不为不可能场景加诊断**
- **干净 runner**：compile 后仅一棵 `temp.win-*`；不为脏 workspace / 人工改目录加兜底。
- **连续 CI 链**：各 compile/link job 内 clone+patch → compile/link → smoke 自动跑完；staging/shard 齐全等流水线检查保留。
- **serial ∥ parallel 产物相同**：共用 link 脚本与 smoke test；parallel link 用 `FLASH_ATTENTION_FORCE_BUILD=TRUE` + prebuilt `.obj` 时间戳 merge；`/Brepro` + `SOURCE_DATE_EPOCH` 使 serial / parallel wheel **byte-identical**。
- **`PRIMARY_DIM`** = lock `opt_dim` 第一档（当前 `32`）；各 shard 均编 shared obj 是预期行为。
- **`ninja_workers` 默认 4**（OOM 改 2）；**`skip_cache_restore` 默认 false**（命中时构建成功后先删旧缓存再重存刷新，构建失败保留旧缓存；设为 true 时 lookup-only 探测）。
- **全模式 prebuilt obj 两向 stamp** / **link 排除 `fmha_*_api.obj`**：见 `build/build-fa-steps.py` 注释。

## 编写规范

1. **单一事实来源** — lock 为准；每 job 仅 `01.config` 读 lock 一次，其余从 `GITHUB_ENV` 取。
2. **信任流水线** — 不为漏传参 / 改目录 / 缺 `GITHUB_ENV`·`GITHUB_OUTPUT` 加 silent fallback；`appendGithubEnv` / `appendGithubOutput` 缺文件即 throw。
3. **最小路径** — 能力一个入口；异常 fail fast（`throw` / `SystemExit`），禁止命令内兜底读 lock、`??` 默认 env、try/catch 吞错继续。
4. **AGENTS 增改须简洁** — 并入现有条目，一句说清；禁长小节、禁复述 README/代码。

**不要添加：** 双源校验、manifest 读回自证、`FA_SKIP_*`、多候选目录排序、git 考古、薄 one-liner 包装、排障用 build-log artifact、lock 只读字段进逻辑、**命令内二次 `readVersionLock`**、**`GITHUB_ENV` 存在却不 export**、**缺 env 时用 `??` 或本地再读 lock 顶上**。

**应当保留：** staging 四目录 + dim kernel + primary shared obj 检查；primary 含 3 个 `fmha_*_api.obj`；link merge skip + ninja API 重编三重校验；patch before-state；smoke 产物校验；cache 精确 key（`serial-v5-{lockHash8}` / `parallel-v5-{lockHash8}-d{dim}` + `msvc`/`rocmClang`/`pipToolchain` 指纹）。

## 维护

- 升级 FA：改 `flash_attention.build_commit` 与 `flash_attention.build_commit_date`
- bump PyTorch/ROCm：同步 `wheel.wheel_local_version`、`release.release_tag_prefix`、`wheel.wheel_artifact_name` 等
- 部署前：`python test/gpu-smoke-test.py -w .`（gfx1201 真机，需已 pip install wheel）
