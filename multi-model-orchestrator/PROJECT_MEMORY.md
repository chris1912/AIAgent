# Multi-Model Orchestrator Project Memory

> Maintainer: Codex / Grok stage  
> Updated: 2026-07-17 (documentation refresh for task-attribute routing)

## Purpose

Coordinate local Grok CLI and Antigravity (`agy`) CLI workers while Codex retains planning, risk control, review, and final acceptance. Keep `grok-orchestrator` independently usable.

## Current design

- Skill root: `$HOME\.codex\skills\multi-model-orchestrator\`
- Run root convention: `.codex/mmo-runs/YYYY-MM-DD-<slug>/`
- Provider contract and adapters: `references/provider-contract.md` + `scripts/Invoke-Provider.ps1`
- Routing and reasoning-tier policy: `references/routing-policy.md` + `config/model-registry.json`
- Task attributes (`ui` / `web_frontend` / `image_generation` + aliases): `Select-Model.ps1` / `Invoke-WithFallback.ps1` `-TaskAttributes`; visual group prefers eligible Agy `Gemini 3.5 Flash (High)` on non-difficult profiles; difficult Claude-first chain is never silently downgraded; `image_generation` is a routing affinity only
- Worktree isolation: `scripts/Allocate-Worktree.ps1`
- Failure classification: `scripts/Classify-Result.ps1` (context-aware; no bare 401/timeout false positives)
- Sequential fallback: `scripts/Invoke-FallbackChain.ps1` (explicit route) and `scripts/Invoke-WithFallback.ps1` (routing profile); both write every hop to `FALLBACKS.jsonl` and `fallback-summary.json`
- Selection snapshots: `selection-<worker>.json` (task-attribute audit fields when profile-driven)
- Watchdog: `scripts/Watch-Run.ps1` (artifact-progress stall detection; multi-worker aggregate mode)

## Local CLI snapshot (2026-07-17)

- Grok Build `0.2.102` discovered from the user installation.
  - Default model listed: `grok-4.5`
  - Flags of interest: `--model`, `--reasoning-effort`, `--single`/`-p`, `--cwd`, `--worktree`, `models`
- Antigravity CLI `1.1.3` discovered from the user installation.
  - Models observed via `agy models`: Gemini 3.5 Flash (Low/Medium/High), Gemini 3.1 Pro (Low/High), Claude Sonnet/Opus 4.6 (Thinking), GPT-OSS 120B (Medium)
  - Flags of interest: `--model`, `--print`/`-p`, `--prompt`, `--add-dir`, `models`
  - Not on default PATH in this session; discovery must search common install locations

## Decisions

- Reasoning tiers restricted to highest and second-highest only; never select low.
- Auto-fallback only on `quota_exhausted` or `model_unavailable` classification; auth/network/permission/timeout/task failures stop for Codex.
- Concurrent writers require separate Git worktrees; without Git/worktrees, parallelize read-only analysis and serialize writes.
- Process CWD is the Agy isolation boundary; `--add-dir` is supplementary.
- Grok headless defaults to `--always-approve`; concurrent specs may set `no_always_approve`.
- Provider hard timeout kills the full process tree with PID-reuse guards.
- Fake provider fixtures enable offline deterministic tests without network or credentials.
- Registry static aliases are hints; live discovery is authority. Refresh aliases when labels change. Selection never treats the registry as a permanent hardcoded model inventory.
- Explicit task attributes only (no unbounded NL classifier). Unknown attributes audited, ignored for routing.
- Simple mechanical backup is `Gemini 3.5 Flash (High)` (not Medium/Low).
- Precedence: safe explicit override > task attributes (non-difficult visual preference) > profile chain; difficult quality floor holds.
- No paid credits or credential changes as part of orchestration fallback.

## Verification

- Offline test suite path: `tests/Run-OfflineTests.ps1`
- Safe live checks: provider help/version/models only for first draft acceptance
- 2026-07-17 first draft: offline **22/22** passed; smoke **18/18** passed; `grok-orchestrator` left with original 4 files
- 2026-07-17 revision 1: offline **50/50** passed; parser **0** failures; concurrent success+quota fixture; Grok dry-build includes `--always-approve`; `grok-orchestrator` still 4 files
- 2026-07-17 hardening: offline **83/83** passed; parser **0** failures; invocation escaping, context-aware classifier, fallback runners + FALLBACKS.jsonl, discovery eligible/forbidden partition, watchdog CPU-stall fix, timeout tree cleanup, concurrent approval opt-out; run checkpoint `.codex/grok-runs/2026-07-17-mmo-hardening/`
- 2026-07-17 task-attribute routing: offline **104/104** passed; parser **0** failures; live discovery/models/version only; run `.codex/grok-runs/2026-07-17-task-attribute-routing/`
- 2026-07-17 **documentation refresh** (this stage): docs only (`SKILL.md`, `PROJECT_MEMORY.md`, `references/*.md`, `evals/prompts.md`); no behavior/API/registry/test changes; `config`/`scripts`/`tests` hashes match `BEFORE_CODE_HASHES.json`; offline suite **skipped** because `tests/Run-OfflineTests.ps1` writes `tests/last-offline-results.json` (baseline-protected generated output); lightweight Markdown/reference consistency scan run instead; run `.codex/grok-runs/2026-07-17-documentation-refresh/`

## Hardening design notes

- `Set-MmoProcessStartInfoArguments` / `ConvertTo-MmoEscapedArgument` for Windows-safe argv.
- `Stop-MmoProcessTree` shared helper; used by `Invoke-Provider` on hard timeout.
- `Classify-Result` prefers stderr/error-framed evidence; exit 0 + narrative 401/auth/timeout/dns stays success.
- `Discover-Providers` exposes `eligible_models` + `forbidden_models` while keeping raw `models`.
- `Invoke-FallbackChain.ps1` is the explicit-route sequential fallback runner; `Invoke-WithFallback.ps1` is the profile-driven entrypoint with the same hop-audit contract.
- Aggregate fallback artifact name is `fallback-summary.json` only (sole aggregate artifact emitted by fallback runners).
- `Normalize-MmoTaskAttributes` + registry `task_attributes` contract; `Select-Model` prepends visual preferred Flash High only for non-difficult profiles; attributes flow into selection artifacts and FALLBACKS Extra.

## Documentation map (user-facing)

| Doc | Role |
|---|---|
| `SKILL.md` | Concise skill entry: decision table, core rules, copyable sketches (<150 lines) |
| `references/routing-policy.md` | Full decision table, `-TaskAttributes` contract, precedence, fallback boundaries, examples |
| `references/run-artifacts.md` | `.codex/mmo-runs`, `FALLBACKS.jsonl`, `fallback-summary.json`, `selection-<worker>.json`, audit fields |
| `references/safety-rules.md` | Hard blocks + which classifications auto-fallback |
| `references/provider-contract.md` | Adapter surface for Grok / Agy |
| `evals/prompts.md` | Evaluation prompts including task-attribute routing |
