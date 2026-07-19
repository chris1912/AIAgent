# Changelog

## 2026-07-19 — 扩展对话分类体系

- 将分类从三类扩展为九类：上位机代码、硬件端代码、科研与论文、文档与报告、PPT与演示、股票与量化、Codex/Skill/MCP、工具部署与环境、其他/闲聊。
- 增加研究、文档、PPT、股票、Codex 工具和通用部署关键词。
- 分类优先识别项目领域，再识别通用部署动作，避免代码项目被归入部署类。
- 增加分类器自检覆盖，准备对已有全量对话重新生成预览并安全写回。
- 已完成 161 条历史对话的九类预览、校验、备份写回和独立核对。

English: The classifier now uses nine categories, prioritizes project domains over generic deployment actions, and has been applied and independently verified across 161 historical threads.

## 2026-07-19 — Codex 安全性与全项目改名升级

- 修复 live/legacy 同名备份互相覆盖。
- 改用 SQLite backup API 创建一致性快照。
- 增加映射、线程 ID、schema、JSONL 预检。
- 增加失败自动恢复和写后四落点核对。
- UI 目录改为仅同步目标线程，保留无关元数据。
- JSONL 改为原子替换。
- 显式关闭 SQLite 连接，修复 Windows 文件占用。
- 支持 Unicode 路径、兄弟项目和全用户线程的按 `cwd` 根目录推导。
- 预览增加置信度与核查原因。
- 新增 `validate`、`verify` 命令和隔离式端到端 `self-check`。
- 完成 83 条本地用户对话的人工复核与统一改名。
