---
name: grok-orchestrator
description: Orchestrate Grok Build as the primary local executor while Codex plans, controls risk, and independently accepts results. Use when the user asks Codex to delegate coding, setup, installation, deployment, testing, or repository work to a local grok executable. / 以 Grok Build 为主要本地执行器，由 Codex 规划、控风险并独立验收。当用户要求 Codex 把编码、安装、部署、测试或仓库工作委托给本地 grok 可执行文件时使用。
---

# Grok Orchestrator / Grok 编排器

Standalone **Grok-only** skill. It does not import or depend on `multi-model-orchestrator`, Agy, or other skills.

独立的 **仅 Grok** skill。不导入、不依赖 `multi-model-orchestrator`、Agy 或其它 skill。

## Roles / 角色

- Codex is the planner, risk controller, and final acceptance owner.
- Codex 是规划者、风险控制者，以及最终验收负责人。
- Grok Build is the primary executor for repository inspection, file changes, dependency installation, commands, tests, and local deployment.
- Grok Build 是主要执行者，负责仓库检查、文件修改、依赖安装、命令执行、测试与本地部署。
- Codex must not duplicate Grok's implementation work unless taking over a blocked or risky step.
- 除非接管受阻或高风险步骤，Codex 不得重复执行 Grok 的实现工作。

## Run artifacts / 运行产物

For each task, create a dated run directory under the target project:

每项任务在目标项目下创建带日期的运行目录：

`.codex/grok-runs/YYYY-MM-DD-<slug>/`

Keep these Markdown files:

保留以下 Markdown 文件：

- `BRIEF.md`: objective, scope, constraints, and acceptance criteria written by Codex.
- `BRIEF.md`：目标、范围、约束与验收标准，由 Codex 撰写。
- `EXECUTION_LOG.md`: Grok session ID, commands, exit codes, changed files, and notable warnings.
- `EXECUTION_LOG.md`：Grok 会话 ID、命令、退出码、变更文件与重要警告。
- `STAGE_REPORT.md`: Grok's concise handoff after the current stage.
- `STAGE_REPORT.md`：当前阶段结束后 Grok 的简明交接报告。
- `REVIEW.md`: Codex's review, questions, corrections, and next-stage decision.
- `REVIEW.md`：Codex 的评审、问题、修正与下一阶段决定。
- `ACCEPTANCE.md`: Codex's independent checks and final verdict.
- `ACCEPTANCE.md`：Codex 的独立检查与最终裁决。

Machine-readable evidence (when using scripts):

机器可读证据（使用脚本时）：

- `discovery.json` — live `grok models` / `grok version` snapshot
- `discovery.json` — 现场 `grok models` / `grok version` 快照
- `workers/<id>/request.json`, `stdout.log`, `stderr.log`, `result.json`
- `FALLBACKS.jsonl`, `fallback-summary.json` when a Grok-only chain runs
- `FALLBACKS.jsonl`、`fallback-summary.json`：当运行仅 Grok 回退链时写入
- `STATUS.json`, `GROK_PID.txt`, optional `WORKER_PIDS.json`
- `STATUS.json`、`GROK_PID.txt`，可选 `WORKER_PIDS.json`
- `WATCHDOG_STATUS.json` / `WATCHDOG_EVENTS.jsonl` when watched
- `WATCHDOG_STATUS.json` / `WATCHDOG_EVENTS.jsonl`：启用看门狗时写入

Grok sets exactly one of `READY_FOR_REVIEW.flag`, `DONE.flag`, `BLOCKED.flag`, or `FAILED.flag` only after the corresponding report and `STATUS.json` are durable.

Grok 仅在对应报告与 `STATUS.json` 已持久写入后，才设置恰好一个哨兵：`READY_FOR_REVIEW.flag`、`DONE.flag`、`BLOCKED.flag` 或 `FAILED.flag`。

Keep `PROJECT_MEMORY.md` at each project root and update it after major changes.

在每个项目根保留 `PROJECT_MEMORY.md`，并在重大变更后更新。

See [references/run-artifacts.md](references/run-artifacts.md) and [references/provider-contract.md](references/provider-contract.md).

参见 [references/run-artifacts.md](references/run-artifacts.md) 与 [references/provider-contract.md](references/provider-contract.md)。

## Workflow / 工作流

1. Inspect the workspace, existing implementations, Git status, target paths, and available `grok` command.
   检查工作区、既有实现、Git 状态、目标路径，以及可用的 `grok` 命令。
2. Write `BRIEF.md` before delegation; make scope, allowed paths, forbidden actions, and acceptance tests explicit.
   在委派前撰写 `BRIEF.md`；明确范围、允许路径、禁止行为与验收测试。
3. **Discover** models before structured invocation: `scripts/Discover-Grok.ps1`. Live discovery is authority; config model names are hints only.
   结构化调用前先 **发现** 模型：`scripts/Discover-Grok.ps1`。现场发现为权威；配置中的模型名仅为提示。
4. Invoke Grok with the project directory as cwd, a bounded task, and a staged execution plan — via natural language handoff **or** `scripts/Invoke-Grok.ps1`.
   以项目目录为 cwd，携带有界任务与分阶段执行计划调用 Grok — 可通过自然语言交接 **或** `scripts/Invoke-Grok.ps1`。
5. Let Grok perform most work: read files, clone repositories, install isolated dependencies, edit code, run tests, and start local services when safe.
   让 Grok 完成大部分工作：读文件、克隆仓库、安装隔离依赖、编辑代码、运行测试，并在安全时启动本地服务。
6. End each stage at a review checkpoint. Grok writes `STAGE_REPORT.md`, updates `STATUS.json`, sets `READY_FOR_REVIEW.flag`, and exits instead of silently starting the next stage.
   每个阶段在评审检查点结束。Grok 写入 `STAGE_REPORT.md`、更新 `STATUS.json`、设置 `READY_FOR_REVIEW.flag` 后退出，而不是静默启动下一阶段。
7. Codex reads the short report first, then inspects only targeted evidence: changed files, test results, process/port state, Git status, and relevant log tails.
   Codex 先读简短报告，再仅检查有针对性的证据：变更文件、测试结果、进程/端口状态、Git 状态与相关日志尾部。
8. Record Codex's quality assessment, corrections, and follow-up questions in `REVIEW.md`. If revision is needed, resume the same Grok session with the exact unresolved items and require a revision report.
   将 Codex 的质量评估、修正与后续问题记入 `REVIEW.md`。若需修订，用确切未解决问题恢复同一 Grok 会话，并要求修订报告。
9. Permit at most two normal revision loops for the same defect. On repeated failure, mark the stage blocked, narrow the task, switch model/reasoning within policy, take over the risky step, or end the run.
   同一缺陷最多允许两次常规修订循环。反复失败时，标记阶段受阻、收窄任务、在策略内切换模型/推理等级、接管风险步骤，或结束本次运行。
10. Permit local deployment only with explicit bind address, credentials boundary, rollback/stop action, and health check.
    仅在具备明确绑定地址、凭证边界、回滚/停止动作与健康检查时，才允许本地部署。
11. Pause or take over when an action risks secrets, destructive data loss, public exposure, unauthorized account automation, CAPTCHA/anti-abuse bypass, or unbounded external side effects.
    当动作可能危及密钥、造成破坏性数据丢失、公开暴露、未授权账户自动化、绕过 CAPTCHA/反滥用，或产生无界外部副作用时，暂停或接管。
12. Write `ACCEPTANCE.md`, update `PROJECT_MEMORY.md`, and report the Grok session ID plus skipped checks.
    撰写 `ACCEPTANCE.md`，更新 `PROJECT_MEMORY.md`，并报告 Grok 会话 ID 与跳过的检查。

## Watchdog and notification / 看门狗与通知

For work expected to exceed five minutes, use `scripts/watch_grok_run.ps1` and follow [references/watchdog-protocol.md](references/watchdog-protocol.md). The watchdog polls locally without model tokens and emits output only for meaningful state changes.

对预计超过五分钟的工作，使用 `scripts/watch_grok_run.ps1` 并遵循 [references/watchdog-protocol.md](references/watchdog-protocol.md)。看门狗在本地轮询、不消耗模型 token，且仅在有意义的状态变化时输出。

- Stall detection uses **artifact progress only** (file size/mtime under the run directory). CPU-only spin does not refresh activity.
- 停滞检测仅使用 **产物进度**（运行目录下的文件大小/修改时间）。仅 CPU 空转不会刷新活动状态。
- Use `-AggregateWorkers` when observing multiple `workers/*/WORKER_PID.txt` entries; optional `WORKER_PIDS.json` index.
- 观察多个 `workers/*/WORKER_PID.txt` 条目时使用 `-AggregateWorkers`；可选 `WORKER_PIDS.json` 索引。
- In the active turn, keep one watcher exec session open and wait on it with backoff; do not repeatedly dump logs.
- 在活动回合中，保持一个监视 exec 会话打开并以退避方式等待；不要反复倾倒日志。
- For background work, create a temporary Codex thread heartbeat that reads only `WATCHDOG_STATUS.json`. Disable it when the run reaches a terminal state.
- 对后台工作，创建临时 Codex 线程心跳，仅读取 `WATCHDOG_STATUS.json`。运行到达终态后禁用该心跳。
- Treat no artifact progress for the configured stall window as `stalled`, not immediate failure. Inspect once, then resume with a narrower prompt or terminate the run.
- 在配置的停滞窗口内无产物进度时视为 `stalled`，而非立即失败。先检查一次，再以更窄提示恢复或终止运行。
- Use a hard timeout for every stage. Terminate only the process tree launched for that run (PID + start-time guard), and only when the timeout policy explicitly permits it.
- 每个阶段使用硬超时。仅终止为该次运行启动的进程树（PID + 启动时间保护），且仅在超时策略明确允许时终止。

## Evidence standard / 证据标准

Treat Grok's transcript as execution evidence, not sole proof. Corroborate it with process ancestry, timestamps, command logs, Git diff/status, file hashes when useful, test output, and service state. State clearly which checks Codex performed independently.

将 Grok 的对话记录视为执行证据，而非唯一证明。用进程谱系、时间戳、命令日志、Git diff/status、有用时的文件哈希、测试输出与服务状态加以佐证。明确说明 Codex 独立完成了哪些检查。

## Token discipline / Token 纪律

Ask Grok for concise stage summaries and write verbose command output to `EXECUTION_LOG.md`. Codex reads `STATUS.json` and `STAGE_REPORT.md` first; it opens verbose logs only on failure, contradiction, or a targeted evidence check. Use separate Grok sessions for large stages so each session has a clear audit boundary.

要求 Grok 提供简明阶段摘要，并将冗长命令输出写入 `EXECUTION_LOG.md`。Codex 先读 `STATUS.json` 与 `STAGE_REPORT.md`；仅在失败、矛盾或有针对性证据检查时打开冗长日志。大型阶段使用独立 Grok 会话，使每个会话都有清晰审计边界。

## Model and reasoning selection / 模型与推理选择

Abstract tiers only:

仅使用抽象层级：

| Abstract tier / 抽象层级 | Grok `--reasoning-effort` | Typical model hint / 典型模型提示 |
|---|---|---|
| `highest` | `high` | `grok-4.5` |
| `second_highest` | `medium` | `grok-4.5` or Composer **if discovered** / 或 Composer（**仅当已发现**） |

**Forbidden** at the invocation boundary (including ExtraArgs): `low`, `lowest`, `minimal`.

调用边界（含 ExtraArgs）**禁止**：`low`、`lowest`、`minimal`。

Hints live in `config/grok-models.json`. **Do not pretend Composer or other models exist** if `grok models` does not list them. Current live discovery often shows only `grok-4.5`.

提示位于 `config/grok-models.json`。若 `grok models` 未列出 Composer 或其它模型，**不得假装它们存在**。当前现场发现通常仅显示 `grok-4.5`。

Guidance:

指引：

- `highest` / `grok-4.5`: architecture, security/risk review, ambiguous requirements, difficult debugging, migration design, final synthesis.
- `highest` / `grok-4.5`：架构、安全/风险评审、模糊需求、困难调试、迁移设计、最终综合。
- `second_highest`: routine mechanical work when appropriate; use Composer only when discovery lists it.
- `second_highest`：适合时用于常规机械性工作；仅当发现列表含 Composer 时使用 Composer。
- Keep Codex's final acceptance on highest-tier judgment when the result affects public exposure, credentials, data, or deployment.
- 当结果影响公开暴露、凭证、数据或部署时，Codex 最终验收应保持最高层级判断。
- Do not claim a price difference unless the local account exposes billing data.
- 除非本地账户暴露计费数据，否则不得声称存在价格差异。

## Safe invocation scripts / 安全调用脚本

Structured runners (`Invoke-Grok.ps1`, default-route `Invoke-GrokFallback.ps1`) **require** a valid discovery snapshot before provider contact: `available=true` and at least one eligible model. Omitted `-Model` is resolved from the eligible discovery list (registry highest hint when present, else first eligible). Absent, unavailable, or empty discovery is refused.

结构化运行器（`Invoke-Grok.ps1`、默认路由的 `Invoke-GrokFallback.ps1`）在联系提供方前 **要求** 有效发现快照：`available=true` 且至少一个合格模型。省略的 `-Model` 从合格发现列表解析（存在时用注册表最高提示，否则用第一个合格项）。缺失、不可用或空发现将被拒绝。

```powershell
# 1) Live discovery (authority) — required before structured invoke
# 1) 现场发现（权威）— 结构化调用前必需
powershell -NoProfile -File scripts/Discover-Grok.ps1 -OutJson run/discovery.json -RequireAvailable

# 2) Single bounded invoke (discovery gate is the safe default)
# 2) 单次有界调用（发现门控为安全默认）
powershell -NoProfile -File scripts/Invoke-Grok.ps1 `
  -RunDirectory run `
  -DiscoveryJsonPath run/discovery.json `
  -Model grok-4.5 `
  -ReasoningTier highest `
  -PromptFile run/BRIEF.md `
  -Cwd <project> `
  -TimeoutSeconds 3600

# 3) Grok-only fallback (default route also requires discovery; advances only for quota_exhausted / model_unavailable)
# 3) 仅 Grok 回退（默认路由同样需要发现；仅对 quota_exhausted / model_unavailable 前进）
powershell -NoProfile -File scripts/Invoke-GrokFallback.ps1 `
  -RunDirectory run `
  -DiscoveryJsonPath run/discovery.json `
  -PromptFile run/BRIEF.md `
  -TimeoutSeconds 3600

# 4) Watchdog
# 4) 看门狗
powershell -NoProfile -File scripts/watch_grok_run.ps1 `
  -RunDirectory run `
  -StallMinutes 10 `
  -HardTimeoutMinutes 60
```

Classification: `scripts/Classify-Result.ps1` maps raw output to `success`, `quota_exhausted`, `model_unavailable`, `auth_failure`, `network_failure`, `permission_failure`, `timeout`, `task_failure`. Only **quota_exhausted** and **model_unavailable** auto-advance the Grok chain; auth, network, permission, timeout, task, and unknown failures stop for Codex review.

分类：`scripts/Classify-Result.ps1` 将原始输出映射为 `success`、`quota_exhausted`、`model_unavailable`、`auth_failure`、`network_failure`、`permission_failure`、`timeout`、`task_failure`。仅 **quota_exhausted** 与 **model_unavailable** 会自动推进 Grok 链；认证、网络、权限、超时、任务与未知失败均停止并交 Codex 评审。

Offline regression: `tests/Run-OfflineTests.ps1` (fake-Grok; no paid/long coding tasks).

离线回归：`tests/Run-OfflineTests.ps1`（假 Grok；无付费/长时编码任务）。

## Invocation examples / 调用示例

Natural language:

自然语言：

`Use grok-orchestrator. In <project>, implement <goal>; let Grok execute, then independently verify <acceptance tests>.`

`使用 grok-orchestrator。在 <project> 中实现 <goal>；让 Grok 执行，然后独立验证 <acceptance tests>。`

### Manual direct CLI (compatibility path) / 手动直连 CLI（兼容路径）

The raw `grok` CLI remains a valid **manual** handoff for ad-hoc sessions. It is **not** the structured runner contract: it does not write `request.json`/`result.json`, does not enforce the discovery gate, and does not classify or fall back. Prefer structured scripts for durable, policy-gated runs.

原始 `grok` CLI 仍是临时会话的有效 **手动** 交接方式。它 **不是** 结构化运行器契约：不写 `request.json`/`result.json`、不强制发现门控、不分类也不回退。对需持久化与策略门控的运行，优先使用结构化脚本。

```text
grok --cwd <project> --model grok-4.5 --reasoning-effort high --always-approve --single "Read BRIEF.md, execute it, update EXECUTION_LOG.md and PROJECT_MEMORY.md, then report changed files and checks."
```

Or with a prompt file:

或使用提示文件：

```text
grok --cwd <project> --model grok-4.5 --reasoning-effort high --always-approve --prompt-file .codex/grok-runs/<run>/BRIEF.md
```

Prefer `scripts/Invoke-Grok.ps1` when you need discovery-gated model selection, durable request/result logs, classification, timeout tree cleanup, and policy gates.

需要发现门控的模型选择、持久 request/result 日志、分类、超时进程树清理与策略门控时，优先使用 `scripts/Invoke-Grok.ps1`。

Never claim Grok performed an action unless its transcript or filesystem/process evidence supports the claim.

除非 Grok 的对话记录或文件系统/进程证据支持该主张，否则不得声称 Grok 执行了某动作。
