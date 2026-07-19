# 分类与标题规则

> Codex 2026-07-19：分类扩展为九类；自动结果是候选，不替代人工核查。

## 标题结构

`类别-主路径-任务摘要`

## 分类目录

- `上位机代码`：SDK、EXE、Qt、CMake、Matlab、GUI 和桌面工具。
- `硬件端代码`：FPGA、Vivado、Zynq PS、STM32、SimpleFOC、Verilog、I2C/AXI 和电机控制。
- `科研与论文`：科研申请、论文、文献、专利和医学研究。
- `文档与报告`：Word、PDF、LaTeX、技术文档、报告和公式整理。
- `PPT与演示`：PPT、PowerPoint、幻灯片、答辩和汇报材料。
- `股票与量化`：股票、证券、行情、交易策略、选股和量化分析。
- `Codex/Skill/MCP`：Codex、skill、MCP、插件、GSD、Grok 编排和 agent 工具。
- `工具部署与环境`：通用软件安装、部署、依赖、端口、CLI、Docker 和运行环境配置。
- `其他/闲聊`：问候、无法稳定归类的任务和剩余内容。

分类优先识别项目领域，再识别通用部署动作；例如“部署 FPGA 工程”仍归入`硬件端代码`。

## 证据优先级

1. 已有结构化标题。
2. 当前非泛化标题。
3. `first_user_message`。
4. 会话正文中评分最高的真实任务消息。
5. 线程 `cwd`。

环境上下文、AGENTS 指令、终止标记会被过滤。交接、恢复和 `resume` 指令降低权重，避免把“生成交接文档”误当项目主题。

## 路径规则

- 支持盘符路径、Unicode 中文目录、正反斜杠。
- 对包含尾部正文的路径，优先取磁盘上存在的最长前缀。
- 位于主要工作区外的兄弟项目不再粗暴截成父目录。
- `--all-user-threads` 会根据每个线程的 `cwd` 选择有效根目录。
- 只有出现对比、联调、兼容、上下位机配合等信号时才保留两个主项目路径。

## 人工核查条件

CSV 的以下情况应重点检查：

- `置信度=低/中`。
- 路径仅来自 `cwd` 或工作区根。
- 摘要包含“相关内容”“skill 与 MCP”“代码注释与文档”等泛化词。
- 长会话跨越多个无关任务。
- 标题只写“你好”“继续”“接收这个工作”或恢复 ID。

人工核查时优先表达当前或主要交付目标，例如“迁移启动应答机制”，不要罗列聊天中出现过的所有工具名。

## English reference

> Codex 2026-07-19: the classifier now has nine categories; automatic results are candidates and do not replace human review.

### Title structure

`category-main-path-task-summary`

### Categories

- `Desktop Code`: SDKs, executables, Qt, CMake, Matlab, GUI, and desktop tools.
- `Embedded/Hardware Code`: FPGA, Vivado, Zynq PS, STM32, SimpleFOC, Verilog, I2C/AXI, and motor control.
- `Research & Papers`: grant proposals, papers, literature, patents, and medical research.
- `Documents & Reports`: Word, PDF, LaTeX, technical documents, reports, and formula editing.
- `PPT & Presentations`: PowerPoint, slides, defenses, presentations, and briefing material.
- `Stocks & Quantitative Analysis`: stocks, securities, market data, trading strategies, screening, and quantitative analysis.
- `Codex/Skill/MCP`: Codex, skills, MCP servers, plugins, GSD, Grok orchestration, and agent tooling.
- `Tool Deployment & Environment`: general installation, deployment, dependencies, ports, CLI, Docker, and runtime configuration.
- `Other/Chat`: greetings, unstable classifications, and remaining content.

The classifier identifies the project domain before generic deployment actions; for example, “deploy an FPGA project” remains `Embedded/Hardware Code`.
