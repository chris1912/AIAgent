# 移植到其他电脑

> Codex 2026-07-19

## 需要复制什么

复制整个目录：

`%USERPROFILE%\.codex\skills\codex-thread-rename`

目标电脑放到相同的 skill 根目录下。应包含：

- `SKILL.md`
- `scripts\codex_thread_rename.py`
- `references\`
- `agents\openai.yaml`
- `CHANGELOG.md`

`scripts\__pycache__` 可以不复制，它会自动重建。

## 运行条件

- Windows 上安装 Python 3.10 或更高版本。
- 目标电脑已经运行过 Codex，且 `%USERPROFILE%\.codex` 中存在本地状态库。
- 目标 Codex 版本的内部 schema 必须通过 `validate`。

脚本使用 `Path.home()` 定位用户目录，不绑定 `Administrator` 用户名。分类关键词仍偏向当前这批 FPGA、STM32、SDK 项目；换成完全不同的项目时，必须人工核查预览。

## 安装后检查

1. 重启 Codex，让它重新扫描 skill。
2. 运行：`python scripts/codex_thread_rename.py self-check`
3. 只生成 preview，不立即 apply。
4. 人工检查低/中置信度项。
5. 运行 `validate`，确认 schema 和映射安全。
6. 得到明确确认后才运行 `apply`，随后运行 `verify`。

不需要额外给 AI 写复杂配置；告诉 AI 使用 `$codex-thread-rename` 即可。若 UI 没发现 skill，先检查目录层级和 `SKILL.md` frontmatter，再重启 Codex。
