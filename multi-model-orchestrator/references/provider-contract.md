# Provider Contract

> Authored 2026-07-17. Documentation refresh 2026-07-17 (terminology alignment).

## Goal

Adapters for local CLIs must look the same to the orchestrator even as model lists and flags change.

## Required adapter surface

Every provider adapter exposes:

| Capability | Meaning |
|---|---|
| `Discover` | Resolve executable path, version, and available models |
| `Invoke` | Run a bounded headless prompt with cwd, model, and reasoning tier |
| `Normalize` | Produce a common result object from raw stdout/stderr/exit code |
| `Classify` | Map output to success, quota, auth, network, permission, or task failure |
| `SupportsWorktree` | Whether the provider can natively open a worktree or needs external allocation |

## Common invoke request

```json
{
  "provider": "grok|agy",
  "executable": "path",
  "model": "provider-specific id",
  "reasoning_tier": "highest|second_highest",
  "prompt_file": "path",
  "cwd": "path",
  "run_directory": "path",
  "worker_id": "w1",
  "timeout_seconds": 3600,
  "extra_args": []
}
```

## Common result object

```json
{
  "provider": "grok",
  "worker_id": "w1",
  "session_id": "optional",
  "model": "grok-4.5",
  "reasoning_tier": "highest",
  "exit_code": 0,
  "classification": "success",
  "fallback_eligible": false,
  "raw_stdout_path": ".../stdout.log",
  "raw_stderr_path": ".../stderr.log",
  "changed_paths": [],
  "summary": "one paragraph",
  "error_message": null,
  "started_at": "ISO-8601",
  "ended_at": "ISO-8601"
}
```

## Grok adapter notes

- Discover: `grok models`, `grok version`
- Invoke headless: `grok --cwd <cwd> --model <model> --reasoning-effort <effort> --always-approve --single <prompt>`
  or `--prompt-file`
- Default model hint: `grok-4.5`. Reasoning tiers map to provider efforts (highest → high, second_highest → medium); low is forbidden.
- `--always-approve` is the controlled default for non-interactive headless runs on this host (`Invoke-Provider.ps1`). Pass `-NoAlwaysApprove` only for intentional interactive sessions. Concurrent workers may set `no_always_approve: true` in the worker spec.
- Argument construction uses `Set-MmoProcessStartInfoArguments` (ArgumentList when runtime supports it; otherwise Windows-safe `Arguments` escaping). `UseShellExecute` remains false.
- Hard timeout kills the provider process tree via `Stop-MmoProcessTree` with PID-reuse protection from the recorded root start time.
- Invocation boundary rejects `low`/`lowest`/`minimal` reasoning and model labels with low tiers (case-insensitive), including values smuggled through `-ExtraArgs`.
- Optional native isolation: `--worktree` / `grok worktree`
- PID file for watchdog: write `workers/<id>/WORKER_PID.txt`; multi-worker index: `WORKER_PIDS.json`
- Concurrent launch: `scripts/Start-ConcurrentWorkers.ps1` starts multiple workers in parallel with isolated cwds
- Multi-worker watch: `scripts/Watch-Run.ps1 -AggregateWorkers` (stall detection uses artifact progress only; CPU-only spin does not refresh activity)
- Sequential fallback: `scripts/Invoke-FallbackChain.ps1` (route JSON) or `scripts/Invoke-WithFallback.ps1` (routing profile + optional `-TaskAttributes`); both write durable `FALLBACKS.jsonl` and `fallback-summary.json`. Explicit `-ExtraArgs` are forwarded one value per hop.

## Antigravity (`agy`) adapter notes

- Discover: `agy models`, `agy --version`. Raw `models` stay for transparency; `eligible_models` / `forbidden_models` mark selectable vs low/forbidden entries.
- Invoke headless: `agy --model <model> --print <prompt>` or `--prompt`
- Workspace isolation boundary: process `WorkingDirectory` (CWD) is primary. `--add-dir` is supplementary for additional roots and may mirror CWD; do not treat `--add-dir` alone as the isolation boundary.
- Model names often embed reasoning (High/Medium/Low/Thinking). Select by resolved model string; do not also force a forbidden low variant.
- Common resolved labels (when discovery lists them): Claude Opus/Sonnet Thinking, `Gemini 3.1 Pro (High)`, `Gemini 3.5 Flash (High)`.
- Executable may not be on PATH; search registry `common_paths`.
- Static aliases in `config/model-registry.json` are hints only; **live discovery remains the authority**. Refresh aliases when provider model labels change in practice.
- Task-attribute visual preference resolves alias `gemini-3.5-flash-high` against discovery eligible models—not a hardcoded permanent inventory.

## Extensibility

To add a future provider:

1. Add a key under `config/model-registry.json` → `providers`
2. Implement discover/invoke branches in the scripts (or a sibling adapter script)
3. Document flags and failure signatures here
4. Add offline fake fixture under `tests/fixtures/`

Do not bake permanent assumptions that only today's model IDs exist.
