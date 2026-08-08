# flash-attn-rocm-gfx1201-build

为 **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0 / Python 3.12** 构建 **FlashAttention 2 CK 后端**推理专用 wheel。版本 pin 见 **`VERSION.lock.json`**。

## 目录结构

```
flash-attn-rocm-gfx1201-build/
  VERSION.lock.json
  build/
    config/       read-version-lock.ps1
    prep/         prep-flash-attention.ps1
    patch/        patch-fa-inference.ps1
    env/          init-fa-build-env.ps1, setup-rocm-env.ps1
    compile/      compile-opt-dim.ps1, link_parallel_wheel.py
    wheel/        build-bdist-wheel.ps1
    test/         smoke-test-wheel.ps1, gpu-smoke-test.ps1
    common/       paths.ps1, get-fa-release-dir.ps1
  .github/
    workflows/build-fa2-ck-gfx1201-serial.yml
    workflows/build-fa2-ck-gfx1201-parallel.yml
    actions/      fa-prep-artifact, fa-rocm-toolchain, fa-ninja-cache-*, …
```

## CI 路径

| Workflow | 链路 |
|----------|------|
| **serial** | `prep` → 单 job 全量 `bdist_wheel` → smoke test |
| **parallel** | `prep` → `compile-d32\|d64\|d128\|d256` → `link-wheel` → smoke test |

两者均为 **workflow_dispatch** 手动触发；产物相同。

- **setuptools 入口**：同进程 `compile/link_parallel_wheel.py`
- **串行**：无 staging，直接 `bdist_wheel`（全量 `OPT_DIM`）
- **并行 link**：`FLASH_ATTENTION_FORCE_BUILD=FALSE` + prebuilt `.obj` 时间戳 merge

Cache key 互相隔离：串行 `serial-v3`，并行 `parallel-v3-d{dim}`。

## VERSION.lock.json

| 字段 | 脚本/CI 是否读取 |
|------|------------------|
| `flash_attention_build_commit` | 是 — clone 目标 |
| `flash_attention_repo` | 是 |
| `opt_dim` | 是 — matrix 与 OPT_DIM |
| `expected_wheel_pattern` | 是 — smoke test |
| `wheel_artifact_name` | 是 |
| `pytorch` / `python` / `hip` / `gpu_archs` / … | 是 — toolchain |
| `flash_attention_min_commit` | **否** — 人类可读参考 |
| `flash_attention_build_commit_date` | **否** — 人类可读参考 |

## 设计决策

以下均为**有意为之**的约束。分析代码、提简化建议或做 refactor 时，**勿当作缺陷**；与「编写规范」冲突时，以本节为准。

### 环境与范围

**CI 使用干净 runner。** 每个 job 在新 VM 上启动，不保留跨 run 的本地目录状态。脚本可假定 compile 完成后只有一棵 `build/temp.win-*`（见 `get-fa-release-dir.ps1`），不必为多棵历史 build 树做择优或排序。

**只服务连续 CI 链路。** 脚本面向 prep → compile / link → smoke test **自动跑完**的一条链；不为「编译中途人工改目录、脏 workspace、混用旧 artifact」等场景加防御分支。link staging 合并、shard obj 齐全等**流水线本身需要的检查**仍保留。

### VERSION.lock 约定

**人类可读字段留在 lock，但不进逻辑。** `flash_attention_build_commit_date`、`flash_attention_min_commit` 供维护者对照与文档引用；prep / CI / smoke **不得读取或依赖**。升级 FA 时维护者自行核对 commit 不低于 `min_commit` 即可。

**参与逻辑的字段以 lock 为唯一来源。** 如 `flash_attention_build_commit`、`opt_dim`、`expected_wheel_pattern` 等——脚本直接读 lock 或经 `read-version-lock.ps1` 注入 env，不做第二套推导或交叉验算。

### 构建架构

**serial 与 parallel 双 workflow，产物相同。** 串行：单 job 全量 `bdist_wheel`；并行：四 shard `build_ext` + staging merge link。二者共用 `link_parallel_wheel.py` 与 smoke test，cache key 前缀隔离（`serial-v3` / `parallel-v3-d{dim}`），不是重复实现。

**并行 compile 四 shard 各编 shared obj，link 仅用第一档。** `PRIMARY_OPT_DIM` = `opt_dim` 逗号分隔的**第一档**（当前 `32`）。每个 shard job 都会编译 `csrc/flash_attn_ck`；link 阶段只从 `d32` 目录取 shared `.obj`，其余 shard 仅贡献各自 `build/fmha_*_dNN_*` kernel obj。**重复编 shared 是预期行为**，不是待优化的浪费。

### Workflow 可调参数

**`ninja_workers` 默认 `4`。** 对应 `MAX_JOBS`；hosted runner OOM 时手动 workflow 输入改为 `2`。不必写入 lock。

**`skip_cache_restore` 测试阶段默认 `true`。** 当前优先排除 stale cache 干扰，每次 compile 从干净 ninja 状态开始；cache **save** 仍启用。流水线稳定后将默认改为 `false`，以支持超时后 Re-run 增量续编。**在改默认之前，不要把「默认 skip restore」当设计错误。**

## 编写规范

本仓库是**单目标、强 pin、CI 优先**的构建脚本集，不是通用 flash-attn 打包框架。新增或修改代码时，默认环境是：**GitHub `windows-2022`、干净 runner、prep → compile/link → smoke test 连续跑完**。在此前提下编写——不为「可能发生的边缘情况」堆兜底。

### 原则

1. **单一事实来源** — 版本与配置以 `VERSION.lock.json` 为准；脚本只读需要的字段，不另做「声明值 vs 计算值」交叉验算。
2. **信任流水线** — CI 各 stage 按约定传参（如 `FaCommitSha`、`PrimaryDim`、artifact 布局）；不为「调用方忘了传、传错、中途被人改目录」加多层回退。
3. **信任 pin** — `flash_attention_build_commit` 由维护者负责；prep 只需验证 checkout 后的 HEAD 一致，不做 ancestry / deepen / unshallow 等 git 考古。
4. **最小路径** — 同一能力只保留一个入口（例如 staging 校验只在 `link_parallel_wheel.py` link 路径内，不另写 CLI wrapper）。
5. **Fail fast，不 silent fallback** — 缺参数、目录不对、obj 缺失应直接 `throw` / `SystemExit`；不要用「猜一个备选目录」「回退到第一个 shard」掩盖配置错误。

### 不要添加

| 类别 | 示例（已删或不应再引入） |
|------|--------------------------|
| 双源 / 重复校验 | lock 字段 + 运行时推导同一含义（如 wheel pattern 验算两遍）；写 manifest 再读回自证 |
| 调试逃生门 | `FA_SKIP_*`、`FA_STRICT_*` 等跳过或软化 CI 检查的 env |
| 非 CI 场景兜底 | 脏 workspace 多候选 `temp.win-*` 排序；shard 交叉污染检测；手动改 staging 的一致性守卫 |
| 过度 git 工具 | 短 SHA 归一化、无 repo 比对、merge-base ancestry 循环 |
| 薄包装脚本 | 仅转发已有 Python/PS1 参数的 one-liner wrapper |
| 失败兜底 artifact | 仅为了「也许有用」的 build-logs 收集/upload（除非明确要求排障） |
| lock 只读字段进逻辑 | 读取 `flash_attention_build_commit_date`、`flash_attention_min_commit` 参与分支 |

### 应当保留

- **流水线必需检查**：staging 四目录齐全、各 shard 有对应 dim kernel obj、primary shard 含 `csrc/flash_attn_ck` shared obj。
- **并行 link 机制**：`FLASH_ATTENTION_FORCE_BUILD=FALSE`、prebuilt `.obj` 时间戳 merge（这是功能，不是兜底）。
- **upstream 变更防护**：`patch-fa-inference.ps1` 对 before-state 的检查（upstream bump 时 fail fast）。
- **smoke test 主路径**：wheel 结构 → pip → extension import；kernel 正确性留给 `gpu-smoke-test.ps1`。
- **Cache 精确 key**：含 FA commit SHA，不用 `restore-keys` 跨 commit 回退。

### 新增代码自检

改脚本或 workflow 前问：

- 这一步在**连续 CI**里是否一定会发生？若否，通常不该加。
- 信息是否已在 lock / 上游 job output / 环境变量里有了？若有，不要再读侧车文件或猜默认值。
- 是否与 serial / parallel 已有路径重复？优先复用 `init-fa-build-env.ps1` + `link_parallel_wheel.py`。
- 删调后 CI **仍**能表达意图？能则删，不要「以防万一」。

### 与「设计决策」的关系

**设计决策** = 有意保留的行为与前提。**编写规范** = 不应再引入的复杂度。先满足前者，再在其余部分从简。

## 维护

- 升级 FA：改 `flash_attention_build_commit`（及可选 `_date` / 核对 `min_commit` 文档）
- bump PyTorch/ROCm：同步 `expected_wheel_pattern` 等 lock 字段
- 部署前：真机跑 `gpu-smoke-test.ps1`

## 文档

- [README.zh-CN.md](README.zh-CN.md)
- [README.md](README.md)
