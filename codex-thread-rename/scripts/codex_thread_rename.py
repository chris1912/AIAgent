from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import sqlite3
import tempfile
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


CODEX_HOME = Path.home() / ".codex"
LIVE_STATE_DB = CODEX_HOME / "sqlite" / "state_5.sqlite"
LEGACY_STATE_DB = CODEX_HOME / "state_5.sqlite"
LOCAL_CATALOG_DB = CODEX_HOME / "sqlite" / "codex-dev.db"
SESSION_INDEX = CODEX_HOME / "session_index.jsonl"
DEFAULT_PREVIEW = CODEX_HOME / "tmp" / "codex-thread-rename-preview.csv"
# Codex 2026-07-19: expanded categories for code, research, documents, and tooling.
CATEGORY_NAMES = (
    "上位机代码",
    "硬件端代码",
    "科研与论文",
    "文档与报告",
    "PPT与演示",
    "股票与量化",
    "Codex/Skill/MCP",
    "工具部署与环境",
    "其他/闲聊",
)
STRUCTURED_PREFIXES = tuple(f"{category}-" for category in CATEGORY_NAMES)
LEGACY_STRUCTURED_PREFIXES = ("上位机代码-", "硬件端代码-", "其他-")

# Codex 2026-07-19: writes are guarded by schema validation, consistent SQLite snapshots,
# targeted cache synchronization, atomic JSON replacement, rollback, and post-write verification.

WINDOWS_PATH_RE = re.compile(r"(?i)(?<![A-Za-z])[A-Z]:[\\/][^\r\n<>\"|?*]+")
ACTIVE_FILE_RE = re.compile(r"^##\s*Active file:\s*(.+?)\s*$", re.MULTILINE)
FILES_MENTIONED_RE = re.compile(r"^##\s*.+?:\s*(.+?)\s*$", re.MULTILINE)
OPEN_TAB_ITEM_RE = re.compile(r"^\s*-\s*.+?:\s*(.+?)\s*$", re.MULTILINE)

COMPARE_KEYWORDS = ("对比", "比较", "新旧", "旧版", "新版", "不同版本", "联调", "兼容", "上下位机", "分别", "配合", "联动")
GENERIC_MESSAGES = {"", "你好", "您好", "nihao", "回复你好", "回复问候", "/start", "继续", "看这个"}
TASK_KEYWORDS = ("分析", "检查", "核查", "审查", "阅读", "更新", "修改", "修复", "编译", "构建", "安装", "对比", "迁移", "实现", "解决", "设计", "优化")
META_TASK_KEYWORDS = ("交接文档", "session-handoff", "接收这个工作", "resume ")
HARDWARE_KEYWORDS = ("fpga", "vivado", "ip_repo", "axi_", "i2c", "stm32", "simplefoc", ".ino", "zynq", "verilog", "hdl", "电机控制", "uart1", "mmc5983")
SOFTWARE_KEYWORDS = ("c++code\\", "rx-exe", "rx-sdk", "mpdecode", "rx-devicetesting", "matlabcode", "qt", "cmake", ".ui", "gui", "sdk", "exe", "wa-app", "ccusage-codex-m")
RESEARCH_KEYWORDS = ("科研", "论文", "文献", "基金", "专利", "医学研究", "研究内容", "research", "paper", "literature", "grant", "patent")
DOCUMENT_KEYWORDS = ("文档", "报告", "说明书", "word", "docx", "latex", "公式", "pdf", "markdown", "md文件", "技术文稿")
PRESENTATION_KEYWORDS = ("ppt", "powerpoint", "幻灯片", "演示文稿", "演示", "答辩", "汇报", "presentation", "slide")
STOCK_KEYWORDS = ("股票", "量化", "证券", "行情", "交易策略", "选股", "财报", "stock", "trading", "ticker", "portfolio", "astockanalysis")
CODEX_KEYWORDS = ("skill", "mcp", "插件", "codex app", "grok-orchestrator", "antigravity", "subagent", "get shit done", "gsd")
DEPLOYMENT_KEYWORDS = ("安装", "部署", "配置环境", "环境配置", "依赖", "端口", "docker", "npm", "pip", "conda", "命令行", "cli", "服务器", "本地运行")
OTHER_KEYWORDS = CODEX_KEYWORDS + ("问候", "读取这个对话", "synthpilot", "powershell", "bash")


@dataclass
class ThreadRecord:
    thread_id: str
    old_title: str
    rollout_path: Path
    cwd: str
    first_user_message: str
    updated_at: float


@dataclass
class RenameRecord:
    thread_id: str
    old_title: str
    new_title: str
    category: str
    main_path: str
    evidence_source: str
    rollout_path: str
    confidence: str
    review_reason: str


def candidate_path_exists(path_text: str) -> bool:
    if " + " in path_text:
        parts = [normalize_path(part) for part in path_text.split(" + ") if part.strip()]
        return all(Path(part).exists() for part in parts)
    return Path(normalize_path(path_text)).exists()


def parse_structured_title(title: str) -> tuple[str, str, str] | None:
    for prefix in STRUCTURED_PREFIXES + LEGACY_STRUCTURED_PREFIXES:
        if not title.startswith(prefix):
            continue
        category = prefix[:-1]
        remainder = title[len(prefix):]
        for index in range(len(remainder), 2, -1):
            candidate_path = normalize_path(remainder[:index])
            if not candidate_path_exists(candidate_path):
                continue
            summary = remainder[index:].lstrip("-").strip()
            return category, candidate_path, summary
        return category, "", remainder
    return None


def normalize_text(raw_text: str) -> str:
    cleaned_text = raw_text.replace("\r", "\n")
    cleaned_text = re.sub(r"<environment_context>.*?</environment_context>", " ", cleaned_text, flags=re.DOTALL)
    cleaned_text = re.sub(r"<turn_aborted>.*?</turn_aborted>", " ", cleaned_text, flags=re.DOTALL)
    cleaned_text = re.sub(r"# AGENTS\.md instructions.*?</INSTRUCTIONS>", " ", cleaned_text, flags=re.DOTALL)
    cleaned_text = cleaned_text.replace("`", "")
    cleaned_text = re.sub(r"\s+", " ", cleaned_text)
    cleaned_text = cleaned_text.strip()
    return cleaned_text


def normalize_path(raw_path: str) -> str:
    normalized_path = raw_path.strip().strip("[](){}<>,;").strip("'\"")
    normalized_path = normalized_path.replace("/", "\\")
    if normalized_path.startswith("\\\\?\\"):
        normalized_path = normalized_path[4:]
    if len(normalized_path) > 3:
        normalized_path = normalized_path.rstrip("\\")
    while normalized_path and normalized_path[-1] in ".!?:，。；、":
        normalized_path = normalized_path[:-1]
    normalized_path = normalized_path.strip()
    return normalized_path


def is_under_root(path_text: str, workspace_root: Path) -> bool:
    normalized_path = normalize_path(path_text).lower()
    normalized_root = str(workspace_root).lower()
    return normalized_path == normalized_root or normalized_path.startswith(f"{normalized_root}\\")


def is_substantial_message(text: str, workspace_root: Path) -> bool:
    normalized_text = normalize_text(text)
    lowered_text = normalized_text.lower()
    if lowered_text in GENERIC_MESSAGES:
        return False
    if len(normalized_text) >= 12:
        return True
    if str(workspace_root).lower() in lowered_text:
        return True
    if any(keyword in lowered_text for keyword in HARDWARE_KEYWORDS + SOFTWARE_KEYWORDS + OTHER_KEYWORDS):
        return True
    return False


def extract_texts(message_payload: dict) -> list[str]:
    extracted_texts: list[str] = []
    for item in message_payload.get("content", []):
        item_text = item.get("text", "")
        if item_text:
            extracted_texts.append(item_text)
    return extracted_texts


def iter_session_user_texts(session_path: Path) -> Iterable[str]:
    with session_path.open("r", encoding="utf-8") as session_file:
        for line in session_file:
            stripped_line = line.strip()
            if not stripped_line:
                continue
            try:
                payload = json.loads(stripped_line)
            except json.JSONDecodeError:
                continue
            if payload.get("type") == "response_item":
                response_payload = payload.get("payload", {})
                if response_payload.get("type") == "message" and response_payload.get("role") == "user":
                    for text in extract_texts(response_payload):
                        yield text
            if payload.get("type") == "compacted":
                compacted_payload = payload.get("payload", {})
                for history_item in compacted_payload.get("replacement_history", []):
                    if history_item.get("type") == "message" and history_item.get("role") == "user":
                        for text in extract_texts(history_item):
                            yield text


def extract_paths(text: str) -> list[str]:
    raw_paths: list[str] = []
    for pattern in (ACTIVE_FILE_RE, FILES_MENTIONED_RE, OPEN_TAB_ITEM_RE, WINDOWS_PATH_RE):
        raw_paths.extend(pattern.findall(text))
    normalized_paths: list[str] = []
    seen_paths: set[str] = set()
    for raw_path in raw_paths:
        normalized_path = normalize_path(raw_path)
        for index in range(len(normalized_path), 2, -1):
            existing_prefix = normalize_path(normalized_path[:index])
            if Path(existing_prefix).exists():
                normalized_path = existing_prefix
                break
        lowered_path = normalized_path.lower()
        if not normalized_path or lowered_path in seen_paths:
            continue
        seen_paths.add(lowered_path)
        normalized_paths.append(normalized_path)
    return normalized_paths


def derive_project_dir(path_text: str, workspace_root: Path) -> str:
    path_value = Path(normalize_path(path_text))
    if not is_under_root(str(path_value), workspace_root):
        if path_value.exists():
            return str(path_value if path_value.is_dir() else path_value.parent)
        return str(path_value.parent if path_value.suffix else path_value)
    relative_parts = path_value.relative_to(workspace_root).parts
    if not relative_parts:
        return str(workspace_root)
    if relative_parts[0] in {"C++Code", "Z-Others"} and len(relative_parts) >= 2:
        return str(workspace_root / relative_parts[0] / relative_parts[1])
    return str(workspace_root / relative_parts[0])


def guess_project_paths(text: str, workspace_root: Path) -> list[str]:
    guess_map = {
        "ccusage-codex-m": workspace_root / "ccusage-codex-m",
        "wa-app": workspace_root / "Z-Others" / "wa-app",
        "rx-exe-codex": workspace_root / "C++Code" / "RX-EXE-Codex",
        "rx-sdk-codex": workspace_root / "C++Code" / "RX-SDK-Codex",
        "rx-exe-fpga-1.7.0": workspace_root / "C++Code" / "RX-EXE-FPGA-1.7.0",
        "rx-sdk-fpga-1.7.0": workspace_root / "C++Code" / "RX-SDK-FPGA-1.7.0",
        "rx-exe-3": workspace_root / "C++Code" / "RX-EXE-3",
        "rx-sdk-3": workspace_root / "C++Code" / "RX-SDK-3",
        "rx-exe-2": workspace_root / "C++Code" / "RX-EXE-2",
        "rx-sdk-2": workspace_root / "C++Code" / "RX-SDK-2",
        "rx-exe": workspace_root / "C++Code" / "RX-EXE",
        "rx-sdk": workspace_root / "C++Code" / "RX-SDK",
        "rx-devicetesting": workspace_root / "C++Code" / "RX-DeviceTesting",
        "mpdecode": workspace_root / "C++Code" / "MpDecode",
        "matlabcode": workspace_root / "MatlabCode",
        "simplefoc_velcity_control_rx": workspace_root / "SimpleFOC_velcity_control_RX",
        "ruixin_fpga_main_v1.7.0": workspace_root / "RuiXin_FPGA_Main_V1.7.0",
        "ruixin_fpga_main_v1.6.6": workspace_root / "RuiXin_FPGA_Main_V1.6.6",
        "ruixin_fpga_main_v1.6.5": workspace_root / "RuiXin_FPGA_Main_V1.6.5",
    }
    guessed_paths: list[str] = []
    lowered_text = text.lower()
    for key, path_value in guess_map.items():
        if key in lowered_text:
            guessed_paths.append(str(path_value))
    unique_paths: list[str] = []
    seen_paths: set[str] = set()
    for guessed_path in guessed_paths:
        lowered_path = guessed_path.lower()
        if lowered_path in seen_paths:
            continue
        seen_paths.add(lowered_path)
        unique_paths.append(guessed_path)
    return unique_paths


def source_score(text: str, label: str, workspace_root: Path, order: int) -> float:
    normalized_text = normalize_text(text)
    lowered_text = normalized_text.lower()
    if not is_substantial_message(normalized_text, workspace_root):
        return -1.0
    score = min(len(normalized_text), 500) / 25.0
    score += 35.0 if any(keyword in normalized_text for keyword in TASK_KEYWORDS) else 0.0
    score += 25.0 if extract_paths(normalized_text) else 0.0
    score += 15.0 if any(keyword in lowered_text for keyword in HARDWARE_KEYWORDS + SOFTWARE_KEYWORDS) else 0.0
    score += 12.0 if label == "title" else 6.0 if label == "first_user_message" else 0.0
    score -= 45.0 if any(keyword in lowered_text for keyword in META_TASK_KEYWORDS) else 0.0
    return score + order / 10000.0


def select_source_text(thread: ThreadRecord, workspace_root: Path) -> tuple[str, str]:
    title_text = normalize_text(thread.old_title)
    first_user_text = normalize_text(thread.first_user_message)
    if is_substantial_message(title_text, workspace_root):
        return title_text, "title"
    if is_substantial_message(first_user_text, workspace_root):
        return first_user_text, "first_user_message"
    candidates: list[tuple[str, str]] = []
    if thread.rollout_path.exists():
        candidates.extend((normalize_text(text), "session_user_message") for text in iter_session_user_texts(thread.rollout_path))
    scored_candidates = [
        (source_score(text, label, workspace_root, order), text, label)
        for order, (text, label) in enumerate(candidates)
    ]
    best_score, best_text, best_label = max(scored_candidates, default=(-1.0, "", "fallback"))
    if best_score >= 0.0:
        return best_text, best_label
    return title_text or first_user_text, "fallback"


def select_main_path(source_text: str, source_label: str, thread: ThreadRecord, workspace_root: Path) -> tuple[str, str]:
    candidate_paths: list[str] = [derive_project_dir(path_text, workspace_root) for path_text in extract_paths(source_text)]
    candidate_paths.extend(guess_project_paths(source_text, workspace_root))
    unique_paths: list[str] = []
    seen_paths: set[str] = set()
    for candidate_path in candidate_paths:
        lowered_path = candidate_path.lower()
        if lowered_path in seen_paths:
            continue
        seen_paths.add(lowered_path)
        unique_paths.append(candidate_path)
    if any(keyword in source_text for keyword in COMPARE_KEYWORDS) and len(unique_paths) >= 2:
        return f"{unique_paths[0]} + {unique_paths[1]}", f"{source_label}|dual_path_compare"
    if unique_paths:
        return unique_paths[0], f"{source_label}|path"
    normalized_cwd = normalize_path(thread.cwd)
    if normalized_cwd:
        return normalized_cwd, "thread_cwd"
    return str(workspace_root), "workspace_root"


def select_thread_workspace_root(thread: ThreadRecord, default_root: Path) -> Path:
    normalized_cwd = normalize_path(thread.cwd)
    if not normalized_cwd or is_under_root(normalized_cwd, default_root):
        return default_root
    cwd_path = Path(normalized_cwd)
    if cwd_path.exists() and cwd_path.is_file():
        return cwd_path.parent
    return cwd_path


def classify_thread(main_path: str, source_text: str, workspace_root: Path) -> str:
    """Classify a thread using project-domain signals before task-mode signals."""
    lowered_text = f"{main_path} {source_text}".lower()
    lowered_source = source_text.lower()
    normalized_main_path = normalize_path(main_path)
    if normalized_main_path.lower().startswith(str((workspace_root / "C++Code")).lower()):
        return "上位机代码"
    if normalized_main_path.lower().startswith(str((workspace_root / "MatlabCode")).lower()):
        return "上位机代码"
    if "ruixin_fpga_main" in lowered_text or "simplefoc_velcity_control_rx" in lowered_text:
        return "硬件端代码"
    if any(keyword in lowered_text for keyword in HARDWARE_KEYWORDS):
        return "硬件端代码"
    if any(keyword in lowered_text for keyword in SOFTWARE_KEYWORDS):
        return "上位机代码"
    if any(keyword in lowered_text for keyword in STOCK_KEYWORDS):
        return "股票与量化"
    if any(keyword in lowered_text for keyword in PRESENTATION_KEYWORDS):
        return "PPT与演示"
    if any(keyword in lowered_text for keyword in RESEARCH_KEYWORDS):
        return "科研与论文"
    if any(keyword in lowered_text for keyword in DOCUMENT_KEYWORDS):
        return "文档与报告"
    codex_path_signal = ".codex\\skills" in normalized_main_path.lower() or normalized_main_path.lower().endswith("-skill")
    if any(keyword in lowered_source for keyword in CODEX_KEYWORDS) or codex_path_signal:
        return "Codex/Skill/MCP"
    if any(keyword in lowered_source for keyword in DEPLOYMENT_KEYWORDS):
        return "工具部署与环境"
    return "其他/闲聊"


def choose_subject(source_text: str, main_path: str) -> str:
    lowered_text = source_text.lower()
    normalized_text = normalize_text(source_text)
    path_names = [Path(part).name for part in main_path.split(" + ") if part.strip()]
    meaningful_names = [name for name in path_names if name and name not in {"Codex", "C++Code", "MatlabCode"}]
    if normalized_text.lower() in GENERIC_MESSAGES:
        return "问候会话"
    if "重命名" in source_text or "改名" in source_text or ("标题" in source_text and "codex" in lowered_text):
        return "Codex 对话标题"
    if "ponytail" in lowered_text:
        return "Ponytail 插件"
    if "antigravity" in lowered_text:
        return "Antigravity CLI"
    if "grok-orchestrator" in lowered_text:
        return "Grok 编排 skill"
    if "session-handoff" in lowered_text or "handoff" in lowered_text:
        return "会话交接 skill"
    if "utf-8" in lowered_text or "记事本" in source_text or "文本编码" in source_text:
        return "文本编码"
    if "scale_recons" in lowered_text:
        return "Scale_Recons 架构"
    if any(keyword in lowered_text for keyword in ("线圈仿真", "femm", "fastHenry".lower())):
        return "线圈仿真工具"
    if any(keyword in source_text for keyword in ("新增参数", "新加参数", "上发参数")):
        return "新增上发参数"
    if any(keyword in source_text for keyword in ("应答机制", "反馈机制", "重试机制")):
        return "启动指令应答机制"
    if "token" in lowered_text and any(keyword in source_text for keyword in ("计费", "金额", "收费")):
        return "Token 计费"
    if "arduino" in lowered_text:
        return "Arduino 编译"
    if "概率性" in source_text or "cdc" in lowered_text or "亚稳态" in source_text:
        return "FPGA 概率性失效风险"
    if "客户" in source_text and "sdk" in lowered_text:
        return "SDK 客户发布包"
    if "diff_report" in lowered_text or "差异报告" in source_text:
        return "SDK 版本差异报告"
    if "build_config.h" in lowered_text:
        return "build_config.h 编码"
    if "读取这个对话" in source_text or "阅读最近的工作" in source_text:
        return "旧会话内容"
    if "位姿" in source_text and "链路" in source_text:
        return "位姿输出链路"
    if "数据入口" in source_text or "接收接口" in source_text:
        return "数据入口链路"
    if "powershell" in lowered_text or "bash" in lowered_text or "终端" in source_text:
        return "终端配置"
    if "注释" in source_text or "乱码" in source_text:
        return "代码注释与文档"
    if "电机" in source_text:
        return "电机控制链路"
    if "qt ui" in lowered_text or "mainwindow" in lowered_text or ("布局" in source_text and any(token in lowered_text for token in ("qt", ".ui", "widget", "dialog"))):
        return "Qt UI 布局"
    if "synthpilot" in lowered_text and "vivado" in lowered_text:
        return "SynthPilot 与 Vivado"
    if "ponytail-audit" in lowered_text or ("审查" in source_text and "子文件夹" in source_text):
        return "各子项目"
    if "插件" in source_text:
        return "插件配置"
    if "mcp" in lowered_text or "skill" in lowered_text:
        return "skill 与 MCP"
    if "项目用途" in source_text:
        return "项目用途"
    if meaningful_names:
        return " 与 ".join(meaningful_names[:2])
    return "相关内容"


def choose_action(source_text: str) -> str:
    lowered_text = source_text.lower()
    if "联通" in source_text or "监听" in source_text or ("synthpilot" in lowered_text and "vivado" in lowered_text):
        return "联通验证"
    if "安装" in source_text or "部署" in source_text:
        return "安装部署"
    if "修复" in source_text or "解决" in source_text:
        return "修复"
    if "更新" in source_text:
        return "更新"
    if "迁移" in source_text or "移植" in source_text:
        return "迁移"
    if "优化" in source_text:
        return "优化"
    if "核查" in source_text or "检查" in source_text or "确认" in source_text:
        return "核查"
    if "编译" in source_text or "构建" in source_text:
        return "编译并排查"
    if "对比" in source_text or "比较" in source_text:
        return "对比分析"
    if "注释" in source_text or "乱码" in source_text:
        return "分析并补充"
    if "审查" in source_text or "审阅" in source_text or "只读分析" in source_text:
        return "只读审查"
    if "阅读" in source_text or "分析" in source_text or "梳理" in source_text:
        return "分析"
    return "整理"


def build_new_title(source_text: str, main_path: str, category: str) -> str:
    subject = choose_subject(source_text, main_path)
    action = choose_action(source_text)
    if subject == "问候会话":
        summary = "问候会话"
    elif subject == "旧会话内容":
        summary = "读取旧会话内容"
    else:
        summary = f"{action}{subject}"
    new_title = f"{category}-{main_path}-{summary}"
    new_title = re.sub(r"\s+", " ", new_title).strip(" -")
    return new_title


def assess_preview_confidence(source_text: str, source_label: str, evidence_source: str, new_title: str) -> tuple[str, str]:
    reasons: list[str] = []
    if source_label in {"fallback", "session_user_message"}:
        reasons.append("主题不来自当前标题")
    if evidence_source in {"thread_cwd", "workspace_root"}:
        reasons.append("路径仅来自工作区")
    if any(token in new_title for token in ("相关内容", "分析skill 与 MCP", "分析代码注释与文档")):
        reasons.append("摘要较泛")
    if any(keyword in source_text.lower() for keyword in META_TASK_KEYWORDS):
        reasons.append("来源包含交接或恢复指令")
    if reasons:
        return "低" if len(reasons) >= 2 else "中", "；".join(reasons)
    return "高", "路径和主题证据明确"


def load_union_threads() -> list[ThreadRecord]:
    thread_map: dict[str, ThreadRecord] = {}
    for database_path in (LEGACY_STATE_DB, LIVE_STATE_DB):
        if not database_path.exists():
            continue
        with closing(sqlite3.connect(database_path)) as connection:
            cursor = connection.cursor()
            rows = cursor.execute(
                """
                select id, coalesce(title, ''), rollout_path, coalesce(cwd, ''), coalesce(first_user_message, ''), coalesce(updated_at, 0)
                from threads
                where thread_source = 'user'
                order by updated_at asc
                """
            ).fetchall()
        for thread_id, old_title, rollout_path, cwd, first_user_message, updated_at in rows:
            thread_map[thread_id] = ThreadRecord(thread_id, old_title, Path(rollout_path), cwd, first_user_message, float(updated_at))
    return sorted(thread_map.values(), key=lambda record: (record.updated_at, record.thread_id))


def load_target_threads(workspace_root: Path, include_all_user_threads: bool = False) -> list[ThreadRecord]:
    target_threads: list[ThreadRecord] = []
    root_text = str(workspace_root).lower()
    for thread in load_union_threads():
        if include_all_user_threads:
            target_threads.append(thread)
            continue
        lowered_title = normalize_text(thread.old_title).lower()
        lowered_message = normalize_text(thread.first_user_message).lower()
        if is_under_root(thread.cwd, workspace_root) or root_text in lowered_title or root_text in lowered_message:
            target_threads.append(thread)
    return target_threads


def load_catalog_source_rows() -> list[tuple[str, str, float, float, str, str | None, str | None, str | None]]:
    source_map: dict[str, tuple[str, str, float, float, str, str | None, str | None, str | None]] = {}
    for database_path in (LEGACY_STATE_DB, LIVE_STATE_DB):
        if not database_path.exists():
            continue
        with closing(sqlite3.connect(database_path)) as connection:
            cursor = connection.cursor()
            rows = cursor.execute(
                """
                select id, title, created_at, updated_at, cwd, source, model_provider, git_branch
                from threads
                where thread_source = 'user'
                order by updated_at asc
                """
            ).fetchall()
        for thread_id, title, created_at, updated_at, cwd, source, model_provider, git_branch in rows:
            source_map[thread_id] = (
                thread_id,
                title,
                float(created_at),
                float(updated_at),
                normalize_path(cwd),
                source,
                model_provider,
                git_branch,
            )
    return sorted(source_map.values(), key=lambda row: (row[3], row[0]))


def ensure_unique_titles(records: list[RenameRecord]) -> list[RenameRecord]:
    seen_titles: dict[str, int] = {}
    unique_records: list[RenameRecord] = []
    for record in records:
        count = seen_titles.get(record.new_title, 0) + 1
        seen_titles[record.new_title] = count
        if count > 1:
            record.new_title = f"{record.new_title}（{count}）"
        unique_records.append(record)
    return unique_records


def build_preview_records(workspace_root: Path, include_all_user_threads: bool = False) -> list[RenameRecord]:
    rename_records: list[RenameRecord] = []
    for thread in load_target_threads(workspace_root, include_all_user_threads):
        thread_workspace_root = select_thread_workspace_root(thread, workspace_root) if include_all_user_threads else workspace_root
        structured_title = parse_structured_title(thread.old_title)
        if structured_title is not None:
            category, main_path, summary = structured_title
            structured_source = summary or thread.old_title
            if is_substantial_message(thread.first_user_message, thread_workspace_root):
                structured_source = thread.first_user_message
            reclassified_category = classify_thread(main_path or str(thread_workspace_root), structured_source, thread_workspace_root)
            if reclassified_category == category:
                rename_records.append(
                    RenameRecord(
                        thread.thread_id,
                        thread.old_title,
                        thread.old_title,
                        category,
                        main_path or str(workspace_root),
                        "existing_structured_title",
                        str(thread.rollout_path),
                        "高",
                        "已有结构化标题且分类一致",
                    )
                )
                continue
            if main_path:
                new_title = build_new_title(structured_source, main_path, reclassified_category)
                confidence, review_reason = assess_preview_confidence(structured_source, "structured_title", "structured_title_reclassified", new_title)
                rename_records.append(RenameRecord(thread.thread_id, thread.old_title, new_title, reclassified_category, main_path, "structured_title_reclassified", str(thread.rollout_path), confidence, review_reason))
                continue
        source_text, source_label = select_source_text(thread, thread_workspace_root)
        main_path, evidence_source = select_main_path(source_text, source_label, thread, thread_workspace_root)
        category = classify_thread(main_path, source_text, thread_workspace_root)
        new_title = build_new_title(source_text, main_path, category)
        confidence, review_reason = assess_preview_confidence(source_text, source_label, evidence_source, new_title)
        rename_records.append(RenameRecord(thread.thread_id, thread.old_title, new_title, category, main_path, evidence_source, str(thread.rollout_path), confidence, review_reason))
    return ensure_unique_titles(rename_records)


def write_preview(records: list[RenameRecord], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as preview_file:
        writer = csv.writer(preview_file)
        writer.writerow(["thread_id", "旧标题", "新标题", "类别", "主路径", "证据来源", "rollout_path", "置信度", "核查原因"])
        for record in records:
            writer.writerow([record.thread_id, record.old_title, record.new_title, record.category, record.main_path, record.evidence_source, record.rollout_path, record.confidence, record.review_reason])
    return


def load_mapping(mapping_path: Path) -> list[tuple[str, str]]:
    """Load and validate a reviewed CSV mapping before any persistent write begins."""
    title_map: dict[str, str] = {}
    with mapping_path.open("r", encoding="utf-8-sig", newline="") as mapping_file:
        reader = csv.DictReader(mapping_file)
        title_column = "新标题" if "新标题" in (reader.fieldnames or []) else "new_title"
        if "thread_id" not in (reader.fieldnames or []) or title_column not in (reader.fieldnames or []):
            raise ValueError("mapping 必须包含 thread_id 和 新标题/new_title 列")
        for line_number, row in enumerate(reader, start=2):
            thread_id = (row.get("thread_id") or "").strip()
            new_title = (row.get(title_column) or "").strip()
            if not thread_id or not new_title:
                raise ValueError(f"mapping 第 {line_number} 行存在空 thread_id 或标题")
            if thread_id in title_map and title_map[thread_id] != new_title:
                raise ValueError(f"mapping 中 thread_id {thread_id} 出现冲突标题")
            title_map[thread_id] = new_title
    if not title_map:
        raise ValueError("mapping 没有可应用的标题")
    known_thread_ids = {thread.thread_id for thread in load_union_threads()}
    unknown_thread_ids = sorted(set(title_map) - known_thread_ids)
    if unknown_thread_ids:
        raise ValueError(f"mapping 包含未知用户线程: {', '.join(unknown_thread_ids)}")
    return list(title_map.items())


def sqlite_snapshot(source_path: Path, snapshot_path: Path) -> None:
    snapshot_path.parent.mkdir(parents=True, exist_ok=True)
    source_uri = f"file:{source_path.as_posix()}?mode=ro"
    with closing(sqlite3.connect(source_uri, uri=True)) as source_connection, closing(sqlite3.connect(snapshot_path)) as snapshot_connection:
        source_connection.backup(snapshot_connection)
    return


def make_backup() -> Path:
    backup_dir = CODEX_HOME / f"backup-{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}-thread-rename-skill"
    backup_dir.mkdir(parents=True, exist_ok=False)
    for source_path, relative_snapshot in (
        (LIVE_STATE_DB, Path("live") / "state_5.sqlite"),
        (LEGACY_STATE_DB, Path("legacy") / "state_5.sqlite"),
        (LOCAL_CATALOG_DB, Path("catalog") / "codex-dev.db"),
    ):
        if source_path.exists():
            sqlite_snapshot(source_path, backup_dir / relative_snapshot)
    if SESSION_INDEX.exists():
        shutil.copy2(SESSION_INDEX, backup_dir / "session_index.jsonl")
    return backup_dir


def restore_backup(backup_dir: Path) -> None:
    for snapshot_path, destination_path in (
        (backup_dir / "live" / "state_5.sqlite", LIVE_STATE_DB),
        (backup_dir / "legacy" / "state_5.sqlite", LEGACY_STATE_DB),
        (backup_dir / "catalog" / "codex-dev.db", LOCAL_CATALOG_DB),
    ):
        if snapshot_path.exists():
            with closing(sqlite3.connect(snapshot_path)) as snapshot_connection, closing(sqlite3.connect(destination_path)) as destination_connection:
                snapshot_connection.backup(destination_connection)
    index_snapshot = backup_dir / "session_index.jsonl"
    if index_snapshot.exists():
        atomic_replace_bytes(SESSION_INDEX, index_snapshot.read_bytes())
    return


def require_table_columns(database_path: Path, table_name: str, required_columns: set[str]) -> None:
    if not database_path.exists():
        raise FileNotFoundError(database_path)
    database_uri = f"file:{database_path.as_posix()}?mode=ro"
    with closing(sqlite3.connect(database_uri, uri=True)) as connection:
        table_row = connection.execute("select 1 from sqlite_master where type = 'table' and name = ?", (table_name,)).fetchone()
        if table_row is None:
            raise RuntimeError(f"{database_path} 缺少表 {table_name}")
        columns = {row[1] for row in connection.execute(f"pragma table_info({table_name})")}
    missing_columns = required_columns - columns
    if missing_columns:
        raise RuntimeError(f"{database_path}:{table_name} 缺少列 {sorted(missing_columns)}")
    return


def validate_apply_inputs() -> None:
    for database_path in (LIVE_STATE_DB, LEGACY_STATE_DB):
        require_table_columns(database_path, "threads", {"id", "title", "thread_source"})
    require_table_columns(LOCAL_CATALOG_DB, "local_thread_catalog", {"host_id", "thread_id", "display_title"})
    require_table_columns(LOCAL_CATALOG_DB, "local_thread_catalog_metadata", {"id", "catalog_revision"})
    validate_session_index()
    return


def update_state_databases(mapping_rows: list[tuple[str, str]]) -> int:
    updated_rows = 0
    for database_path in (LIVE_STATE_DB, LEGACY_STATE_DB):
        if not database_path.exists():
            continue
        with closing(sqlite3.connect(database_path)) as connection:
            cursor = connection.cursor()
            for thread_id, new_title in mapping_rows:
                cursor.execute("update threads set title = ? where id = ?", (new_title, thread_id))
                updated_rows += cursor.rowcount
            connection.commit()
    return updated_rows


def rebuild_local_catalog(mapping_rows: list[tuple[str, str]]) -> int:
    """Synchronize only mapped display titles while preserving unrelated UI metadata."""
    synchronized_rows = 0
    with closing(sqlite3.connect(LOCAL_CATALOG_DB)) as catalog_connection:
        catalog_cursor = catalog_connection.cursor()
        source_map = {row[0]: row for row in load_catalog_source_rows()}
        next_sequence = int(catalog_cursor.execute("select coalesce(max(observation_sequence), 0) + 1 from local_thread_catalog").fetchone()[0])
        for thread_id, new_title in mapping_rows:
            catalog_cursor.execute(
                "update local_thread_catalog set display_title = ?, missing_candidate = 0 where host_id = 'local' and thread_id = ?",
                (new_title, thread_id),
            )
            if catalog_cursor.rowcount:
                synchronized_rows += catalog_cursor.rowcount
                continue
            source_row = source_map.get(thread_id)
            if source_row is None:
                raise RuntimeError(f"无法为目录缓存找到线程 {thread_id}")
            _, _title, created_at, updated_at, cwd, source, model_provider, git_branch = source_row
            catalog_cursor.execute(
                """
                insert into local_thread_catalog (
                    host_id, thread_id, display_title, source_created_at, source_updated_at,
                    cwd, source_kind, source_detail, model_provider, git_branch,
                    observation_sequence, missing_candidate
                ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """,
                ("local", thread_id, new_title, created_at, updated_at, cwd, source, None, model_provider, git_branch, next_sequence),
            )
            next_sequence += 1
            synchronized_rows += 1
        catalog_cursor.execute(
            """
            insert into local_thread_catalog_metadata (id, catalog_revision)
            values (1, 1)
            on conflict(id) do update set
                catalog_revision = local_thread_catalog_metadata.catalog_revision + 1
            """
        )
        catalog_connection.commit()
    return synchronized_rows


def validate_session_index() -> None:
    if not SESSION_INDEX.exists():
        return
    with SESSION_INDEX.open("r", encoding="utf-8") as session_index_file:
        for line_number, line in enumerate(session_index_file, start=1):
            if not line.strip():
                continue
            try:
                json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"session_index.jsonl 第 {line_number} 行损坏") from error
    return


def atomic_replace_bytes(destination_path: Path, content: bytes) -> None:
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination_path.name}.", dir=destination_path.parent)
    try:
        with os.fdopen(file_descriptor, "wb") as temporary_file:
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_name, destination_path)
    except Exception:
        Path(temporary_name).unlink(missing_ok=True)
        raise
    return


def update_session_index(mapping_rows: list[tuple[str, str]]) -> int:
    if not SESSION_INDEX.exists():
        return 0
    title_map = {thread_id: new_title for thread_id, new_title in mapping_rows}
    updated_rows = 0
    rewritten_lines: list[str] = []
    with SESSION_INDEX.open("r", encoding="utf-8") as session_index_file:
        for line in session_index_file:
            stripped_line = line.strip()
            if not stripped_line:
                rewritten_lines.append(line)
                continue
            row = json.loads(stripped_line)
            thread_id = row.get("id", "")
            if thread_id in title_map:
                row["thread_name"] = title_map[thread_id]
                updated_rows += 1
            rewritten_lines.append(json.dumps(row, ensure_ascii=False) + "\n")
    atomic_replace_bytes(SESSION_INDEX, "".join(rewritten_lines).encode("utf-8"))
    return updated_rows


def verify_mapping(mapping_rows: list[tuple[str, str]]) -> list[str]:
    """Return every mapped thread whose persisted title differs in a storage layer."""
    expected_titles = dict(mapping_rows)
    mismatches: list[str] = []
    for database_path in (LIVE_STATE_DB, LEGACY_STATE_DB):
        database_uri = f"file:{database_path.as_posix()}?mode=ro"
        with closing(sqlite3.connect(database_uri, uri=True)) as connection:
            for thread_id, expected_title in mapping_rows:
                row = connection.execute("select title from threads where id = ? and thread_source = 'user'", (thread_id,)).fetchone()
                if row is not None and row[0] != expected_title:
                    mismatches.append(f"{database_path.name}:{thread_id}")
    catalog_uri = f"file:{LOCAL_CATALOG_DB.as_posix()}?mode=ro"
    with closing(sqlite3.connect(catalog_uri, uri=True)) as connection:
        for thread_id, expected_title in mapping_rows:
            row = connection.execute("select display_title from local_thread_catalog where host_id = 'local' and thread_id = ?", (thread_id,)).fetchone()
            if row is None or row[0] != expected_title:
                mismatches.append(f"codex-dev.db:{thread_id}")
    if SESSION_INDEX.exists():
        with SESSION_INDEX.open("r", encoding="utf-8") as session_index_file:
            for line in session_index_file:
                if not line.strip():
                    continue
                row = json.loads(line)
                thread_id = row.get("id", "")
                if thread_id in expected_titles and row.get("thread_name") != expected_titles[thread_id]:
                    mismatches.append(f"session_index.jsonl:{thread_id}")
    return mismatches


def create_self_check_state_database(database_path: Path) -> None:
    """Create the smallest state database needed for the isolated write-path check."""
    with closing(sqlite3.connect(database_path)) as connection:
        connection.execute(
            """
            create table threads (
                id text primary key, title text, rollout_path text, cwd text,
                first_user_message text, created_at real, updated_at real,
                thread_source text, source text, model_provider text, git_branch text
            )
            """
        )
        connection.execute(
            "insert into threads values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("thread-1", "旧标题", "missing.jsonl", r"D:\Project", "分析项目", 1.0, 2.0, "user", "app", "openai", None),
        )
        connection.commit()
    return


def create_self_check_catalog_database(database_path: Path) -> None:
    """Create a minimal UI catalog that also detects accidental metadata erasure."""
    with closing(sqlite3.connect(database_path)) as connection:
        connection.execute(
            """
            create table local_thread_catalog (
                host_id text, thread_id text, display_title text,
                source_created_at real, source_updated_at real, cwd text,
                source_kind text, source_detail text, model_provider text,
                git_branch text, observation_sequence integer, missing_candidate integer,
                unique(host_id, thread_id)
            )
            """
        )
        connection.execute("create table local_thread_catalog_metadata (id integer primary key, catalog_revision integer)")
        connection.execute(
            "insert into local_thread_catalog values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("local", "thread-1", "旧标题", 1.0, 2.0, r"D:\Project", "app", "preserve-me", "openai", None, 1, 0),
        )
        connection.commit()
    return


def self_check() -> int:
    """Run path parsing and an isolated end-to-end storage synchronization check."""
    global CODEX_HOME, LIVE_STATE_DB, LEGACY_STATE_DB, LOCAL_CATALOG_DB, SESSION_INDEX
    assert normalize_path(r"\\?\D:/Workspace/Codex/") == r"D:\Workspace\Codex"
    assert is_under_root(r"D:\Workspace\Codex\C++Code\RX-SDK", Path(r"D:\Workspace\Codex"))
    assert not is_under_root(r"D:\Workspace\Codex-YJD", Path(r"D:\Workspace\Codex"))
    assert parse_structured_title("其他-D:\\Project-旧标题") is not None
    assert parse_structured_title("Codex/Skill/MCP-D:\\Project-skill") is not None
    assert classify_thread(r"D:\Workspace\Codex\C++Code\RX-SDK", "分析 RX-SDK", Path(r"D:\Workspace\Codex")) == "上位机代码"
    assert classify_thread(r"D:\Workspace\Codex\RuiXin_FPGA_Main_V1.6.6", "分析 FPGA 电机控制", Path(r"D:\Workspace\Codex")) == "硬件端代码"
    assert select_main_path("你好", "fallback", ThreadRecord("1", "你好", Path("."), r"\\?\C:\Example\Documents\Codex\2026-06-07\new-chat", "你好", 0.0), Path(r"D:\Workspace\Codex"))[0] == r"C:\Example\Documents\Codex\2026-06-07\new-chat"
    original_paths = (CODEX_HOME, LIVE_STATE_DB, LEGACY_STATE_DB, LOCAL_CATALOG_DB, SESSION_INDEX)
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_root = Path(temporary_directory)
        default_root = temporary_root / "Codex"
        sibling_root = temporary_root / "Codex-线圈仿真"
        default_root.mkdir()
        sibling_root.mkdir()
        assert derive_project_dir(str(sibling_root), default_root) == str(sibling_root)
        assert extract_paths(f"{sibling_root} 读取项目")[0] == str(sibling_root)
        CODEX_HOME = temporary_root / ".codex"
        LIVE_STATE_DB = CODEX_HOME / "sqlite" / "state_5.sqlite"
        LEGACY_STATE_DB = CODEX_HOME / "state_5.sqlite"
        LOCAL_CATALOG_DB = CODEX_HOME / "sqlite" / "codex-dev.db"
        SESSION_INDEX = CODEX_HOME / "session_index.jsonl"
        LIVE_STATE_DB.parent.mkdir(parents=True)
        create_self_check_state_database(LIVE_STATE_DB)
        create_self_check_state_database(LEGACY_STATE_DB)
        create_self_check_catalog_database(LOCAL_CATALOG_DB)
        SESSION_INDEX.write_text('{"id":"thread-1","thread_name":"旧标题"}\n', encoding="utf-8")
        mapping_path = temporary_root / "mapping.csv"
        mapping_path.write_text("thread_id,新标题\nthread-1,其他/闲聊-D:\\Project-核查项目\n", encoding="utf-8")
        run_apply(mapping_path)
        mapping_rows = load_mapping(mapping_path)
        assert not verify_mapping(mapping_rows)
        with closing(sqlite3.connect(LOCAL_CATALOG_DB)) as connection:
            assert connection.execute("select source_detail from local_thread_catalog where thread_id = 'thread-1'").fetchone()[0] == "preserve-me"
        backup_directories = list(CODEX_HOME.glob("backup-*-thread-rename-skill"))
        assert len(backup_directories) == 1
        assert (backup_directories[0] / "live" / "state_5.sqlite").exists()
        assert (backup_directories[0] / "legacy" / "state_5.sqlite").exists()
        restore_backup(backup_directories[0])
        with closing(sqlite3.connect(LIVE_STATE_DB)) as connection:
            assert connection.execute("select title from threads where id = 'thread-1'").fetchone()[0] == "旧标题"
        with closing(sqlite3.connect(LOCAL_CATALOG_DB)) as connection:
            assert connection.execute("select display_title from local_thread_catalog where thread_id = 'thread-1'").fetchone()[0] == "旧标题"
        assert json.loads(SESSION_INDEX.read_text(encoding="utf-8"))["thread_name"] == "旧标题"
    CODEX_HOME, LIVE_STATE_DB, LEGACY_STATE_DB, LOCAL_CATALOG_DB, SESSION_INDEX = original_paths
    print("self_check=ok")
    return 0


def run_preview(workspace_root: Path, output_path: Path, include_all_user_threads: bool = False) -> int:
    records = build_preview_records(workspace_root, include_all_user_threads)
    write_preview(records, output_path)
    print(f"preview_count={len(records)}")
    print(f"preview_file={output_path}")
    return 0


def run_apply(mapping_path: Path) -> int:
    mapping_rows = load_mapping(mapping_path)
    validate_apply_inputs()
    backup_dir = make_backup()
    try:
        updated_state_rows = update_state_databases(mapping_rows)
        updated_catalog_rows = rebuild_local_catalog(mapping_rows)
        updated_index_rows = update_session_index(mapping_rows)
        mismatches = verify_mapping(mapping_rows)
        if mismatches:
            raise RuntimeError(f"写后核对失败: {', '.join(mismatches)}")
    except Exception:
        restore_backup(backup_dir)
        raise
    print(f"backup_dir={backup_dir}")
    print(f"updated_state_rows={updated_state_rows}")
    print(f"updated_catalog_rows={updated_catalog_rows}")
    print(f"updated_index_rows={updated_index_rows}")
    print("verification=ok")
    return 0


def run_validate(mapping_path: Path) -> int:
    mapping_rows = load_mapping(mapping_path)
    validate_apply_inputs()
    titles = [title for _thread_id, title in mapping_rows]
    if len(titles) != len(set(titles)):
        raise ValueError("mapping 包含重复的新标题")
    print(f"mapping_count={len(mapping_rows)}")
    print("validation=ok")
    return 0


def run_verify(mapping_path: Path) -> int:
    mapping_rows = load_mapping(mapping_path)
    mismatches = verify_mapping(mapping_rows)
    if mismatches:
        raise RuntimeError(f"核对失败: {', '.join(mismatches)}")
    print(f"mapping_count={len(mapping_rows)}")
    print("verification=ok")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Codex 本地历史线程分类与改名脚本。")
    subparsers = parser.add_subparsers(dest="command", required=True)
    preview_parser = subparsers.add_parser("preview")
    preview_parser.add_argument("--workspace-root", required=True, type=Path)
    preview_parser.add_argument("--output", type=Path, default=DEFAULT_PREVIEW)
    preview_parser.add_argument("--all-user-threads", action="store_true")
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("--mapping", required=True, type=Path)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--mapping", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--mapping", required=True, type=Path)
    subparsers.add_parser("self-check")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "preview":
        return run_preview(args.workspace_root.resolve(), args.output.resolve(), args.all_user_threads)
    if args.command == "apply":
        return run_apply(args.mapping.resolve())
    if args.command == "validate":
        return run_validate(args.mapping.resolve())
    if args.command == "verify":
        return run_verify(args.mapping.resolve())
    if args.command == "self-check":
        return self_check()
    raise SystemExit("unknown command")


if __name__ == "__main__":
    raise SystemExit(main())
