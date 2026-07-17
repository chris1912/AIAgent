# Run Artifacts

> Authored 2026-07-17. Documentation refresh 2026-07-17 (task-attribute audit fields).

## Run directory

Create one dated directory per orchestrated task:

```text
.codex/mmo-runs/YYYY-MM-DD-<slug>/
```

Use this layout (files may be sparse early in a run):

```text
BRIEF.md
EXECUTION_LOG.md
STAGE_REPORT.md
REVIEW.md                 # Codex
ACCEPTANCE.md             # Codex
STATUS.json
PROJECT_MEMORY.md         # optional per-project pointer; skill-level memory stays in skill root
READY_FOR_REVIEW.flag     # exactly one sentinel when ready
DONE.flag | BLOCKED.flag | FAILED.flag
discovery.json
route-plan.json
selection-<worker_id>.json  # Select-Model snapshot per hop (Invoke-WithFallback); includes task_attributes
FALLBACKS.jsonl             # one JSON object per line (Invoke-FallbackChain / Invoke-WithFallback / Add-MmoFallbackRecord)
fallback-summary.json       # sole aggregate fallback runner summary (both entrypoints)
workers/
  <worker_id>/
    request.json
    stdout.log
    stderr.log
    result.json
    WORKER_PID.txt
worktrees/
  <worker_id>.json        # allocation metadata
WATCHDOG_STATUS.json
WATCHDOG_EVENTS.jsonl
```

### Naming consistency

| Artifact | Path / name | Writer |
|---|---|---|
| Run root | `.codex/mmo-runs/YYYY-MM-DD-<slug>/` | `New-RunDirectory.ps1` / orchestrator |
| Discovery cache | `discovery.json` | `Discover-Providers.ps1` |
| Per-hop selection | `selection-<worker>.json` | `Invoke-WithFallback.ps1` via Select-Model |
| Fallback log | `FALLBACKS.jsonl` | fallback runners |
| Fallback aggregate | `fallback-summary.json` | fallback runners (sole aggregate artifact emitted) |

## Task-attribute audit fields

### `selection-<worker>.json` (Select-Model output)

When `-TaskAttributes` is passed (or empty), selection JSON includes:

| Field | Meaning |
|---|---|
| `task_attributes.raw` | Tokens as supplied by the caller |
| `task_attributes.canonical` | Normalized canonical ids (`ui`, `web_frontend`, `image_generation`) |
| `task_attributes.unknown` | Tokens that did not match any alias (audited only) |
| `task_attributes.is_visual` | True when any visual-group attribute is present |
| `visual_preference_applied` | True when eligible Agy `Gemini 3.5 Flash (High)` was prepended for a non-difficult profile |
| `visual_preference_skipped_reason` | e.g. `difficult_task_quality_not_downgraded` when attrs ignored for quality floor |
| `route_notes` | Fall-through notes such as visual preferred absent/excluded |

### `FALLBACKS.jsonl` record shape

```json
{
  "timestamp": "ISO-8601",
  "reason": "quota_exhausted|model_unavailable|initial_attempt|...",
  "source_provider": "agy",
  "source_model": "...",
  "target_provider": "grok",
  "target_model": "grok-4.5",
  "reasoning_tier": "highest",
  "classification": "success|quota_exhausted|...",
  "fallback_eligible": true,
  "exit_code": 0,
  "worker_id": "fb3",
  "routing_profile": "ordinary_implementation",
  "task_attributes": ["ui"],
  "task_attributes_raw": ["ui"],
  "task_attributes_unknown": [],
  "visual_preference_applied": true,
  "selection_path": ".../selection-fb1.json"
}
```

`task_attributes*` / `visual_preference_applied` / `selection_path` appear when profile-driven fallback passes attributes through Select-Model. Explicit-route `Invoke-FallbackChain.ps1` may omit attribute fields when no selection step ran.

### `fallback-summary.json`

Sole aggregate artifact emitted by fallback runners. Aggregate outcome of a fallback run: final classification, hop count, last selection summary, and (when profile-driven) the canonical `task_attributes` used for the run.

## Sentinel rules

Write the report and `STATUS.json` **before** the sentinel flag. Exactly one of:

- `READY_FOR_REVIEW.flag`
- `DONE.flag`
- `BLOCKED.flag`
- `FAILED.flag`

should exist at stage end.

## STATUS.json minimum fields

```json
{
  "run_id": "2026-07-17-example",
  "stage": "implement-first-draft",
  "state": "ready_for_review",
  "strategy": "single",
  "session_id": "orchestrator-or-primary-worker",
  "providers": ["grok", "agy"],
  "models": ["grok-4.5"],
  "reasoning_tiers": ["highest"],
  "summary": "short",
  "next_action": "codex_review",
  "updated_at": "ISO-8601"
}
```

## Evidence standard

Retain:

- raw provider stdout/stderr
- normalized `result.json` per worker
- fallback reasons (`FALLBACKS.jsonl`, `fallback-summary.json`)
- selection snapshots (`selection-*.json`) when profile-driven
- changed paths (from worker report and/or git status)
- test command output
- final acceptance notes from Codex

Transcripts are evidence, not sole proof. Prefer filesystem, exit codes, and targeted diffs.

## Token discipline

Codex should read `STATUS.json` and `STAGE_REPORT.md` first. Open verbose logs only on failure, contradiction, or targeted verification.
