# Multi-Model Orchestrator / 多模型编排器

Orchestrate local **Grok CLI** and **Antigravity (`agy`) CLI** workers with explicit model routing, isolated workspaces, quota-aware fallback, and Codex-owned acceptance.

通过显式模型路由、隔离工作区、配额感知回退和 Codex 最终验收，编排本地 **Grok CLI** 与 **Antigravity (`agy`) CLI** 工作者。

## Features / 功能

- Dynamic provider and model discovery. / 动态发现提供方和模型。
- Task-class routing with `highest` and `second_highest` reasoning tiers only. / 按任务类别路由，且仅使用最高和次高思考等级。
- Task attributes for UI, web frontend, visual design, and image-generation affinity. / 支持 UI、网页前端、视觉设计和生图倾向等任务属性。
- Concurrent, debate, dual-implementation, and pipeline strategies. / 支持并发、辩论、双实现和流水线策略。
- Git worktree isolation for concurrent writers. / 使用 Git worktree 隔离并发写入者。
- Durable per-hop fallback records and review artifacts. / 持久化记录每次回退和评审产物。
- Low-tier model rejection and credential/paid-credit safety boundaries. / 拒绝低思考等级，并设置凭据与付费额度安全边界。

## Routing / 路由

| Task | Preferred model | Fallback |
| --- | --- | --- |
| UI/frontend/image affinity, non-difficult | Agy `Gemini 3.5 Flash (High)` | Profile chain |
| Architecture/security/migration/deep debug | Claude Opus/Sonnet Thinking | Gemini Pro High, then Grok `grok-4.5` highest |
| Ordinary implementation | Grok `grok-4.5` highest | Agy Flash High |
| Simple mechanical work | Grok `grok-4.5` second-highest | Agy Flash High |

Visual and image-generation attributes express routing affinity only; they do not guarantee that the local CLI can generate images. Difficult profiles remain Claude-first and are never silently downgraded by visual attributes.

视觉和生图属性只表达路由倾向，不保证本地 CLI 能生成图像。困难任务仍优先 Claude，且不会因视觉属性被静默降级。

## Quick Start / 快速开始

Run commands from this directory after both CLIs are installed and authenticated. / 安装并登录两个 CLI 后，在本目录执行：

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

任务具有视觉倾向时，使用 `-TaskAttributes ui`、`web_frontend` 或 `image_generation`。未知属性会保留用于审计，但不会改变路由。

## Safety / 安全

Automatic fallback advances only for `quota_exhausted` or `model_unavailable`. Authentication, network, permission, timeout, and task failures stop for review. The orchestrator never purchases credits, changes credentials, or selects Low/Lowest/Minimal reasoning.

自动回退仅在 `quota_exhausted` 或 `model_unavailable` 时前进。认证、网络、权限、超时和任务失败会停止并等待审查。编排器不会购买额度、修改凭据或选择 Low/Lowest/Minimal 思考等级。

## Development / 开发验证

```powershell
powershell -NoProfile -File tests/Run-OfflineTests.ps1
```

The latest recorded offline suite result is 104/104. / 最近记录的离线测试结果为 104/104。

See [`SKILL.md`](SKILL.md) and [`references/routing-policy.md`](references/routing-policy.md) for the complete contract and artifact format.

完整契约和产物格式见 [`SKILL.md`](SKILL.md) 与 [`references/routing-policy.md`](references/routing-policy.md)。
