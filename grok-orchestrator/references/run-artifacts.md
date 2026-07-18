# Run Artifacts (Grok Orchestrator) / 运行产物（Grok 编排器）

> Authored 2026-07-18.  
> Bilingual refresh: Codex brief + Grok `grok-4.5`, 2026-07-18.  
> 撰写于 2026-07-18。  
> 中英双语刷新：Codex 简报 + Grok `grok-4.5`，2026-07-18。

## Run directory / 运行目录

```text
.codex/grok-runs/YYYY-MM-DD-<slug>/
```

Layout (files may be sparse early in a run):

布局（运行早期文件可能稀疏）：

```text
BRIEF.md
EXECUTION_LOG.md
STAGE_REPORT.md
REVIEW.md                 # Codex
ACCEPTANCE.md             # Codex
STATUS.json
READY_FOR_REVIEW.flag     # exactly one sentinel when ready / 就绪时恰好一个哨兵
DONE.flag | BLOCKED.flag | FAILED.flag
discovery.json
FALLBACKS.jsonl
fallback-summary.json
GROK_PID.txt
WORKER_PID.txt            # optional root alias / 可选根别名
WORKER_PIDS.json          # optional multi-worker index / 可选多 worker 索引
workers/
  <worker_id>/
    request.json
    stdout.log
    stderr.log
    result.json
    WORKER_PID.txt
    GROK_PID.txt
WATCHDOG_STATUS.json
WATCHDOG_EVENTS.jsonl
```

## Sentinel rules / 哨兵规则

1. Write `STAGE_REPORT.md` (or equivalent durable report) and `STATUS.json` **first**.
   先写入 `STAGE_REPORT.md`（或等价持久报告）与 `STATUS.json`。
2. Then create **exactly one** of: `READY_FOR_REVIEW.flag`, `DONE.flag`, `BLOCKED.flag`, `FAILED.flag`.
   然后创建 **恰好一个**：`READY_FOR_REVIEW.flag`、`DONE.flag`、`BLOCKED.flag`、`FAILED.flag`。
3. Helpers: `Write-GoStageArtifacts` then `Write-GoSentinel` in `scripts/Common.ps1`.
   辅助函数：`scripts/Common.ps1` 中的 `Write-GoStageArtifacts`，然后 `Write-GoSentinel`。

## STATUS.json minimum fields / STATUS.json 最低字段

```json
{
  "run_id": "2026-07-18-example",
  "stage": "implement",
  "state": "ready_for_review",
  "session_id": "optional",
  "model": "grok-4.5",
  "reasoning_tier": "highest",
  "summary": "short",
  "next_action": "codex_review",
  "updated_at": "ISO-8601"
}
```

## Evidence to retain / 应保留的证据

- raw provider stdout/stderr
- 原始提供方 stdout/stderr
- normalized `result.json`
- 规范化 `result.json`
- fallback reasons when used
- 使用时的回退原因
- changed paths
- 变更路径
- test command output
- 测试命令输出
- Codex `REVIEW.md` / `ACCEPTANCE.md`

Transcripts are evidence, not sole proof.

对话记录是证据，但不是唯一证明。

## Token discipline / Token 纪律

Codex should read `STATUS.json` and `STAGE_REPORT.md` first. Open verbose logs only on failure, contradiction, or targeted verification.

Codex 应先读 `STATUS.json` 与 `STAGE_REPORT.md`。仅在失败、矛盾或有针对性核验时打开冗长日志。
