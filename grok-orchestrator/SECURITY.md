# Security Policy / 安全政策

## Supported Scope / 支持范围

Security reports are welcome for the scripts, invocation policy, process cleanup, result classification, fallback boundaries, and documentation shipped in this directory.

欢迎报告本目录中脚本、调用策略、进程清理、结果分类、回退边界和文档相关的安全问题。

## Reporting / 报告方式

Please do not open a public issue for an unpatched vulnerability. Use the repository owner's private GitHub security reporting channel or contact the maintainer privately through the repository profile. Do not include credentials in the report.

对于尚未修复的漏洞，请不要创建公开 issue。请使用仓库所有者的 GitHub 私密安全报告渠道，或通过仓库个人资料私下联系维护者。报告中不要包含凭证。

Include the affected file, a minimal reproduction, impact, and a suggested mitigation when available.

如有可能，请提供受影响文件、最小复现步骤、影响和建议的缓解措施。

## Secret Handling / 秘密处理

Never commit credentials, private keys, `.env` files, raw provider logs, or local authentication material. If a credential was exposed, revoke or rotate it first, then assess whether history remediation is required.

绝不要提交凭证、私钥、`.env` 文件、原始提供方日志或本地认证材料。如果凭证已经暴露，应先撤销或轮换，再评估是否需要清理 Git 历史。
