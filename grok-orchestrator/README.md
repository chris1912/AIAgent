# Grok Orchestrator / Grok 编排器

Standalone Codex skill for delegating bounded repository work to a local Grok CLI while Codex owns planning, risk control, and final acceptance.

面向 Codex 的独立 skill：将有界的仓库工作委托给本地 Grok CLI，同时由 Codex 负责规划、风险控制和最终验收。

## Features / 功能

- Dynamic `grok models` and `grok version` discovery before structured invocation.  
  结构化调用前动态发现 `grok models` 和 `grok version`。
- Windows-safe prompt, argument, cwd, timeout, process-tree, and PID-reuse handling.  
  提供 Windows 安全的提示词、参数、工作目录、超时、进程树和 PID 复用处理。
- Highest and second-highest reasoning tiers only; low tiers are rejected before provider contact.  
  仅允许最高和次高思考等级；联系提供方前拒绝低等级。
- Context-aware result classification and Grok-only fallback for quota/model-unavailable failures.  
  上下文感知的结果分类，以及针对配额耗尽/模型不可用的仅 Grok 回退。
- Durable run artifacts, review checkpoints, watchdog monitoring, and offline fake-Grok tests.  
  持久化运行产物、评审检查点、看门狗监控和离线 fake-Grok 测试。

## Requirements / 环境要求

- Windows PowerShell 5.1 or later. / Windows PowerShell 5.1 或更高版本。
- A local `grok` CLI installation and an authenticated session. / 已安装本地 `grok` CLI，并完成登录认证。
- Codex or another host that can execute PowerShell scripts. / 能执行 PowerShell 脚本的 Codex 或其他宿主环境。

Model availability is always determined by live discovery; the registry is only a hint.

模型可用性始终由现场发现决定，注册表仅提供提示。

## Installation / 安装

Copy this directory into the skill directory used by your Codex installation. Do not copy `.codex` run artifacts or local generated reports into a public repository.

将此目录复制到 Codex 使用的 skill 目录。不要将 `.codex` 运行产物或本地生成报告复制到公开仓库。

Verify the CLI before a structured run. / 在结构化运行前验证 CLI：

```powershell
grok version
grok models
```

## Usage / 使用

Create a run brief, discover available models, then invoke a bounded stage.

创建运行简报，发现可用模型，然后调用一个有界阶段。

```powershell
powershell -NoProfile -File scripts/Discover-Grok.ps1 `
  -OutJson .codex/grok-runs/example/discovery.json `
  -RequireAvailable

powershell -NoProfile -File scripts/Invoke-Grok.ps1 `
  -RunDirectory .codex/grok-runs/example `
  -DiscoveryJsonPath .codex/grok-runs/example/discovery.json `
  -Model grok-4.5 `
  -ReasoningTier highest `
  -PromptFile .codex/grok-runs/example/BRIEF.md `
  -Cwd <project> `
  -TimeoutSeconds 3600
```

Use the documented direct `grok` command only for manual compatibility handoffs. It does not provide the structured runner's discovery gate, result envelope, classification, or fallback contract.

仅将文档中的直接 `grok` 命令用于手动兼容交接。它不提供结构化运行器的发现门控、结果信封、分类或回退契约。

## Verification / 验证

Run the deterministic offline suite from this directory.

在本目录运行确定性的离线测试套件：

```powershell
powershell -NoProfile -NonInteractive -File tests/Run-OfflineTests.ps1
```

The latest development evidence records 62 passed and 0 failed checks, including PowerShell 5.1 parsing, argument escaping, discovery gates, fallback boundaries, timeout cleanup, watchdog behavior, and sentinel ordering.

最新开发证据记录 62 项通过、0 项失败，其中包括 PowerShell 5.1 解析、参数转义、发现门控、回退边界、超时清理、看门狗行为和哨兵顺序。

## Limitations / 限制

- This skill orchestrates Grok only; it does not import or control Antigravity or other providers. / 本 skill 仅编排 Grok，不导入或控制 Antigravity 或其他提供方。
- Composer is used only when live discovery lists it. / 仅当现场发现结果列出 Composer 时才使用它。
- Optional MCP warnings may appear in raw stderr; exit-zero warning-only output is classified as success. / 原始 stderr 可能出现可选 MCP 警告；仅有 exit-zero 警告时分类为成功。
- Offline tests do not imply a paid or long-running coding task. / 离线测试不代表执行了付费或长时间编码任务。

## Security / 安全

Never commit credentials, `.env` files, private keys, raw provider logs containing secrets, or absolute local workspace paths. Review the publication set before pushing and enable GitHub Secret Protection and push protection where available.

绝不要提交凭证、`.env` 文件、私钥、含有秘密的原始提供方日志或本地绝对工作区路径。推送前审核发布文件集，并在条件允许时启用 GitHub Secret Protection 和 push protection。

Report suspected vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).

按照 [`SECURITY.md`](SECURITY.md) 的说明私下报告疑似漏洞。

## License / 许可证

This project is released under the MIT License. See [`LICENSE`](LICENSE).

本项目采用 MIT 许可证。详见 [`LICENSE`](LICENSE)。

## Documentation / 文档

- [`SKILL.md`](SKILL.md): complete Codex skill contract / 完整 Codex skill 契约
- [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md): design decisions and verification notes / 设计决策与验证记录
- [`references/provider-contract.md`](references/provider-contract.md): provider and fallback contract / 提供方与回退契约
- [`references/run-artifacts.md`](references/run-artifacts.md): durable run artifacts / 持久化运行产物
- [`references/watchdog-protocol.md`](references/watchdog-protocol.md): stall and timeout protocol / 停滞与超时协议
