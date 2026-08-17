# 看门狗与优雅退出机制

## 背景

GitHub-hosted runner 的 job 硬上限为 **6 小时**（不可突破）。compile 接近 6h 时被强制终止时，`if: always()` 的 ninja cache save 可能来不及执行。

## 目标

1. 自 bootstrap 起 **5h** 主动中断 compile，留出 save 窗口
2. save 已编译的 ninja 增量缓存
3. 自动 dispatch retry run 接续编译（`use_cache=true` 时）

## 机制总览

**初始 run（retry_count=0）：**

1. **A00** 第一步写 `JOB_START_TIME`（UTC epoch ms）。
2. fingerprint + cache restore 后，**`06.compile`** 经 `spawnAsync` 启动 Python 编译，同时 `watchdog.ts` 注册单次 deadline（`jobStartMs + 5h`）。
3. 到期且子进程仍在运行 → 写 `ABORT_TRIGGERED=true`、`COMPILE_COMPLETE=false` → 最多 **3× SIGINT**（间隔 1min）→ 仍不退出则 `taskkill /T /F` 并写 `ABORT_FORCE_KILLED=true`（**不 save、不 retry**）。中止期间 Node 通过 `process.on('SIGINT')` + `swallowSigint` 拦截误传到自身的 SIGINT，以保持存活并完成 save。
4. 编译成功 → `COMPILE_COMPLETE=true`。
5. **A03** save ninja cache（`use_cache=true` 时失败也 save；`ABORT_FORCE_KILLED` 时跳过 save/delete）。
6. **retry**：
   - **serial**：compile job 内 save 后 **`07-retry`**（workflow 条件：`!cancelled() && ABORT_TRIGGERED && !COMPILE_COMPLETE && ABORT_FORCE_KILLED != 'true'`；普通 compile 失败不触发）。
   - **parallel**：compile shard 写 `abort-meta/d{dim}.json` 并上传 artifact **`abort-meta-d{dim}`**；compile matrix **失败**且全部 shard 结束后独立 **`watchdog-retry`** job 下载 abort/cache meta，**单次**调用 **`07-retry --abort-meta-dir`**。
7. wheel / verify / publish 仅在 compile 成功路径执行（serial 同 job 内 `09.wheel` → `A99`；parallel 独立 **`link-wheel`** job）。

**Retry run（retry_count=N）：** 继承 `ninja_workers`、`use_cache`、`publish_release`、`ck_disable_bwd`，仅 `retry_count` 递增；restore ninja cache 后续接编译，重复看门狗 + retry，直至 5h 内完成或 `retry_count >= 8`。

## Parallel abort 元数据匹配

`evaluateParallelWatchdogRetry`（`watchdog-abort-meta.ts`）在 **`watchdog-retry`** job 内校验 compile 失败是否**全部**由看门狗引起：

1. 从 `--all-opt-dims` 得 plan 全部 OPT_DIM；从 `--cache-meta-dir` 得已成功 shard（有 cache-meta 的 dim）。
2. `failedDims` = 全部 dim − 成功 dim。
3. 从 `--abort-meta-dir` 读 abort 条目（JSON 文件 `abort-meta/d{dim}.json`，artifact 名 `abort-meta-d{dim}`）；任一 `force_killed=true` → 直接 throw（不 retry）。
4. **eligible** 当且仅当 `failedDims` 与 abort 条目中的 `opt_dim` 集合**完全一致**（无缺项、无多余、无非看门狗失败 shard）。

不支持 partial link：部分 shard 成功时 matrix 仍为 `failure`，`link-wheel` 跳过，由 retry run 全量重跑（已成功 shard 的 ninja cache 可被 restore 加速）。

## 为什么用 SIGINT + 吞信号

| 手段 | 行为 |
|------|------|
| `child.kill("SIGINT")` | 向编译子进程发 SIGINT，ninja 通常 `Cleanup()` 后以非 0 退出 |
| `swallowSigint` | 中止期间父 Node 忽略误传的 SIGINT，避免 save/retry 步骤来不及执行 |
| `taskkill /PID /T /F` | 3 次 SIGINT 仍不退出时的兜底强杀 |

实现集中在 `scripts/lib/watchdog.ts`；`exec.ts` 的 `spawnAsync` 暴露 `child.pid` 供 taskkill 使用。

## 环境变量

| 变量 | 写入 | 含义 |
|------|------|------|
| `JOB_START_TIME` | A00 | bootstrap 开始 UTC epoch ms |
| `ABORT_TRIGGERED` | `watchdog.ts` | 已触发优雅中止 |
| `ABORT_FORCE_KILLED` | `watchdog.ts` | 已 taskkill；不 save、不 retry |
| `COMPILE_COMPLETE` | `06.compile` | `true` 成功；中止时 `false` |
| `RETRY_COUNT` | workflow input → env | 当前 retry 计数（manifest `dispatch.retry_count`；save 后 `07-retry` 判断） |
| `PUBLISH_RELEASE` | workflow input → env | retry dispatch 时继承 `publish_release` |

## 结果

| 场景 | 结论 |
|------|------|
| 5h 内完成 | success |
| 看门狗 + retry 成功 cancel | cancelled（新 run 接续） |
| taskkill / `retry_count ≥ 8` / `use_cache=false` / dispatch 失败 / 5min 未 cancel | failure |

## 实现入口

- `scripts/lib/watchdog.ts` — `createWatchdog`
- `scripts/lib/exec.ts` — `spawnAsync`（暴露 `child.pid`）
- `scripts/commands/06.compile.ts` — 看门狗接入
- `scripts/lib/watchdog-abort-meta.ts` — parallel abort 元数据读取与 eligible 判定
- `scripts/commands/07-retry.ts` — retry dispatch（serial 同 job；parallel 独立 `watchdog-retry` job）

### 07-retry 行为

- serial：脚本入口校验 `ABORT_FORCE_KILLED=true` → throw（与 workflow `if:` 双重门禁）。
- parallel：先经 `evaluateParallelWatchdogRetry`；不 eligible 则 throw（含非看门狗失败、force_killed、abort/cache meta 与 failed shard 不一致）。
- `use_cache=false` 或 `retry_count >= 8` → throw。
- `gh api workflow_dispatch`：3 次重试，间隔 60s；成功后等 300s 由 concurrency `cancel-in-progress` 取消当前 run；未 cancel 则 throw。

## 已知限制（刻意不处理）

- bootstrap + fingerprint + restore 计入 5h 窗口（`JOB_START_TIME` 从 A00 第一步起算，已覆盖常规场景）
- 6h 硬上限内 save 仍未完成
- `use_cache=false` 时 compile 失败不 save、不 retry
- parallel 不支持 partial link（见上文 abort 匹配）

## 风险与降级

| 风险 | 缓解 |
|------|------|
| SIGINT 单次失败 | 每 1min 重复，最多 3 次 |
| 3 次后仍不退出 | `taskkill` + `ABORT_FORCE_KILLED=true`；A03 跳过 save/delete，workflow 跳过 retry |
| dispatch 失败 | 3 次重试 + 明确报错 |
| 并发取消延迟 | 等 300s 后报错；wheel 仅在 compile 成功路径执行 |
| parallel 非看门狗 compile 失败 | `watchdog-retry` job 运行后 `evaluateParallelWatchdogRetry` 拒绝并 failure |
