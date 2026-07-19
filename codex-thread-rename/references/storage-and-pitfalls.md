# 存储、备份与坑点

> Codex 2026-07-19：本文与当前安全写回实现同步。

## 四个落点

- live 状态库：`%USERPROFILE%\.codex\sqlite\state_5.sqlite`
- legacy 镜像库：`%USERPROFILE%\.codex\state_5.sqlite`
- UI 目录缓存：`%USERPROFILE%\.codex\sqlite\codex-dev.db`
- 兼容索引：`%USERPROFILE%\.codex\session_index.jsonl`

live 是主线程清单。legacy 可能包含仅在旧客户端或 VS Code 中出现的用户线程。UI 标题来自 `local_thread_catalog`。JSONL 只覆盖部分线程，不能作为全量真源。

## 当前正确顺序

1. 从 live + legacy 用户线程并集生成预览。
2. 人工核查低/中置信度标题。
3. 校验映射、线程 ID、数据库 schema 和 JSONL。
4. 用 SQLite backup API 分别保存 `live/`、`legacy/`、`catalog/` 快照，并复制 JSONL。
5. 更新 live 和 legacy 中存在的目标线程。
6. 只同步目标线程的 UI 标题，不清空其他目录元数据。
7. 原子替换 JSONL。
8. 自动核对四个落点；失败则从快照恢复。
9. 用户重启 Codex 刷新内存缓存。

## 已修复的关键问题

- 旧实现把两份同名 `state_5.sqlite` 复制到同一目录，legacy 会覆盖 live 备份。
- 逐个复制 DB/WAL/SHM 可能得到不一致快照；当前改用 SQLite backup API。
- 旧实现分步提交后失败会留下半完成状态；当前失败会自动恢复。
- 旧实现全量 upsert UI 目录并把 `source_detail` 写空；当前只更新映射线程标题。
- 旧实现直接覆盖 JSONL；当前使用临时文件 + `os.replace`。
- Python SQLite 上下文管理器不会自动关闭连接；当前所有连接均显式关闭，避免 Windows 文件占用。

## 仍需注意

- Codex 运行时可能保留内存标题，磁盘验证成功后侧栏仍可能需要重启。
- Codex 内部数据库 schema 未来可能变化；`validate` 会在写入前阻止不兼容版本。
- 不要手工删除 WAL/SHM，不要关闭小写 `codex` 桥接进程，不要只修改某一个落点。
- 备份目录位于 `%USERPROFILE%\.codex\backup-<时间>-thread-rename-skill`，确认稳定后再自行决定是否保留。
