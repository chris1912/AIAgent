# Grok Orchestrator Project Memory / Grok 编排器项目记忆

> Maintainer: Codex / Grok implementation stage  
> Updated: 2026-07-18  
> Documentation bilingual refresh: Codex brief + Grok `grok-4.5` executor, 2026-07-18  
> 文档中英双语刷新：Codex 简报 + Grok `grok-4.5` 执行，2026-07-18

## Purpose / 目的

Coordinate Grok Build as the primary executor while Codex owns planning, risk control, review, follow-up questions, and final acceptance. This skill remains **independently usable as Grok-only**.

以 Grok Build 为主要执行者，由 Codex 负责规划、风险控制、评审、后续问题与最终验收。本 skill 保持 **可独立作为仅 Grok 使用**。

## Current design / 当前设计

- Global workflow instructions live in `SKILL.md`.
- 全局工作流说明位于 `SKILL.md`。
- Config/profile hints: `config/grok-models.json` (hints only; live discovery is authority).
- 配置/配置文件提示：`config/grok-models.json`（仅为提示；现场发现为权威）。
- Scripts / 脚本:
  - `scripts/Common.ps1` — UTF-8 I/O, argv escaping, process-tree stop, PID reuse guard, policy gate, sentinel helpers
  - `scripts/Common.ps1` — UTF-8 输入输出、argv 转义、进程树停止、PID 复用保护、策略门控、哨兵辅助
  - `scripts/Discover-Grok.ps1` — `grok models` / `grok version`
  - `scripts/Invoke-Grok.ps1` — safe invoke + result envelope / 安全调用 + 结果信封
  - `scripts/Classify-Result.ps1` — context-aware classification; exit-zero log-level `WARN` stderr, including optional MCP auth warnings, is non-fatal while non-zero provider errors remain strict
  - `scripts/Classify-Result.ps1` — 上下文感知分类；退出码为 0 时日志级 `WARN` stderr（含可选 MCP 认证警告）非致命，非零提供方错误仍严格处理
  - `scripts/Invoke-GrokFallback.ps1` — Grok-only chain; auto-advance only for quota/model-unavailable
  - `scripts/Invoke-GrokFallback.ps1` — 仅 Grok 链；仅对配额/模型不可用自动前进
  - `scripts/watch_grok_run.ps1` — artifact-only stall; single or aggregate workers
  - `scripts/watch_grok_run.ps1` — 仅产物停滞检测；单 worker 或聚合 workers
- References: `references/watchdog-protocol.md`, `provider-contract.md`, `run-artifacts.md`
- 参考文档：`references/watchdog-protocol.md`、`provider-contract.md`、`run-artifacts.md`
- Offline tests: `tests/Run-OfflineTests.ps1` + `tests/fixtures/fake-grok.ps1`
- 离线测试：`tests/Run-OfflineTests.ps1` + `tests/fixtures/fake-grok.ps1`
- Natural-language Grok handoff and checkpoint workflow are preserved.
- 自然语言 Grok 交接与检查点工作流予以保留。

## Decisions / 决策

- Prefer event-driven status changes over frequent log polling.
- 优先事件驱动的状态变更，而非频繁日志轮询。
- Treat stalled work as an intervention event, not automatic failure; stall = no **artifact** progress.
- 将停滞工作视为干预事件，而非自动失败；停滞 = 无 **产物** 进度。
- Limit repeated revision loops for the same defect to two before narrowing, blocking, switching model within policy, taking over, or ending the run.
- 同一缺陷的重复修订循环限制为两次，之后再收窄、阻塞、在策略内切换模型、接管或结束运行。
- Abstract reasoning tiers: `highest` → Grok `high`, `second_highest` → Grok `medium`. Reject `low` / `lowest` / `minimal` before provider contact (including ExtraArgs).
- 抽象推理层级：`highest` → Grok `high`，`second_highest` → Grok `medium`。在联系提供方前拒绝 `low` / `lowest` / `minimal`（含 ExtraArgs）。
- Model hints: `grok-4.5` for highest; Composer only if discovery lists it (optional). Do not invent models.
- 模型提示：最高层用 `grok-4.5`；Composer 仅在发现列表中时可选使用。不得编造模型。
- Automatic fallback advances only for `quota_exhausted` or `model_unavailable`. Auth, network, permission, timeout, task, and unknown failures stop for Codex.
- 自动回退仅对 `quota_exhausted` 或 `model_unavailable` 前进。认证、网络、权限、超时、任务与未知失败停止并交 Codex。
- No imports or edits of `multi-model-orchestrator`, Agy, or other skills.
- 不导入或编辑 `multi-model-orchestrator`、Agy 或其它 skill。
- Windows-safe argv construction, prompt files, explicit cwd, process-tree timeout cleanup, PID reuse protection.
- Windows 安全 argv 构造、提示文件、显式 cwd、进程树超时清理、PID 复用保护。

## Verification / 验证

- Offline suite: `tests/Run-OfflineTests.ps1` (see `tests/last-offline-results.json` after run).
- 离线套件：`tests/Run-OfflineTests.ps1`（运行后见 `tests/last-offline-results.json`）。
- PowerShell 5.1 parser check included in offline suite.
- PowerShell 5.1 解析器检查包含在离线套件中。
- Do not run real long/paid coding tasks for skill self-test.
- skill 自测时不运行真实长时/付费编码任务。

## Documentation bilingual refresh (2026-07-18) / 文档中英双语刷新（2026-07-18）

- Scope: user-facing Markdown only — `SKILL.md`, `PROJECT_MEMORY.md`, `references/provider-contract.md`, `references/run-artifacts.md`, `references/watchdog-protocol.md`.
- 范围：仅用户面向 Markdown — 上述五个文件。
- Rule: keep English technical content; add corresponding Chinese; do not delete sections, commands, safety boundaries, or decisions.
- 规则：保留英文技术内容；补充对应中文；不删除章节、命令、安全边界或决策。
- Attribution: Codex authored the brief; Grok `grok-4.5` (highest) executed the documentation update.
- 归属：Codex 撰写简报；Grok `grok-4.5`（highest）执行文档更新。
- Code/scripts/tests/config: not modified for this docs-only change; offline/parser tests not required to re-run for acceptance of bilingual docs.
- 代码/脚本/测试/配置：本次纯文档变更未修改；离线/解析器测试对双语文档验收不必重跑。
