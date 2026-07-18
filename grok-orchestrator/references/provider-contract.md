# Grok Provider Contract / Grok 提供方契约

> Authored 2026-07-18 for standalone grok-orchestrator.  
> Bilingual refresh: Codex brief + Grok `grok-4.5`, 2026-07-18.  
> 撰写于 2026-07-18，面向独立 grok-orchestrator。  
> 中英双语刷新：Codex 简报 + Grok `grok-4.5`，2026-07-18。

## Goal / 目标

One local adapter surface for the Grok CLI so Codex can invoke, classify, and fall back without depending on multi-provider skills.

为 Grok CLI 提供一个本地适配表面，使 Codex 可调用、分类与回退，而无需依赖多提供方 skill。

## Adapter surface / 适配表面

| Capability / 能力 | Script / 脚本 | Meaning / 含义 |
|---|---|---|
| Discover / 发现 | `Discover-Grok.ps1` | Resolve executable, version, models / 解析可执行文件、版本、模型 |
| Invoke / 调用 | `Invoke-Grok.ps1` | Bounded headless prompt with cwd, model, tier, timeout / 有界无头提示，含 cwd、模型、层级、超时 |
| Normalize / 规范化 | `Invoke-Grok.ps1` result.json | Common result envelope from stdout/stderr/exit / 由 stdout/stderr/exit 形成的通用结果信封 |
| Classify / 分类 | `Classify-Result.ps1` | success / quota / model_unavailable / auth / network / permission / task / timeout |
| Fallback / 回退 | `Invoke-GrokFallback.ps1` | Grok-only hops; quota/model-unavailable only / 仅 Grok 跳转；仅配额/模型不可用 |

## Common invoke request (workers/\*/request.json) / 通用调用请求

```json
{
  "provider": "grok",
  "executable": "path",
  "model": "grok-4.5",
  "reasoning_tier": "highest|second_highest",
  "reasoning_effort": "high|medium",
  "prompt_file": "path",
  "cwd": "path",
  "worker_id": "w1",
  "timeout_seconds": 3600,
  "always_approve": true,
  "args": []
}
```

## Common result object (workers/\*/result.json) / 通用结果对象

```json
{
  "provider": "grok",
  "worker_id": "w1",
  "model": "grok-4.5",
  "reasoning_tier": "highest",
  "reasoning_effort": "high",
  "exit_code": 0,
  "classification": "success",
  "fallback_eligible": false,
  "raw_stdout_path": ".../stdout.log",
  "raw_stderr_path": ".../stderr.log",
  "changed_paths": [],
  "summary": "one paragraph",
  "error_message": null,
  "started_at": "ISO-8601",
  "ended_at": "ISO-8601",
  "timed_out": false
}
```

## Discovery authority / 发现权威

- Commands: `grok models`, `grok version`
- 命令：`grok models`、`grok version`
- Config file `config/grok-models.json` holds **hints only**
- 配置文件 `config/grok-models.json` 仅保存 **提示**
- Do not invent Composer or other models when discovery omits them
- 当发现结果未列出时，不得编造 Composer 或其它模型
- Current live inventory often: `grok-4.5` only
- 当前现场清单通常：仅 `grok-4.5`
- **Structured gate (safe default):** `Invoke-Grok.ps1` and the default route of `Invoke-GrokFallback.ps1` require `-DiscoveryJsonPath` with `available=true` and at least one eligible model before any provider contact. Omitted `-Model` is resolved from the eligible list. Absent / unavailable / empty discovery is refused.
- **结构化门控（安全默认）：** `Invoke-Grok.ps1` 与 `Invoke-GrokFallback.ps1` 的默认路由在任何提供方联系前都要求 `-DiscoveryJsonPath` 满足 `available=true` 且至少一个合格模型。省略的 `-Model` 从合格列表解析。缺失 / 不可用 / 空发现将被拒绝。
- **Manual direct CLI** (`grok --cwd ...`) remains a documented compatibility path outside the structured runner; it does not weaken the script contract.
- **手动直连 CLI**（`grok --cwd ...`）仍是结构化运行器之外的已文档化兼容路径；它不会削弱脚本契约。

## Reasoning policy / 推理策略

| Abstract tier / 抽象层级 | Provider effort / 提供方 effort |
|---|---|
| `highest` | `high` |
| `second_highest` | `medium` |

Reject `low`, `lowest`, `minimal` (case-insensitive) before provider contact, including values smuggled through ExtraArgs or model labels.

在联系提供方前拒绝 `low`、`lowest`、`minimal`（不区分大小写），包括经 ExtraArgs 或模型标签夹带的值。

## Headless invoke flags / 无头调用标志

```text
grok --cwd <cwd> --model <model> --reasoning-effort <effort> --always-approve --prompt-file <path>
# or --single <prompt>
# 或 --single <prompt>
```

- Default non-interactive approval: `--always-approve` (pass `-NoAlwaysApprove` only for intentional interactive sessions)
- 默认非交互批准：`--always-approve`（仅在有意的交互会话中传入 `-NoAlwaysApprove`）
- Argument construction: `Set-GoProcessStartInfoArguments` (ArgumentList when available; else Windows-safe `Arguments` escaping). `UseShellExecute = false`
- 参数构造：`Set-GoProcessStartInfoArguments`（可用时用 ArgumentList；否则用 Windows 安全的 `Arguments` 转义）。`UseShellExecute = false`
- Hard timeout: `Stop-GoProcessTree` with root start-time PID reuse guard
- 硬超时：`Stop-GoProcessTree`，带根进程启动时间的 PID 复用保护
- PID files: `workers/<id>/WORKER_PID.txt`, run-root `GROK_PID.txt`
- PID 文件：`workers/<id>/WORKER_PID.txt`，运行根目录 `GROK_PID.txt`

## Fallback boundaries / 回退边界

| Classification / 分类 | Auto-advance? / 自动前进？ |
|---|---|
| `quota_exhausted` | **yes** / **是** |
| `model_unavailable` | **yes** / **是** |
| `auth_failure` | no — Codex review / 否 — Codex 评审 |
| `network_failure` | no — Codex review / 否 — Codex 评审 |
| `permission_failure` | no — Codex review / 否 — Codex 评审 |
| `timeout` | no — Codex review / 否 — Codex 评审 |
| `task_failure` | no — Codex review / 否 — Codex 评审 |
| `unknown_error` | no — Codex review / 否 — Codex 评审 |

Record hops in `FALLBACKS.jsonl` and aggregate in `fallback-summary.json`. Never purchase credits or mutate credentials.

在 `FALLBACKS.jsonl` 记录跳转，并在 `fallback-summary.json` 聚合。绝不购买额度或改动凭证。

Default chain (when discovery allows): `grok-4.5/highest` then optional Composer/`second_highest` **only if listed**.

默认链（当发现允许时）：`grok-4.5/highest`，然后可选 Composer/`second_highest`（**仅当已列出**）。

## Copyable examples / 可复制示例

```powershell
powershell -NoProfile -File scripts/Discover-Grok.ps1 -OutJson .codex/grok-runs/<run>/discovery.json -RequireAvailable

powershell -NoProfile -File scripts/Invoke-Grok.ps1 `
  -RunDirectory .codex/grok-runs/<run> `
  -DiscoveryJsonPath .codex/grok-runs/<run>/discovery.json `
  -Model grok-4.5 `
  -ReasoningTier highest `
  -PromptFile .codex/grok-runs/<run>/BRIEF.md `
  -Cwd <project> `
  -TimeoutSeconds 3600

powershell -NoProfile -File scripts/Invoke-GrokFallback.ps1 `
  -RunDirectory .codex/grok-runs/<run> `
  -DiscoveryJsonPath .codex/grok-runs/<run>/discovery.json `
  -PromptFile .codex/grok-runs/<run>/BRIEF.md
```
