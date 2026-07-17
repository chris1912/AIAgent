---
name: multi-model-orchestrator
description: Orchestrate local Grok CLI and Antigravity (agy) CLI with multi-strategy routing, worktree isolation, quota-aware fallback, and Codex-owned acceptance. Use when the user wants multi-model execution, parallel/debate/dual-implementation/pipeline worker strategies, grok+agy orchestration, or provider fallback across local CLIs.
---

# Multi-Model Orchestrator

## Roles

- **Codex** owns planning, risk control, review, and final acceptance.
- **Workers** (`grok`, `agy` / Antigravity) execute only the current bounded stage.
- Keep `grok-orchestrator` unchanged and independently usable for Grok-only runs.

## When to use

Prefer this skill when the task needs multiple local providers, concurrent isolated writers, strategy selection (`single` / `parallel` / `debate` / `dual-implementation` / `pipeline`), or automatic quota/model-unavailable fallback.

## Decision table (task class + attributes)

| Situation | First pick (when eligible) | Then / fallback |
|---|---|---|
| Visual attrs (`ui`, `web_frontend`, `image_generation`) on **non-difficult** work | Agy `Gemini 3.5 Flash (High)` | Profile chain (ordinary or simple) |
| Difficult architecture / security / migration / deep debug | Claude Opus/Sonnet Thinking | Gemini 3.1 Pro High → Grok `grok-4.5` **highest** |
| Generic simple mechanical (no visual attrs) | Grok `grok-4.5` **second-highest** | Agy `Gemini 3.5 Flash (High)` |
| Generic ordinary (no visual attrs) | Grok `grok-4.5` **highest** | Agy `Gemini 3.5 Flash (High)` |

`image_generation` is a **routing affinity** only (prefer Flash High when eligible). Do not treat it as a promise that the local CLI can execute image generation.

Full policy, attributes, precedence, and fallback boundaries: [references/routing-policy.md](references/routing-policy.md).

## Core rules

1. Write a dated run under `.codex/mmo-runs/YYYY-MM-DD-<slug>/` before any worker launch. See [references/run-artifacts.md](references/run-artifacts.md).
2. Select strategy and providers from the brief; never invent credentials or enable paid credits.
3. Discover models dynamically (`scripts/Discover-Providers.ps1`). Cache in the run dir; selection uses **live discovery + registry aliases**, not a permanent hardcoded inventory.
4. Reasoning tiers are only **highest** and **second-highest**. Ordinary/difficult → highest; simple → second-highest. Never select low.
5. Pass explicit `-TaskAttributes` when UI/frontend/image routing affinity is desired. Arbitrary natural-language text is **not** auto-classified.
6. Precedence: safe explicit override → task attributes (non-difficult visual preference) → profile chain. Difficult quality is **never** silently downgraded.
7. Never let two writers share one working directory. Use Git worktrees (`scripts/Allocate-Worktree.ps1`). If unavailable, parallelize read-only analysis and serialize writes.
8. Only `quota_exhausted` and `model_unavailable` auto-advance fallback; auth/network/permission/timeout/task failures stop for Codex. No paid credits or credential changes.
9. Record every fallback hop in `FALLBACKS.jsonl`; aggregate in `fallback-summary.json`; write `selection-<worker>.json` per hop when using profile-driven selection.
10. End every stage at a review checkpoint with `STAGE_REPORT.md`, `STATUS.json`, and exactly one sentinel flag.
11. Follow [references/safety-rules.md](references/safety-rules.md) for blocks and takeovers.

## Workflow

1. Inspect workspace, Git status, available providers, and `PROJECT_MEMORY.md`.
2. Write `BRIEF.md` (objective, strategy, allowed paths, forbidden actions, acceptance checks).
3. Discover providers/models; select via registry + routing policy (+ optional `-TaskAttributes`).
4. Allocate isolated workspaces for concurrent writers.
5. Invoke via `scripts/Invoke-Provider.ps1` (Grok headless defaults to `--always-approve`) or `scripts/Start-ConcurrentWorkers.ps1` for multi-writer. Watch multi-worker runs with `scripts/Watch-Run.ps1 -AggregateWorkers`.
6. On quota/model-unavailable, run `scripts/Invoke-WithFallback.ps1` (profile) or `scripts/Invoke-FallbackChain.ps1` (explicit route). Low tiers are rejected at every hop.
7. Stop for Codex: `STAGE_REPORT.md`, `STATUS.json`, `READY_FOR_REVIEW.flag`.
8. Codex records `REVIEW.md`, optionally revises at most twice for the same defect, then `ACCEPTANCE.md`.

## Strategies

| Strategy | Intent | Isolation |
|---|---|---|
| `single` | One provider, one stage | Shared cwd OK |
| `parallel` | Independent subtasks | Worktree per writer |
| `debate` | Same question, independent analyses | Read-only parallel, serialize synthesis |
| `dual-implementation` | Two implementations of one task | Worktree per writer |
| `pipeline` | Ordered stages, different models | Artifact handoff; one active writer |

Details: [references/provider-contract.md](references/provider-contract.md).

## Invocation sketch

```powershell
# Live discovery (authority for available models)
powershell -NoProfile -File scripts/Discover-Providers.ps1 -OutJson run/discovery.json

# Visual ordinary task → eligible Agy Gemini 3.5 Flash (High) first
powershell -NoProfile -File scripts/Select-Model.ps1 `
  -Profile ordinary_implementation -DiscoveryJsonPath run/discovery.json `
  -TaskAttributes ui,web_frontend -OutJson run/selection.json

# Difficult: Claude first; attributes do not downgrade; quota/unavailable can reach Grok highest
powershell -NoProfile -File scripts/Invoke-WithFallback.ps1 `
  -RunDirectory run -RoutingProfile difficult_architecture `
  -DiscoveryJsonPath run/discovery.json -TaskAttributes ui `
  -PromptFile run/worker-prompt.md

# Visual ordinary with attribute audit on every hop
powershell -NoProfile -File scripts/Invoke-WithFallback.ps1 `
  -RunDirectory run -RoutingProfile ordinary_implementation `
  -DiscoveryJsonPath run/discovery.json -TaskAttributes image `
  -PromptFile run/worker-prompt.md

# Single worker invoke
powershell -NoProfile -File scripts/Invoke-Provider.ps1 `
  -Provider grok -PromptFile run/worker-prompt.md -RunDirectory run `
  -Model grok-4.5 -ReasoningTier highest -Cwd <project>
```

More examples: [references/routing-policy.md](references/routing-policy.md).

## Offline verification

Run `tests/Run-OfflineTests.ps1` after skill **code** edits. Live CLI smoke checks should be help/models/version only unless the user authorizes a paid/long run.

## Evals

See [evals/prompts.md](evals/prompts.md) for single, parallel, isolation, quota fallback, task-attribute routing, provider failure, no-Git fallback, and safety blocking.
