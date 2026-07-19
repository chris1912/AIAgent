# AIAgent Toolbox / AI Agent 工具箱

## Summary / 项目简介

AIAgent Toolbox is a personal collection of authored, adapted, and experimental skills, plugins, and command-line helpers for AI coding agents. The repository focuses on explicit routing, bounded delegation, reproducible artifacts, and human-controlled acceptance.

AIAgent Toolbox 是一个个人维护的 AI 编程代理工具集合，收录原创、二次开发和实验性的 Skill、插件及命令行辅助工具。仓库重点关注显式路由、有界委派、可复核运行产物，以及由使用者掌握最终验收权。

This repository is a workshop rather than a single application. Each top-level directory is independently installable and documents its own requirements and limitations.

本仓库是持续演进的工具工坊，而不是单一应用。每个顶级目录均可独立安装，并分别说明环境要求与已知限制。

## Current Projects / 当前项目

| Project / 项目 | Purpose / 用途 | Providers / 提供方 | Status / 状态 |
| --- | --- | --- | --- |
| [`grok-orchestrator`](grok-orchestrator/) | Safe, bounded delegation from Codex to a local Grok CLI. / 由 Codex 安全、有界地委派本地 Grok CLI。 | Grok | Offline checks: 62/62 / 离线检查：62/62 |
| [`multi-model-orchestrator`](multi-model-orchestrator/) | Attribute-aware routing, fallback, and isolated parallel work across local model CLIs. / 面向本地模型 CLI 的任务属性路由、回退与隔离并行执行。 | Grok, Antigravity (`agy`) | Offline checks: 104/104 / 离线检查：104/104 |
| [`codex-thread-rename`](codex-thread-rename/) | Safe preview, review, and synchronization for renaming local Codex history. / 安全预览、核查并同步重命名 Codex 本地历史对话。 | Codex local state | Self-check passed / 自检通过 |

Recorded test counts describe the latest documented development evidence; they do not guarantee that an external provider, model, or quota is currently available.

表中的测试数量来自最近一次开发记录，不保证外部提供方、模型或额度当前仍然可用。

## Design Principles / 设计原则

- **Host-owned control:** Codex plans, approves risk, reviews evidence, and accepts results. / **宿主掌控：** Codex 负责规划、风险批准、证据审查和最终验收。
- **Live discovery:** installed CLI output is authoritative; static model registries are hints. / **动态发现：** 以本地 CLI 的实时输出为准，静态模型注册表仅作提示。
- **High-quality reasoning:** orchestration rejects low reasoning tiers. / **高质量推理：** 编排层拒绝低思考等级。
- **Bounded fallback:** only quota or model-unavailable failures advance automatically. / **有限回退：** 仅配额耗尽或模型不可用时自动切换。
- **Auditable runs:** important decisions and provider hops are written to durable artifacts. / **过程可审计：** 重要决策和提供方切换均写入持久化产物。
- **Safe concurrency:** concurrent writers use isolated Git worktrees. / **安全并发：** 并发写入者使用隔离的 Git worktree。

## Requirements / 环境要求

- Windows PowerShell 5.1 or later. / Windows PowerShell 5.1 或更高版本。
- Codex or another host capable of running local PowerShell scripts. / 可运行本地 PowerShell 脚本的 Codex 或其他宿主。
- The provider CLIs required by the selected project, installed and authenticated by the user. / 已由用户安装并登录目标子项目所需的提供方 CLI。

No project automatically purchases credits, changes credentials, or bypasses provider authentication.

任何项目都不会自动购买额度、修改凭据或绕过提供方认证。

## Installation / 安装

Clone the repository, then copy only the desired project directory into the skill directory used by your Codex installation.

克隆仓库，然后仅将需要的项目目录复制到 Codex 使用的 Skill 目录。

```powershell
git clone https://github.com/chris1912/AIAgent.git
Copy-Item -Recurse -Force .\AIAgent\<project-name> "$HOME\.codex\skills\<project-name>"
```

Read the selected project's README before running it because provider and authentication requirements differ.

运行前请阅读对应项目的 README，因为各项目需要的提供方和认证条件不同。

## Usage / 使用

Use the single-provider project when one Grok worker is sufficient; use the multi-model project when task-aware routing, provider fallback, debate, pipelines, or concurrent workers are required.

只需要一个 Grok 工作者时使用单提供方项目；需要任务属性路由、跨提供方回退、辩论、流水线或并发工作者时使用多模型项目。

- [`grok-orchestrator/README.md`](grok-orchestrator/README.md): setup and bounded Grok invocation / Grok 安装与有界调用。
- [`multi-model-orchestrator/README.md`](multi-model-orchestrator/README.md): provider discovery and profile-driven routing / 提供方发现与配置驱动路由。

## Verification / 验证

Run each project's deterministic offline suite without contacting paid models.

执行各项目的确定性离线测试，无需调用付费模型。

```powershell
powershell -NoProfile -NonInteractive -File .\grok-orchestrator\tests\Run-OfflineTests.ps1
powershell -NoProfile -NonInteractive -File .\multi-model-orchestrator\tests\Run-OfflineTests.ps1
```

Live smoke checks should normally be limited to CLI help, version, and model discovery unless a paid or long-running task is explicitly authorized.

除非明确授权付费或长时间任务，在线冒烟检查通常应限制为 CLI 帮助、版本和模型发现。

## Repository Structure / 仓库结构

```text
AIAgent/
├── grok-orchestrator/          # Grok-only orchestration / 仅 Grok 编排
├── multi-model-orchestrator/   # Multi-provider orchestration / 多提供方编排
├── codex-thread-rename/        # Codex local thread renaming / Codex 本地对话改名
├── .github/                    # Issue and pull-request templates / Issue 与 PR 模板
└── README.md                   # Repository entry point / 仓库入口
```

Future tools should remain independently documented and avoid hidden coupling to sibling directories.

后续工具应保持独立文档，避免与同级目录形成隐式耦合。

## Limitations / 限制

- The scripts are currently Windows- and PowerShell-oriented. / 脚本当前主要面向 Windows 与 PowerShell。
- Provider CLIs and model labels can change without notice; live discovery remains authoritative. / 提供方 CLI 与模型标签可能随时变化，应以实时发现为准。
- Visual or image-generation task attributes express routing preference, not guaranteed media generation capability. / 视觉或生图任务属性只表示路由偏好，不保证 CLI 具备媒体生成能力。
- Offline tests validate orchestration behavior, not provider service quality. / 离线测试验证编排行为，不代表提供方服务质量。

## Contributing and Support / 贡献与支持

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before proposing changes. Use GitHub Issues for reproducible bugs, feature proposals, and documentation problems; read [`SUPPORT.md`](SUPPORT.md) for scope.

提交修改前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)。可通过 GitHub Issues 报告可复现缺陷、提出功能建议或文档问题；支持范围见 [`SUPPORT.md`](SUPPORT.md)。

## Security / 安全

Do not publish credentials, raw provider logs, `.env` files, private keys, or personal absolute paths. Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md), and enable GitHub Secret Protection and push protection where available.

不要公开凭据、原始提供方日志、`.env` 文件、私钥或个人绝对路径。请按 [`SECURITY.md`](SECURITY.md) 私下报告漏洞，并在条件允许时启用 GitHub Secret Protection 和推送保护。

## License / 许可证

Unless a subdirectory states otherwise, original repository contributions are released under the MIT License. Third-party or adapted material remains subject to its original license and attribution requirements. See [`LICENSE`](LICENSE).

除非子目录另有说明，本仓库原创贡献采用 MIT 许可证。第三方或二次开发内容仍受其原始许可证和署名要求约束。详见 [`LICENSE`](LICENSE)。
