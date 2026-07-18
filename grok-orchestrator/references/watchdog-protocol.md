# Grok Watchdog Protocol / Grok 看门狗协议

> Authored by Codex on 2026-07-12; upgraded 2026-07-18 for artifact-only stall and aggregate workers.  
> Bilingual refresh: Codex brief + Grok `grok-4.5`, 2026-07-18.  
> 由 Codex 于 2026-07-12 撰写；2026-07-18 升级为仅产物停滞检测与聚合 workers。  
> 中英双语刷新：Codex 简报 + Grok `grok-4.5`，2026-07-18。

## Why / 原因

Frequent Codex polling consumes tokens because every process listing or log dump re-enters model context. The watchdog moves routine polling into a local PowerShell process and wakes Codex only for a meaningful event.

频繁的 Codex 轮询会消耗 token，因为每次进程列表或日志倾倒都会重新进入模型上下文。看门狗将例行轮询移到本地 PowerShell 进程，仅在有意义事件时唤醒 Codex。

## Stage contract / 阶段契约

One Grok run should complete one bounded stage, then stop for review. Before it exits, Grok writes:

一次 Grok 运行应完成一个有界阶段，然后停止等待评审。退出前，Grok 写入：

1. `STATUS.json` with `run_id`, `stage`, `state`, `session_id`, `model`, `reasoning_effort` / `reasoning_tier`, `summary`, `next_action`, and timestamps.
   `STATUS.json`，含 `run_id`、`stage`、`state`、`session_id`、`model`、`reasoning_effort` / `reasoning_tier`、`summary`、`next_action` 与时间戳。
2. `STAGE_REPORT.md` with objective, actions, changed files, commands, checks, risks, blockers, and proposed next stage.
   `STAGE_REPORT.md`，含目标、动作、变更文件、命令、检查、风险、阻塞与建议的下一阶段。
3. `EXECUTION_LOG.md` or redirected stdout/stderr for verbose evidence.
   `EXECUTION_LOG.md` 或重定向的 stdout/stderr，作为冗长证据。
4. Exactly one sentinel: `READY_FOR_REVIEW.flag`, `DONE.flag`, `BLOCKED.flag`, or `FAILED.flag`.
   恰好一个哨兵：`READY_FOR_REVIEW.flag`、`DONE.flag`、`BLOCKED.flag` 或 `FAILED.flag`。

Write the report before the sentinel so notification never races an incomplete report.

先写报告再写哨兵，使通知永远不会与未完成的报告竞态。

## State machine / 状态机

`queued -> running -> ready_for_review -> accepted -> next_stage`

Terminal or intervention states are `done`, `blocked`, `failed`, `stalled`, `timeout`, and `cancelled`.

终态或干预状态为 `done`、`blocked`、`failed`、`stalled`、`timeout` 与 `cancelled`。

Codex writes `REVIEW.md` after every checkpoint with one verdict:

Codex 在每个检查点后写入 `REVIEW.md`，并给出一个裁决：

- `PASS`: accept this stage and issue the next `BRIEF.md`.
- `PASS`：接受本阶段并发出下一份 `BRIEF.md`。
- `REVISE`: list exact factual gaps or failed checks and resume the same Grok session.
- `REVISE`：列出确切事实缺口或失败检查，并恢复同一 Grok 会话。
- `BLOCK`: stop because authority, safety, credentials, or external state is missing.
- `BLOCK`：因权限、安全、凭证或外部状态缺失而停止。
- `TAKEOVER`: Codex handles only the blocked/risky step, then returns execution to Grok when possible.
- `TAKEOVER`：Codex 仅处理受阻/风险步骤，然后在可能时把执行交回 Grok。

Record Grok's answer to every follow-up in the next stage report or exported transcript. Never keep review and challenge reasoning only in chat.

将 Grok 对每个后续问题的回答记入下一阶段报告或导出的对话记录。绝不可仅把评审与质疑推理留在聊天中。

## Notification modes / 通知模式

### Active Codex turn / 活动 Codex 回合

Launch the watchdog as a long-running exec session. Wait with 30-60 second backoff. The script remains quiet while progress continues and returns only for checkpoint, completion, failure, stall, or timeout.

将看门狗作为长时运行的 exec 会话启动。以 30–60 秒退避等待。进度持续时脚本保持安静，仅在检查点、完成、失败、停滞或超时时返回。

### Background task / 后台任务

Create a temporary Codex heartbeat automation attached to the current thread. It reads only `WATCHDOG_STATUS.json` every few minutes and wakes the thread when the state changes. Disable or delete the heartbeat after a terminal state.

创建附加到当前线程的临时 Codex 心跳自动化。它每隔几分钟仅读取 `WATCHDOG_STATUS.json`，并在状态变化时唤醒线程。终态后禁用或删除该心跳。

The filesystem cannot push directly into a stopped model turn; the heartbeat is the bridge that creates a real wake-up.

文件系统无法直接推入已停止的模型回合；心跳是产生真实唤醒的桥梁。

## Time budgets / 时间预算

| Stage class / 阶段类别 | Expected / 预期 | Stall window / 停滞窗口 | Hard timeout / 硬超时 | Codex heartbeat / Codex 心跳 |
|---|---:|---:|---:|---:|
| Quick / 快速 | under 10 min / 10 分钟内 | 5 min | 20 min | none or 5 min / 无或 5 分钟 |
| Medium / 中等 | 10-45 min | 10 min | 60 min | 5 min |
| Long / 长时 | over 45 min / 超过 45 分钟 | 15 min | 90 min | 5-10 min |

Split work expected to exceed 90 minutes into smaller stages instead of extending one autonomous run.

预计超过 90 分钟的工作应拆成更小阶段，而不是延长一次自治运行。

## Stall handling / 停滞处理

Progress is **artifact-only**: run-directory file bytes or latest write time (excluding `WATCHDOG_STATUS.json` / `WATCHDOG_EVENTS.jsonl`). **CPU-only spin does not count as progress.**

进度仅为 **产物**：运行目录文件字节数或最近写入时间（排除 `WATCHDOG_STATUS.json` / `WATCHDOG_EVENTS.jsonl`）。**仅 CPU 空转不计入进度。**

When `stalled` occurs:

当出现 `stalled` 时：

1. Read `STATUS.json`, `STAGE_REPORT.md` if present, and at most the last 100 log lines.
   读取 `STATUS.json`、若存在则读 `STAGE_REPORT.md`，以及最多最后 100 行日志。
2. Inspect the Grok process tree and the single external command it is waiting on (PID + start-time guard).
   检查 Grok 进程树及其等待的单个外部命令（PID + 启动时间保护）。
3. Decide whether the cause is slow-but-valid work, missing input, repeated error, network wait, permission prompt, or model drift.
   判断原因是缓慢但有效的工作、缺少输入、重复错误、网络等待、权限提示，还是模型漂移。
4. Resume with a narrower instruction, switch model/reasoning within policy, provide the missing input, or terminate the run.
   以更窄指令恢复、在策略内切换模型/推理、提供缺失输入，或终止运行。
5. After two failed revisions for the same issue, stop looping and choose `BLOCK` or `TAKEOVER`.
   同一问题两次修订失败后，停止循环并选择 `BLOCK` 或 `TAKEOVER`。

## Aggregate workers / 聚合 workers

When multiple workers write under `workers/*/WORKER_PID.txt` (or `WORKER_PIDS.json`):

当多个 workers 在 `workers/*/WORKER_PID.txt`（或 `WORKER_PIDS.json`）下写入时：

```powershell
powershell.exe -NoProfile -NonInteractive -File scripts\watch_grok_run.ps1 `
  -RunDirectory <run-dir> `
  -AggregateWorkers `
  -StallMinutes 10 `
  -HardTimeoutMinutes 60
```

- All workers complete with `result.json` → state `workers_complete` (exit 0).
- 所有 workers 完成并有 `result.json` → 状态 `workers_complete`（退出码 0）。
- Any worker exits without result while others are done → `failed_unreported` (exit 3).
- 任一 worker 无结果退出而其它已完成 → `failed_unreported`（退出码 3）。
- Run-level sentinels still take precedence when present.
- 存在运行级哨兵时，仍以运行级哨兵优先。

This skill remains single-writer by design for shared cwds; aggregate watch is for observing multi-hop fallback workers or isolated directories, not concurrent writers on one tree.

本 skill 对共享 cwd 在设计上仍为单写者；聚合监视用于观察多跳回退 workers 或隔离目录，而非同一树上的并发写者。

## Token discipline / Token 纪律

- Do not poll full logs on a timer.
- 不要按定时器轮询完整日志。
- Do not reread unchanged reports.
- 不要重读未变更的报告。
- Persist the last reviewed artifact hashes or timestamps in `REVIEW.md`.
- 将上次评审的产物哈希或时间戳持久写入 `REVIEW.md`。
- Ask Grok for a concise report and store verbose output on disk.
- 要求 Grok 提供简明报告，并将冗长输出存盘。
- Export the Grok transcript once at the end or when attribution is disputed.
- 在结束时或归属有争议时，导出一次 Grok 对话记录。

## Watchdog usage / 看门狗用法

The launcher writes the Grok process ID to `GROK_PID.txt`, then runs:

启动器将 Grok 进程 ID 写入 `GROK_PID.txt`，然后运行：

```powershell
powershell.exe -NoProfile -NonInteractive -File scripts\watch_grok_run.ps1 `
  -RunDirectory <run-dir> `
  -StallMinutes 10 `
  -HardTimeoutMinutes 60
```

Use `-TerminateOnTimeout` only when Grok and all child processes were launched specifically for this run. Termination uses process-tree cleanup with PID reuse protection (recorded root start time).

仅当 Grok 及其所有子进程专为本次运行启动时，才使用 `-TerminateOnTimeout`。终止使用带 PID 复用保护的进程树清理（记录的根进程启动时间）。
