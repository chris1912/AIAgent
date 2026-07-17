# Safety Rules

> Authored 2026-07-17. Documentation refresh 2026-07-17 (fallback boundary wording).

## Hard boundaries

- Do not modify `grok-orchestrator` or any other existing skill unless the user explicitly expands scope.
- Do not modify secrets, credentials, Antigravity settings, or Grok configuration as part of orchestration.
- Do not install dependencies unless strictly necessary for the user's task; prefer PowerShell and existing CLIs.
- Do not commit, push, or publish unless the user explicitly requests it for that task.
- Do not run destructive commands, deploy services, or access external accounts without explicit authority.
- Do not auto-purchase or auto-enable paid credits when quota is exhausted.
- Do not invent credentials or change auth material during fallback.

## Writer isolation

- Two writers must never share a working directory concurrently.
- Prefer separate Git worktrees for concurrent implementation.
- If worktrees are unavailable: parallelize read-only analysis only; serialize all writes.
- Clean up allocated worktrees only when the run policy says so and after results are copied into the run directory.

## Failure handling (fallback boundaries)

Only **`quota_exhausted`** and **`model_unavailable`** advance the automatic fallback chain. All other failure classes stop for Codex review (or follow the BRIEF if it explicitly allows a single brief network retry).

| Classification | Auto-fallback? | Default stage outcome |
|---|---|---|
| `success` | no | continue / ready_for_review |
| `quota_exhausted` | **yes** | try next preferred model/provider |
| `model_unavailable` | **yes** | try next preferred model/provider |
| `auth_failure` | no | blocked — stop for Codex |
| `network_failure` | no | blocked or retry once if BRIEF allows — stop for Codex after that |
| `permission_failure` | no | blocked — stop for Codex |
| `task_failure` | no | revise or failed — stop for Codex |
| `timeout` | no | stalled/failed per watchdog — stop for Codex |
| `unknown_error` | no | inspect; prefer blocked over blind retry |

Record every auto-fallback hop in `FALLBACKS.jsonl` and summarize in `fallback-summary.json`. Never enable paid credits or mutate credentials to “fix” quota.

## Codex intervention

Pause or take over when an action risks:

- secret exfiltration or credential mutation
- destructive data loss
- public exposure / unauthorized deployment
- account automation / CAPTCHA bypass
- unbounded external side effects

Use at most two normal revision loops for the same defect, then block, narrow, switch model within policy, take over, or end.

## Watchdog

For stages expected to exceed five minutes, attach `scripts/Watch-Run.ps1`. Treat stall as intervention, not automatic success. Terminate only the process tree launched for the run, and only when timeout policy explicitly permits it.
