# Repository Memory / 仓库项目记忆

> Maintainer / 维护者: repository owner
> Updated / 更新日期: 2026-07-19

## Purpose / 目标

Maintain a public collection of independently installable AI-agent skills, plugins, and helper tools, including original work, adaptations, and experiments.

维护一个公开的 AI Agent Skill、插件和辅助工具集合，内容包括原创实现、二次开发和实验项目，并保持各项目可独立安装。

## Repository Decisions / 仓库决策

- Each top-level project owns its implementation, tests, README, and detailed contract. / 每个顶级项目独立维护实现、测试、README 和详细契约。
- Root documentation describes shared positioning, governance, security, and contribution policy. / 根级文档负责统一定位、治理、安全和贡献规则。
- Public-facing explanatory documentation is bilingual Chinese and English. / 面向用户的说明文档采用中英文双语。
- Live provider discovery is authoritative; static model names and routing registries are hints. / 模型可用性以提供方实时发现为准，静态名称和路由注册表仅作提示。
- Local run artifacts, credentials, generated reports, and personal absolute paths are excluded from publication. / 本地运行产物、凭据、生成报告和个人绝对路径不得公开。
- A subproject license or third-party notice overrides the root license for that material. / 子项目许可证或第三方声明对对应内容优先于根许可证。

## Current Catalog / 当前目录

- `grok-orchestrator`: Grok-only bounded delegation with 62 recorded offline checks. / 仅 Grok 的有界委派，已记录 62 项离线检查。
- `multi-model-orchestrator`: Grok and Antigravity routing with 104 recorded offline checks. / Grok 与 Antigravity 路由，已记录 104 项离线检查。

## Documentation Map / 文档地图

- `README.md`: public overview, installation, verification, and project catalog. / 公开介绍、安装、验证和项目目录。
- `CONTRIBUTING.md`: issue, development, testing, and pull-request expectations. / Issue、开发、测试和 Pull Request 要求。
- `SECURITY.md`: private vulnerability reporting and security boundaries. / 私密漏洞报告与安全边界。
- `SUPPORT.md`: supported and unsupported requests. / 支持与不支持的请求。
- `.github/`: issue forms and pull-request checklist. / Issue 表单与 Pull Request 检查清单。

## Maintenance Notes / 维护说明

When adding a project, update the root catalog, document its provider requirements, add deterministic tests when practical, verify licenses and attribution, and run a publication-safety audit before commit.

新增项目时，应更新根目录项目表，说明提供方要求，在可行时添加确定性测试，核对许可证和署名，并在提交前执行发布安全审计。
