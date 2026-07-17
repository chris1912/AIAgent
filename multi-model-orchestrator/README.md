# Multi-Model Orchestrator

Orchestrate local **Grok CLI** and **Antigravity (`agy`) CLI** workers with explicit model routing, isolated workspaces, quota-aware fallback, and Codex-owned acceptance.

## Features

- Dynamic provider and model discovery.
- Task-class routing with `highest` and `second_highest` reasoning tiers only.
- Task attributes for UI, web frontend, visual design, and image-generation affinity.
- Concurrent, debate, dual-implementation, and pipeline strategies.
- Git worktree isolation for concurrent writers.
- Durable per-hop fallback records and review artifacts.
- Low-tier model rejection and credential/paid-credit safety boundaries.

## Routing

| Task | Preferred model | Fallback |
| --- | --- | --- |
| UI/frontend/image affinity, non-difficult | Agy `Gemini 3.5 Flash (High)` | Profile chain |
| Architecture/security/migration/deep debug | Claude Opus/Sonnet Thinking | Gemini Pro High, then Grok `grok-4.5` highest |
| Ordinary implementation | Grok `grok-4.5` highest | Agy Flash High |
| Simple mechanical work | Grok `grok-4.5` second-highest | Agy Flash High |

Visual and image-generation attributes express routing affinity only; they do not guarantee that the local CLI can generate images. Difficult profiles remain Claude-first and are never silently downgraded by visual attributes.

## Quick Start

Run commands from this directory after both CLIs are installed and authenticated:

```powershell
# Discover currently available models
powershell -NoProfile -File scripts/Discover-Providers.ps1 `
  -OutJson .codex/mmo-runs/example/discovery.json

# Select a visual implementation model
powershell -NoProfile -File scripts/Select-Model.ps1 `
  -Profile ordinary_implementation `
  -DiscoveryJsonPath .codex/mmo-runs/example/discovery.json `
  -TaskAttributes ui,web_frontend `
  -OutJson .codex/mmo-runs/example/selection.json

# Run a profile-driven worker with audited fallback
powershell -NoProfile -File scripts/Invoke-WithFallback.ps1 `
  -RunDirectory .codex/mmo-runs/example `
  -RoutingProfile difficult_architecture `
  -DiscoveryJsonPath .codex/mmo-runs/example/discovery.json `
  -PromptFile .codex/mmo-runs/example/worker-prompt.md
```

Use `-TaskAttributes ui`, `web_frontend`, or `image_generation` when the task has a visual affinity. Unknown attributes are preserved for audit and do not change routing.

## Safety

Automatic fallback advances only for `quota_exhausted` or `model_unavailable`. Authentication, network, permission, timeout, and task failures stop for review. The orchestrator never purchases credits, changes credentials, or selects Low/Lowest/Minimal reasoning.

## Development

```powershell
powershell -NoProfile -File tests/Run-OfflineTests.ps1
```

See [`SKILL.md`](SKILL.md) and [`references/routing-policy.md`](references/routing-policy.md) for the complete contract and artifact format.
