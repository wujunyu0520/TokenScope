#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_STRINGS = ROOT / "Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings"
CORE_STRINGS = ROOT / "Sources/TokenScopeCore/Resources/zh-Hans.lproj/Localizable.strings"
APP_SOURCES = ROOT / "Sources/TokenScopeApp"
CORE_SOURCES = ROOT / "Sources/TokenScopeCore"

# Baseline gate for key user-facing strings.
# Expand as UI strings are localized; this is not an exhaustive extractor.
REQUIRED_APP = {
    "Dashboard": "仪表盘",
    "Usage": "用量",
    "Sessions": "会话",
    "Pricing": "价格",
    "Backup": "备份",
    "Settings": "设置",
    "Refresh": "刷新",
    "Clear": "清除",
    "Add": "添加",
    "Edit": "编辑",
    "Save": "保存",
    "Cancel": "取消",
    "Close": "关闭",
    "Provider Usage": "服务用量",
    "Last updated: %@": "最后更新：%@",
    "Cached · %@": "已缓存 · %@",
    "Latest data is being verified": "正在验证最新数据",
    "Previous successful update: %@": "上次成功更新：%@",
    "Not live": "非实时",
    "Snapshot updated: %@": "快照更新时间：%@",
    "Refresh error: %@": "刷新错误：%@",
    "Last successful update: %@": "上次成功更新：%@",
    "Local session logs; not an official subscription quota.": "本地会话日志；并非官方订阅额度。",
    "Quota from OpenAI's official API; local cost is an estimate.": "额度来自 OpenAI 官方 API；本地成本为估算值。",
    "No usage data available.": "暂无用量数据。",
    "No usage data available yet.": "暂无用量数据。",
    "Configure a z.ai API key in Settings to load usage.": "请在设置中配置 z.ai API Key 后加载用量。",
    "Monthly Usage": "月度用量",
    "No usage in selected range": "所选范围内暂无用量",
    "Activity Heatmap": "活跃度热力图",
    "Daily tokens across the selected range": "所选范围内每日 Token 用量（单位：亿）",
    "No activity in selected range": "所选范围内暂无活动",
    "%d active days · peak %@": "%d 个活跃日 · 峰值 %@",
    "Total Tokens": "总 Token",
    "Input": "输入",
    "Output": "输出",
    "Cache Read": "缓存读取",
    "Cache Create": "缓存写入",
    "API cost estimate": "API 成本估算",
    "API est.": "API 估算",
    "Unpriced": "未定价",
    "Vendor": "厂商",
    "Aliases": "别名",
    "Verified": "核验日期",
    "Started": "开始时间",
    "Project": "项目",
    "Models": "模型",
    "Msgs": "消息数",
    "Hide 0-msg": "隐藏 0 消息",
    "Search project": "搜索项目",
    "Loading session…": "正在加载会话…",
    "Edit Price": "编辑价格",
    "Add Price": "添加价格",
    "Delete Override": "删除自定义价格",
    "Pricing (USD per 1M tokens)": "价格（USD / 每 100 万 tokens）",
    "System account": "系统账号",
    "Signing in…": "正在登录…",
    "Add Account": "添加账号",
    "Configured": "已配置",
    "Missing API key": "缺少 API Key",
    "Not refreshed": "尚未刷新",
    "Cached": "已缓存",
    "Refreshing...": "正在刷新...",
    "Ready": "就绪",
    "Failed": "失败",
    "Directories": "目录",
}

REQUIRED_CORE = {
    "Usage is unavailable for this provider.": "该服务暂不支持用量查询。",
    "Failed to load detailed session records.": "无法加载会话明细记录。",
    "Codex auth.json not found. Please sign in first.": "未找到 Codex auth.json，请先登录。",
    "Codex auth.json exists but contains no usable tokens.": "Codex auth.json 存在，但没有可用 token。",
    "Refresh token expired. Please sign in again.": "刷新 token 已过期，请重新登录。",
    "Invalid response from Codex usage API.": "Codex 用量 API 返回无效响应。",
    "z.ai API key is not configured.": "尚未配置 z.ai API Key。",
    "Invalid z.ai API credentials.": "z.ai API 凭据无效。",
    "Unknown error": "未知错误",
}

ENTRY_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
HELPER_CALL_RE_TEMPLATE = r"\b{helper}\.string\(\s*\"((?:[^\"\\]|\\.)*)\""


def load_strings(path: Path) -> dict[str, str]:
    data = path.read_text(encoding="utf-8")
    return {key: value for key, value in ENTRY_RE.findall(data)}


def extract_helper_keys(source_dir: Path, helper: str) -> dict[str, list[str]]:
    pattern = re.compile(HELPER_CALL_RE_TEMPLATE.format(helper=re.escape(helper)), re.MULTILINE | re.DOTALL)
    keys: dict[str, list[str]] = {}

    for path in sorted(source_dir.rglob("*.swift")):
        data = path.read_text(encoding="utf-8")
        for match in pattern.finditer(data):
            key = match.group(1)
            line = data.count("\n", 0, match.start()) + 1
            keys.setdefault(key, []).append(f"{path.relative_to(ROOT)}:{line}")

    return keys


def check(path: Path, required: dict[str, str], helper_keys: dict[str, list[str]]) -> list[str]:
    errors: list[str] = []
    if not path.exists():
        errors.append(f"missing strings file: {path.relative_to(ROOT)}")
        return errors

    entries = load_strings(path)
    for key, locations in helper_keys.items():
        if key not in entries:
            errors.append(
                f"missing localized helper key in {path.relative_to(ROOT)}: {key} "
                f"({', '.join(locations[:3])})"
            )

    for key, expected in required.items():
        actual = entries.get(key)
        if actual is None:
            errors.append(f"missing key in {path.relative_to(ROOT)}: {key}")
        elif actual != expected:
            errors.append(f"wrong translation for {key!r}: expected {expected!r}, got {actual!r}")
    return errors


def main() -> int:
    app_helper_keys = extract_helper_keys(APP_SOURCES, "L10n")
    core_helper_keys = extract_helper_keys(CORE_SOURCES, "CoreL10n")
    errors = (
        check(APP_STRINGS, REQUIRED_APP, app_helper_keys)
        + check(CORE_STRINGS, REQUIRED_CORE, core_helper_keys)
    )
    if errors:
        print("\n".join(errors))
        return 1
    print("zh-Hans localization check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
