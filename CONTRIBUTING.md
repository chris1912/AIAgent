# Contributing / 贡献指南

Thank you for improving AIAgent Toolbox. Contributions should keep each tool independently understandable, testable, and safe to publish.

感谢改进 AIAgent Toolbox。贡献内容应保证每个工具均可独立理解、测试，并适合公开发布。

## Before Opening an Issue / 提交 Issue 前

- Search existing issues and documentation first. / 先搜索已有 Issue 和文档。
- Include the affected project, operating system, PowerShell version, CLI version, and a minimal reproduction. / 提供受影响项目、操作系统、PowerShell 版本、CLI 版本和最小复现步骤。
- Redact tokens, account identifiers, private paths, prompts, and provider output containing personal data. / 删除令牌、账户标识、私人路径、提示词和含个人数据的提供方输出。

## Development Workflow / 开发流程

1. Fork the repository and create a focused branch. / Fork 仓库并创建聚焦单一目标的分支。
2. Read the target project's `SKILL.md`, README, references, and tests. / 阅读目标项目的 `SKILL.md`、README、参考文档和测试。
3. Keep behavior changes small and update adjacent documentation. / 保持行为修改小而集中，并更新相邻文档。
4. Add or update deterministic offline tests for behavior changes. / 行为变更应新增或更新确定性离线测试。
5. Run the smallest relevant suite, then the full project suite. / 先运行最小相关测试，再运行完整项目测试。

```powershell
powershell -NoProfile -NonInteractive -File .\<project-name>\tests\Run-OfflineTests.ps1
```

## Style / 风格

- Preserve Windows PowerShell 5.1 compatibility unless the project explicitly changes its baseline. / 除非项目明确变更基线，否则保持 Windows PowerShell 5.1 兼容。
- Use explicit parameters, bounded timeouts, durable artifacts, and clear failure categories. / 使用显式参数、有界超时、持久化产物和清晰的失败分类。
- Public-facing explanatory documents must contain complete Chinese and English content. / 面向用户的说明文档必须包含完整中英文内容。
- Do not hard-code personal paths, credentials, provider quotas, or model availability. / 不要硬编码个人路径、凭据、提供方额度或模型可用性。

## Pull Requests / Pull Request

Describe the problem, scope, safety impact, files changed, and verification evidence. Link related issues and include screenshots only when they contain no private information. A pull request may be held when tests, documentation, licensing, or publication safety are unclear.

请说明问题、范围、安全影响、修改文件和验证证据，并关联相关 Issue。仅在不含私人信息时附加截图。测试、文档、许可或发布安全不明确时，Pull Request 可能暂缓合并。
