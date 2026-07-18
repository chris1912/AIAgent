# Security Policy / 安全策略

## Supported Versions / 支持版本

Security fixes target the current `main` branch. Historical snapshots and external provider CLIs are not maintained by this repository.

安全修复面向当前 `main` 分支。本仓库不维护历史快照或外部提供方 CLI。

## Reporting a Vulnerability / 报告漏洞

Use GitHub's private vulnerability reporting or Security Advisory feature when available. Do not open a public issue for an unpatched vulnerability.

请优先使用 GitHub 私有漏洞报告或 Security Advisory 功能。未修复漏洞不要提交为公开 Issue。

Include the affected project and version, reproduction steps, expected impact, and a suggested mitigation when possible. Remove credentials, account identifiers, private prompts, local paths, and raw logs before submitting.

请尽可能提供受影响项目与版本、复现步骤、预期影响和缓解建议。提交前删除凭据、账户标识、私人提示词、本机路径和原始日志。

## Security Boundaries / 安全边界

- The repository does not manage provider accounts, billing, VPNs, or authentication. / 本仓库不管理提供方账户、计费、VPN 或认证。
- Orchestration must not purchase credits, change credentials, or bypass provider controls. / 编排过程不得购买额度、修改凭据或绕过提供方控制。
- Authentication, permission, network, timeout, and task failures require review rather than blind fallback. / 认证、权限、网络、超时和任务失败必须人工审查，不得盲目回退。
- Users remain responsible for reviewing generated code and commands before execution. / 用户仍需在执行前审查生成的代码和命令。

## Secret Protection / 凭据保护

Enable GitHub Secret Protection and push protection where available. Local scans reduce risk but do not replace GitHub-side protection or credential rotation after exposure.

建议在条件允许时启用 GitHub Secret Protection 和推送保护。本地扫描只能降低风险，不能替代 GitHub 侧保护，也不能替代泄露后的凭据轮换。
