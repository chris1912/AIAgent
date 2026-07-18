# Contributing / 贡献指南

## Scope / 范围

Keep changes focused on the standalone Grok orchestrator. Do not add provider credentials, paid-service assumptions, or dependencies without a clear need.

修改应聚焦于独立 Grok 编排器。没有明确必要时，不要加入提供方凭证、付费服务假设或新依赖。

## Workflow / 工作流

1. Read [`SKILL.md`](SKILL.md), the relevant reference, and the project memory.
2. 阅读 [`SKILL.md`](SKILL.md)、相关参考文档和项目记忆。
3. Describe the objective, allowed paths, forbidden actions, and acceptance checks in the change or pull request.
4. 在变更或 pull request 中说明目标、允许路径、禁止行为和验收检查。
5. Keep public documentation bilingual and preserve copyable commands.
6. 保持公开文档中英双语，并保留可复制命令。

## Checks / 检查

Run the offline suite from the repository root. / 在仓库根目录运行离线测试：

```powershell
powershell -NoProfile -NonInteractive -File tests/Run-OfflineTests.ps1
```

The suite uses a fake Grok executable and must not require paid credits, credential changes, or a long live task.

测试套件使用 fake Grok 可执行文件，不应要求付费额度、修改凭证或执行长时间现场任务。

## Pull Requests / Pull Request

Include a concise summary, changed paths, verification results, skipped checks, and any security or compatibility risk. Do not include raw credentials, private paths, or complete provider transcripts.

请包含简洁摘要、变更路径、验证结果、跳过的检查以及安全或兼容性风险。不要包含原始凭证、私有路径或完整提供方对话记录。
