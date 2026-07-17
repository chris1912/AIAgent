# Routing Policy

> Authored 2026-07-17. Task attributes the same day. Documentation refresh 2026-07-17 (terminology + operational clarity).

## Reasoning tiers

Only two tiers may be selected:

1. **highest** — ordinary and difficult tasks
2. **second_highest** — simple mechanical tasks only

Never select low/lowest/minimal. If a provider exposes only one non-low tier, use that single allowed tier for all task classes.

### Mapping examples

| Provider signal | Tier mapping |
|---|---|
| Grok efforts `high` > `medium` > `low` | highest=`high`, second_highest=`medium` |
| Agy `Gemini 3.5 Flash (High/Medium/Low)` | highest=High, second_highest=Medium; Low forbidden |
| Agy Claude `*(Thinking)` | Treat Thinking as highest; no low variant may be chosen |
| Agy `Gemini 3.1 Pro (High/Low)` | highest=High; Low forbidden; if only High remains usable, use High even for simple |

## Decision table: task class + task attributes

| Task class | Profile keys | Visual attrs present? | Preferred order (eligible only) | Reasoning tier |
|---|---|---|---|---|
| difficult | `difficult_architecture`, `difficult_security`, `difficult_migration`, `difficult_debug` | ignored for prepending | 1) Claude Opus Thinking 2) Claude Sonnet Thinking 3) Gemini 3.1 Pro High 4) Grok `grok-4.5` **highest** | highest |
| ordinary | `ordinary_implementation` | yes (`ui` / `web_frontend` / `image_generation`) | 1) Agy `Gemini 3.5 Flash (High)` 2) Grok `grok-4.5` highest 3) Flash High (profile backup if not already selected) | highest |
| ordinary | `ordinary_implementation` | no | 1) Grok `grok-4.5` **highest** 2) Agy `Gemini 3.5 Flash (High)` | highest |
| simple | `simple_mechanical` | yes | 1) Agy `Gemini 3.5 Flash (High)` 2) Grok `grok-4.5` second_highest | second_highest (Grok); Flash High uses its High label |
| simple | `simple_mechanical` | no | 1) Grok `grok-4.5` **second-highest** 2) Agy `Gemini 3.5 Flash (High)` (never Low/Medium as backup) | second_highest |

Notes:

- **Difficult quality floor:** visual attributes never insert Flash High ahead of Claude Thinking. Audit field: `visual_preference_skipped_reason = difficult_task_quality_not_downgraded`.
- **Quota / model-unavailable** on a difficult chain advances automatically along the preferred order and can reach Grok `grok-4.5` at highest without purchasing credits.
- **`image_generation`** (and aliases) is a **routing affinity** toward eligible Agy Flash High. It does not assert that the local CLI can generate images—only that selection prefers that model when discovery marks it eligible.
- Selection always resolves models via **live discovery** (`Discover-Providers.ps1`) and registry **aliases**. Static aliases in `config/model-registry.json` are hints; they are not a permanent hardcoded inventory.

## Task attributes (explicit contract)

Callers may pass a small explicit list to `Select-Model.ps1` and `Invoke-WithFallback.ps1` via **`-TaskAttributes`**.

This is **not** an unbounded natural-language classifier. Free-text task descriptions are **not** scanned or auto-mapped. Only the tokens below (or their aliases) affect routing.

| Canonical | Accepted aliases (normalized) | Intent |
|---|---|---|
| `ui` | `interface`, `ui_design`, `visual`, `visual_design` | UI / interface / visual design work |
| `web_frontend` | `frontend`, `web`, `web-frontend` | Web frontend implementation |
| `image_generation` | `image`, `images`, `image-generation`, `img`, `img_gen` | Image / visual generation **routing affinity** |

### Contract rules

- **Unknown tokens** are kept for audit (`task_attributes.unknown`) and **do not** change the route.
- Normalization is case-insensitive; spaces and hyphens become underscores where applicable.
- Comma-joined values are accepted under `powershell -File` (e.g. `-TaskAttributes ui,web_frontend` or `-TaskAttributes image`).
- Selection output, `selection-<worker>.json`, and `FALLBACKS.jsonl` Extra fields carry normalized attributes for audit (`task_attributes`, `task_attributes_raw`, `task_attributes_unknown`, `visual_preference_applied`, `selection_path` when present).

### Attribute influence

When any visual-group attribute is present **and** the profile task class is **not** `difficult`:

1. Prefer eligible Antigravity alias `gemini-3.5-flash-high` → live-resolved `Gemini 3.5 Flash (High)` **before** the ordinary/simple profile chain.
2. Resolve only via registry alias against discovery eligible models. Never hardcode availability or bypass eligibility/low gates.
3. If that model is missing, excluded, or the provider executable is unavailable, continue on the profile preferred chain. `route_notes` may record `visual_preferred_absent_or_excluded_continue_profile`.

## Precedence (highest authority first)

1. **Safe explicit override** (`-OverrideProvider` + `-OverrideModel` / `-OverrideModelAlias`, optional override reasoning tier) — authoritative when the model is policy-safe (not low) and selectable. If absent/ineligible, continue on the attribute/profile chain.
2. **Task attributes** — adjust preferred order for **non-difficult** profiles only (visual prepend).
3. **Routing profile preferred chain** — difficulty-based defaults from `config/model-registry.json`.
4. **Difficult quality floor** — never insert a lower-quality visual shortcut ahead of Claude on difficult profiles.

## Preferred chains (profile defaults)

### Difficult architecture / migration / security / deep debug

1. Antigravity Claude Opus Thinking  
2. Antigravity Claude Sonnet Thinking  
3. Antigravity Gemini 3.1 Pro High  
4. Grok `grok-4.5` at **highest** reasoning  

### Ordinary implementation / tests / documentation

1. Grok `grok-4.5` at **highest**  
2. Antigravity `Gemini 3.5 Flash (High)`  

With visual attributes: Flash High is tried first, then this chain.

### Simple mechanical

1. Grok `grok-4.5` at **second-highest**  
2. Antigravity `Gemini 3.5 Flash (High)` (documented backup; never Low/Medium as the simple backup)

With visual attributes: Flash High is tried first, then this chain.

## Fallback boundaries

| Classification | Auto-advance? | Codex action |
|---|---|---|
| `quota_exhausted` | **yes** | try next preferred model/provider |
| `model_unavailable` | **yes** | try next preferred model/provider |
| `auth_failure` | no | stop / blocked |
| `network_failure` | no | stop / blocked (or single brief retry only if BRIEF allows) |
| `permission_failure` | no | stop / blocked |
| `timeout` | no | stop / stalled per watchdog |
| `task_failure` | no | revise or failed |
| `unknown_error` | no | inspect; prefer blocked over blind retry |

- Do **not** auto-enable or purchase paid credits.
- Do **not** change credentials or provider settings as part of fallback.
- Execute hops with `scripts/Invoke-FallbackChain.ps1` (explicit route JSON) or `scripts/Invoke-WithFallback.ps1` (routing profile + Select-Model + optional `-TaskAttributes`).
- Record every hop in `FALLBACKS.jsonl` (timestamp, reason, source/target provider/model, reasoning tier, classification, task-attribute audit fields when present). Write aggregate `fallback-summary.json`.
- Re-apply the highest/second-highest-only policy gate on every hop.
- After the chain is exhausted, set `BLOCKED.flag` or `FAILED.flag` and stop for Codex.

## Strategy routing

| Strategy | Provider selection | Write isolation |
|---|---|---|
| `single` | One profile pick | Shared cwd allowed |
| `parallel` | One pick per independent subtask | Worktree per writer |
| `debate` | Two+ models same prompt | Read-only parallel; one synthesizer write |
| `dual-implementation` | Two providers or two models | Worktree per writer; Codex compares |
| `pipeline` | Ordered profile picks | One active writer; artifact handoff |

## Conflict resolution

- User-explicit model/provider overrides the default chain unless it violates safety or the two-tier reasoning rule.
- If Claude is requested but missing from discovery, continue at Gemini Pro High / Grok without pretending Claude ran.
- If visual preferred Flash High is missing/excluded, continue on the profile chain without inventing availability.
- If Git worktrees cannot be allocated for a multi-writer strategy, degrade: read-only parallel analysis if applicable, then serialize writes; note the degradation in `STAGE_REPORT.md`.

## PowerShell examples (copyable)

Paths assume the skill root is the current directory. Replace `run` with a real run directory under `.codex/mmo-runs/YYYY-MM-DD-<slug>/`.

```powershell
# 1) Live discovery — authority for available models
powershell -NoProfile -File scripts/Discover-Providers.ps1 -OutJson run/discovery.json

# 2) Select: ordinary UI/frontend → eligible Agy Gemini 3.5 Flash (High) first
powershell -NoProfile -File scripts/Select-Model.ps1 `
  -Profile ordinary_implementation `
  -DiscoveryJsonPath run/discovery.json `
  -TaskAttributes ui,web_frontend `
  -OutJson run/selection.json

# 3) Select: simple mechanical (Grok second-highest first; Flash High backup)
powershell -NoProfile -File scripts/Select-Model.ps1 `
  -Profile simple_mechanical `
  -DiscoveryJsonPath run/discovery.json `
  -OutJson run/selection-simple.json

# 4) Select: difficult + visual attrs — Claude first (no silent downgrade)
powershell -NoProfile -File scripts/Select-Model.ps1 `
  -Profile difficult_architecture `
  -DiscoveryJsonPath run/discovery.json `
  -TaskAttributes ui `
  -OutJson run/selection-difficult.json

# 5) Invoke-WithFallback: visual ordinary task (attribute audit on every hop)
powershell -NoProfile -File scripts/Invoke-WithFallback.ps1 `
  -RunDirectory run `
  -RoutingProfile ordinary_implementation `
  -DiscoveryJsonPath run/discovery.json `
  -TaskAttributes image `
  -PromptFile run/worker-prompt.md

# 6) Invoke-WithFallback: difficult task — Claude-first chain; quota/unavailable can reach Grok highest
powershell -NoProfile -File scripts/Invoke-WithFallback.ps1 `
  -RunDirectory run `
  -RoutingProfile difficult_architecture `
  -DiscoveryJsonPath run/discovery.json `
  -TaskAttributes ui `
  -PromptFile run/worker-prompt.md

# 7) Safe explicit override (still low-gate checked)
powershell -NoProfile -File scripts/Select-Model.ps1 `
  -Profile ordinary_implementation `
  -DiscoveryJsonPath run/discovery.json `
  -OverrideProvider grok -OverrideModel grok-4.5 -OverrideReasoningTier highest
```

Artifacts produced by profile-driven fallback (when used): `selection-<worker>.json`, `FALLBACKS.jsonl`, `fallback-summary.json`. See [run-artifacts.md](run-artifacts.md).
