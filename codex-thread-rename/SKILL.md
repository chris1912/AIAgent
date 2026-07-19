---
name: codex-thread-rename
description: 分类、人工核查并安全重命名 Codex 本地历史对话，同步 live/legacy 状态库、UI 目录缓存和兼容索引。适用于按项目批量整理标题、修复侧栏旧标题、全量核查可见项目或迁移该能力到其他电脑。
---

# Codex Thread Rename

## 目标

- 标题格式：`类别-主路径-任务摘要`。
- 默认类别：`上位机代码`、`硬件端代码`、`科研与论文`、`文档与报告`、`PPT与演示`、`股票与量化`、`Codex/Skill/MCP`、`工具部署与环境`、`其他/闲聊`。
- 自动分类只负责生成候选；低置信度标题必须结合会话正文人工核查。
- 写回前校验，写回时备份，失败自动恢复，完成后核对所有存储落点。

## 标准工作流

1. 运行隔离式自检：
   `python scripts/codex_thread_rename.py self-check`
2. 为一个工作区生成预览：
   `python scripts/codex_thread_rename.py preview --workspace-root <路径> --output <csv>`
3. 核查所有可见用户对话：
   `python scripts/codex_thread_rename.py preview --workspace-root <主要根目录> --all-user-threads --output <csv>`
4. 优先检查 CSV 中 `置信度=低/中`、`核查原因`、`旧标题/新标题/主路径`，必要时直接修改 `新标题`。
5. 写回前严格预检：
   `python scripts/codex_thread_rename.py validate --mapping <csv>`
6. 用户确认后应用：
   `python scripts/codex_thread_rename.py apply --mapping <csv>`
7. 再独立核对：
   `python scripts/codex_thread_rename.py verify --mapping <csv>`
8. 如果侧栏仍显示旧标题，让用户重启 Codex 刷新内存缓存；不要继续猜测并修改其他缓存。

## 写回安全保证

- 先验证映射列、空标题、重复/未知线程、SQLite 表结构和 JSONL 完整性。
- 使用 SQLite backup API 创建一致性快照，live、legacy、catalog 分目录保存，避免同名覆盖。
- UI 目录只更新目标线程标题，保留 `source_detail` 等无关元数据。
- `session_index.jsonl` 使用同目录临时文件原子替换。
- 任一步失败会从本次备份恢复；成功后自动核对四个落点。

## 真实落点

- live：`%USERPROFILE%\.codex\sqlite\state_5.sqlite`
- legacy：`%USERPROFILE%\.codex\state_5.sqlite`
- UI 目录：`%USERPROFILE%\.codex\sqlite\codex-dev.db`
- 兼容索引：`%USERPROFILE%\.codex\session_index.jsonl`

`session_index.jsonl` 不是全量真源；部分线程没有对应行属于正常情况。

## 分类原则

- 当前标题优先，其次 `first_user_message`，再从会话正文中选择最强任务信息。
- 过滤环境上下文、AGENTS 指令、终止标记；交接/恢复指令降低主题权重。
- 支持 Unicode Windows 路径、兄弟工作区和 `--all-user-threads` 下按线程 `cwd` 推导项目根。
- 自动摘要无法可靠理解跨多任务长会话，因此保留置信度和人工审核环节，不把启发式当事实。

## 分类目录

- `上位机代码`：SDK、EXE、Qt、CMake、Matlab、GUI 和桌面工具。
- `硬件端代码`：FPGA、Vivado、Zynq、STM32、SimpleFOC、Verilog、I2C/AXI 和电机控制。
- `科研与论文`：科研申请、论文、文献、专利和医学研究。
- `文档与报告`：Word、PDF、LaTeX、技术文档、报告和公式整理。
- `PPT与演示`：PPT、PowerPoint、幻灯片、答辩和汇报材料。
- `股票与量化`：股票、证券、行情、交易策略、选股和量化分析。
- `Codex/Skill/MCP`：Codex、skill、MCP、插件、GSD、Grok 编排和 agent 工具。
- `工具部署与环境`：通用软件安装、部署、依赖、端口、CLI、Docker 和运行环境配置。
- `其他/闲聊`：问候、无法稳定归类的任务和剩余内容。

分类优先识别项目领域，再识别通用部署动作；例如“部署 FPGA 工程”仍归入`硬件端代码`，而不是`工具部署与环境`。

## English reference

### Goal

- Use the title format `category-main-path-task-summary`.
- The default categories are `Desktop Code`, `Embedded/Hardware Code`, `Research & Papers`, `Documents & Reports`, `PPT & Presentations`, `Stocks & Quantitative Analysis`, `Codex/Skill/MCP`, `Tool Deployment & Environment`, and `Other/Chat`.
- Automatic classification only produces candidates; low-confidence titles still require human review.
- Validate before writing, create backups during writing, restore on failure, and verify all storage locations afterward.

### Category directory

- `Desktop Code`: SDKs, executables, Qt, CMake, Matlab, GUI, and desktop tools.
- `Embedded/Hardware Code`: FPGA, Vivado, Zynq, STM32, SimpleFOC, Verilog, I2C/AXI, and motor control.
- `Research & Papers`: grant proposals, papers, literature, patents, and medical research.
- `Documents & Reports`: Word, PDF, LaTeX, technical documents, reports, and formula editing.
- `PPT & Presentations`: PowerPoint, slides, defenses, presentations, and briefing material.
- `Stocks & Quantitative Analysis`: stocks, securities, market data, trading strategies, screening, and quantitative analysis.
- `Codex/Skill/MCP`: Codex, skills, MCP servers, plugins, GSD, Grok orchestration, and agent tooling.
- `Tool Deployment & Environment`: general installation, deployment, dependencies, ports, CLI, Docker, and runtime configuration.
- `Other/Chat`: greetings, unstable classifications, and remaining content.

The classifier prioritizes the project domain before generic deployment actions, so “deploy an FPGA project” remains `Embedded/Hardware Code` instead of `Tool Deployment & Environment`.

## 移植

- 完整说明见 `references/portability.md`。
- 简要做法：复制整个 `codex-thread-rename` 文件夹到另一台电脑的 `%USERPROFILE%\.codex\skills\`，不要复制 `__pycache__`，然后重启 Codex。
- 需要 Python 3.10+；首次使用必须先跑 `self-check` 和 `validate`。

## 文件

- 主脚本：`scripts/codex_thread_rename.py`
- 存储说明：`references/storage-and-pitfalls.md`
- 分类规则：`references/classification-rules.md`
- 移植说明：`references/portability.md`
- 变更记录：`CHANGELOG.md`
