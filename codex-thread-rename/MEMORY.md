# Codex Thread Rename Memory / Codex 对话改名记忆

> Codex 2026-07-19

## 中文

- 本 skill 面向 Codex 本地历史对话的预览、人工核查、安全改名和四落点同步。
- 当前分类为九类：上位机代码、硬件端代码、科研与论文、文档与报告、PPT与演示、股票与量化、Codex/Skill/MCP、工具部署与环境、其他/闲聊。
- 分类器优先识别项目领域，再识别通用部署动作；低置信度结果仍需人工核查。
- 2026-07-19 扩分类后，必须先运行 `self-check`，再生成全量 preview，执行 `validate`、`apply` 和 `verify`。

## English

- This skill previews, reviews, safely renames, and synchronizes Codex local historical threads across four storage locations.
- It now uses nine categories: Desktop Code, Embedded/Hardware Code, Research & Papers, Documents & Reports, PPT & Presentations, Stocks & Quantitative Analysis, Codex/Skill/MCP, Tool Deployment & Environment, and Other/Chat.
- The classifier prioritizes project domains before generic deployment actions, and low-confidence results still require human review.
- After the 2026-07-19 category expansion, run `self-check`, generate the full preview, then run `validate`, `apply`, and `verify`.
