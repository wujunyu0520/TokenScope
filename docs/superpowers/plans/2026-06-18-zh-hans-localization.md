# TokenScope Chinese Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize TokenScope's user-facing macOS UI into Simplified Chinese while preserving technical identifiers such as model names, provider names, API Key labels, file paths, USD amounts, and token units.

**Architecture:** Add explicit localization helpers and `zh-Hans` resource bundles for the app and core targets. UI code will call localization helpers for labels, buttons, table headers, empty states, status text, and errors; data identifiers and formatting strings remain unchanged. The packaging script will copy SwiftPM resource bundles into `TokenScope.app` so release zips display Chinese.

**Tech Stack:** Swift 5.9 package, SwiftUI, SwiftPM localized resources, macOS 14, Bash packaging script, Python static localization check.

---

## File Structure

- Modify `Package.swift`
  - Add `defaultLocalization: "en"`.
  - Add `.process("Resources")` to `TokenScopeApp` and `TokenScopeCore` targets.
- Create `Sources/TokenScopeApp/Localization/L10n.swift`
  - App-target helper that loads `zh-Hans.lproj/Localizable.strings` from `Bundle.module` and falls back to the English key.
- Create `Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings`
  - Chinese translations for navigation, buttons, table headers, dashboard, sessions, usage, pricing, settings, backup, and empty states.
- Create `Sources/TokenScopeCore/Localization/CoreL10n.swift`
  - Core-target helper for localized error descriptions and notices emitted by providers/parsers.
- Create `Sources/TokenScopeCore/Resources/zh-Hans.lproj/Localizable.strings`
  - Chinese translations for errors and notices that surface in the UI.
- Modify `Scripts/package_app.sh`
  - Copy `TokenScope_*.bundle` resource bundles from the SwiftPM build output into `TokenScope.app/Contents/Resources`.
  - Add `CFBundleLocalizations` for `en` and `zh-Hans`.
- Modify UI files:
  - `Sources/TokenScopeApp/Views/RootView.swift`
  - `Sources/TokenScopeApp/Views/DashboardView.swift`
  - `Sources/TokenScopeApp/Views/UsageView.swift`
  - `Sources/TokenScopeApp/Views/SessionsView.swift`
  - `Sources/TokenScopeApp/Views/SessionDetailView.swift`
  - `Sources/TokenScopeApp/Views/PricingView.swift`
  - `Sources/TokenScopeApp/Views/SettingsView.swift`
  - `Sources/TokenScopeApp/Views/BackupView.swift`
- Modify app/core status and error files:
  - `Sources/TokenScopeApp/Stores/AppStore.swift`
  - `Sources/TokenScopeApp/Stores/CodexAccountLoginController.swift`
  - `Sources/TokenScopeCore/Providers/CodexOAuthSupport.swift`
  - `Sources/TokenScopeCore/Providers/ZaiUsageProvider.swift`
- Create `Scripts/check_zh_hans_localization.py`
  - Static gate for required Chinese keys and expected residual English.

## Scope Rules

- Localize:
  - Navigation: Dashboard, Usage, Sessions, Pricing, Backup, Settings.
  - Buttons and commands: Refresh, Clear, Add, Edit, Save, Cancel, Close, Add Account, Delete Override.
  - Table headers: Started, Provider, Project, Models, Msgs, In, Out, Cache R, Cache W, Cost, Source, Time, Model, Input, Output.
  - Settings sections and status: About, Version, Usage Providers, Directories, Configured, Missing API key, Cached, Ready, Failed, Refreshing.
  - Empty/loading states and notices.
  - Error descriptions shown to the user.
- Preserve:
  - Product name `TokenScope`.
  - Provider display names such as `Claude Code`, `Codex`, `OpenCode`, `z.ai`, `OpenAI API`, `Anthropic API`, `GLM API`.
  - Model names such as `glm-4.7`, `claude-opus-4-6`, `gpt-*`.
  - `API Key`, `USD`, `$`, account emails, filesystem paths, URLs, CLI names, JSON field names, and raw error payloads.
  - Numeric/date formatting behavior unless the date is already system-locale formatted by Swift.

## Task 1: Add A Failing Localization Gate

**Files:**
- Create: `Scripts/check_zh_hans_localization.py`

- [ ] **Step 1: Create the static check script**

```python
#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_STRINGS = ROOT / "Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings"
CORE_STRINGS = ROOT / "Sources/TokenScopeCore/Resources/zh-Hans.lproj/Localizable.strings"

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
    "No usage data available.": "暂无用量数据。",
    "No usage data available yet.": "暂无用量数据。",
    "Configure a z.ai API key in Settings to load usage.": "请在设置中配置 z.ai API Key 后加载用量。",
    "Monthly Usage": "月度用量",
    "No usage in selected range": "所选范围内暂无用量",
    "Activity Heatmap": "活跃度热力图",
    "Daily tokens across the selected range": "所选范围内每日 Token 用量",
    "No activity in selected range": "所选范围内暂无活动",
    "%d active days · peak %@ tok": "%d 个活跃日 · 峰值 %@ tok",
    "Sessions": "会话",
    "Total Tokens": "总 Token",
    "Input": "输入",
    "Output": "输出",
    "Cache Read": "缓存读取",
    "Cache Create": "缓存写入",
    "Cost (est.)": "成本（估算）",
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
}

ENTRY_RE = re.compile(r'"((?:[^"\\\\]|\\\\.)*)"\s*=\s*"((?:[^"\\\\]|\\\\.)*)"\s*;')

def load_strings(path: Path) -> dict[str, str]:
    if not path.exists():
        raise AssertionError(f"missing strings file: {path.relative_to(ROOT)}")
    data = path.read_text(encoding="utf-8")
    return {key: value for key, value in ENTRY_RE.findall(data)}

def check(path: Path, required: dict[str, str]) -> list[str]:
    entries = load_strings(path)
    errors: list[str] = []
    for key, expected in required.items():
        actual = entries.get(key)
        if actual is None:
            errors.append(f"missing key in {path.relative_to(ROOT)}: {key}")
        elif actual != expected:
            errors.append(f"wrong translation for {key!r}: expected {expected!r}, got {actual!r}")
    return errors

def main() -> int:
    errors = check(APP_STRINGS, REQUIRED_APP) + check(CORE_STRINGS, REQUIRED_CORE)
    if errors:
        print("\n".join(errors))
        return 1
    print("zh-Hans localization check passed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run the script and verify it fails before implementation**

Run:

```bash
python3 Scripts/check_zh_hans_localization.py
```

Expected: exit code `1` with missing `Localizable.strings` file errors.

- [ ] **Step 3: Commit the failing gate**

```bash
git add Scripts/check_zh_hans_localization.py
git commit -m "test: add zh-Hans localization gate"
```

## Task 2: Add Localization Resources And Helpers

**Files:**
- Modify: `Package.swift`
- Create: `Sources/TokenScopeApp/Localization/L10n.swift`
- Create: `Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings`
- Create: `Sources/TokenScopeCore/Localization/CoreL10n.swift`
- Create: `Sources/TokenScopeCore/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Update `Package.swift`**

Change the package initializer and target definitions to:

```swift
let package = Package(
    name: "TokenScope",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenScopeApp", targets: ["TokenScopeApp"]),
        .library(name: "TokenScopeCore", targets: ["TokenScopeCore"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TokenScopeApp",
            dependencies: ["TokenScopeCore"],
            path: "Sources/TokenScopeApp",
            resources: [.process("Resources")]
        ),
        .target(
            name: "TokenScopeCore",
            path: "Sources/TokenScopeCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TokenScopeCoreTests",
            dependencies: ["TokenScopeCore"],
            path: "Tests/TokenScopeCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Add app localization helper**

Create `Sources/TokenScopeApp/Localization/L10n.swift`:

```swift
import Foundation

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: zhHansBundle ?? .module, value: key, comment: "")
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: "zh_Hans"), arguments: arguments)
    }

    private static let zhHansBundle: Bundle? = {
        guard let path = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }()
}
```

- [ ] **Step 3: Add core localization helper**

Create `Sources/TokenScopeCore/Localization/CoreL10n.swift`:

```swift
import Foundation

enum CoreL10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: zhHansBundle ?? .module, value: key, comment: "")
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: "zh_Hans"), arguments: arguments)
    }

    private static let zhHansBundle: Bundle? = {
        guard let path = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }()
}
```

- [ ] **Step 4: Create `Localizable.strings` files**

Use UTF-8 encoding. Include the exact keys required by `Scripts/check_zh_hans_localization.py`, then add remaining UI keys found while replacing strings.

- [ ] **Step 5: Run localization gate**

Run:

```bash
python3 Scripts/check_zh_hans_localization.py
```

Expected: `zh-Hans localization check passed`.

- [ ] **Step 6: Commit infrastructure**

```bash
git add Package.swift Sources/TokenScopeApp/Localization Sources/TokenScopeApp/Resources Sources/TokenScopeCore/Localization Sources/TokenScopeCore/Resources
git commit -m "feat: add zh-Hans localization resources"
```

## Task 3: Localize Navigation, Settings, Backup, Usage, And Pricing

**Files:**
- Modify: `Sources/TokenScopeApp/Views/RootView.swift`
- Modify: `Sources/TokenScopeApp/Views/SettingsView.swift`
- Modify: `Sources/TokenScopeApp/Views/BackupView.swift`
- Modify: `Sources/TokenScopeApp/Views/UsageView.swift`
- Modify: `Sources/TokenScopeApp/Views/PricingView.swift`

- [ ] **Step 1: Replace static UI strings with `L10n.string`**

Use this pattern:

```swift
Text(L10n.string("Provider Usage"))
Button(L10n.string("Refresh")) { refresh() }
Label(L10n.string("Add Price"), systemImage: "plus")
TableColumn(L10n.string("Provider"), value: \.provider.rawValue) { p in
    Text(p.provider.displayName)
}
```

- [ ] **Step 2: Localize dynamic status functions**

Change status-returning functions from hard-coded English to localized English keys:

```swift
private func providerStatusText(_ provider: Provider) -> String {
    switch store.usageRefreshStates[provider] ?? .idle {
    case .idle:
        return store.providerUsageSnapshots[provider] == nil ? L10n.string("Not refreshed") : L10n.string("Cached")
    case .loading:
        return L10n.string("Refreshing...")
    case .loaded:
        return L10n.string("Ready")
    case .failed:
        return store.usageErrors[provider] ?? L10n.string("Failed")
    }
}
```

- [ ] **Step 3: Preserve technical identifiers**

Do not wrap these values with Chinese translations:

```swift
Text(provider.displayName)
Text(p.model)
Text(account.email)
SecureField("z.ai API Key", text: $zaiAPIKey)
Text(String(format: "$%.3f", p.inputPerMillion))
Button(url.path) { NSWorkspace.shared.open(url) }
```

- [ ] **Step 4: Run static check**

```bash
python3 Scripts/check_zh_hans_localization.py
```

Expected: pass.

- [ ] **Step 5: Commit page group**

```bash
git add Sources/TokenScopeApp/Views/RootView.swift Sources/TokenScopeApp/Views/SettingsView.swift Sources/TokenScopeApp/Views/BackupView.swift Sources/TokenScopeApp/Views/UsageView.swift Sources/TokenScopeApp/Views/PricingView.swift Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat: localize primary app views"
```

## Task 4: Localize Dashboard And Session Views

**Files:**
- Modify: `Sources/TokenScopeApp/Views/DashboardView.swift`
- Modify: `Sources/TokenScopeApp/Views/SessionsView.swift`
- Modify: `Sources/TokenScopeApp/Views/SessionDetailView.swift`
- Modify: `Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Localize dashboard labels and date presets**

Use `L10n.string` for stat cards, date presets, chart labels, empty states, heatmap labels, and monthly usage labels. Keep model names and cost strings unchanged.

```swift
private enum DatePreset: CaseIterable {
    case all, today, yesterday, thisWeek, last7Days, thisMonth, lastMonth, last30Days, last60Days, last90Days, thisYear, lastYear

    var label: String {
        switch self {
        case .all: return L10n.string("All")
        case .today: return L10n.string("Today")
        case .yesterday: return L10n.string("Yesterday")
        case .thisWeek: return L10n.string("This Week")
        case .last7Days: return L10n.string("Last 7 Days")
        case .thisMonth: return L10n.string("This Month")
        case .lastMonth: return L10n.string("Last Month")
        case .last30Days: return L10n.string("Last 30 Days")
        case .last60Days: return L10n.string("Last 60 Days")
        case .last90Days: return L10n.string("Last 90 Days")
        case .thisYear: return L10n.string("This Year")
        case .lastYear: return L10n.string("Last Year")
        }
    }
}
```

- [ ] **Step 2: Localize session table and detail labels**

Use localized labels for headers and controls:

```swift
TableColumn(L10n.string("Started"), value: \.startedAt) { r in ... }
TableColumn(L10n.string("Project"), value: \.projectName) { r in ... }
ProgressView(L10n.string("Loading session…"))
Button(L10n.string("Close")) { dismiss() }
Text(L10n.string("Input %@", formatMillions(message.usage.inputTokens)))
```

- [ ] **Step 3: Keep runtime data unchanged**

Leave these values as raw data:

```swift
Text(r.provider)
Text(r.projectName)
Text(r.models)
Text(message.role.capitalized)
Text(model)
Text(text)
```

- [ ] **Step 4: Run residual-English audit**

Run:

```bash
rg -n '"[^"]*[A-Za-z][^"]*"' Sources/TokenScopeApp/Views Sources/TokenScopeApp/Stores Sources/TokenScopeCore/Providers
```

Expected residual English categories only:

- system image names, key paths, URLs, domains, CLI names, environment keys, provider display names, model names, raw parse keys, format strings, `API Key`, `USD`, `$`, `TokenScope`, and intentionally preserved technical units.
- No remaining hard-coded English navigation labels, button labels, table headers, empty states, or user-facing error text.

- [ ] **Step 5: Commit dashboard/session group**

```bash
git add Sources/TokenScopeApp/Views/DashboardView.swift Sources/TokenScopeApp/Views/SessionsView.swift Sources/TokenScopeApp/Views/SessionDetailView.swift Sources/TokenScopeApp/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat: localize dashboard and session views"
```

## Task 5: Localize User-Facing Errors

**Files:**
- Modify: `Sources/TokenScopeApp/Stores/AppStore.swift`
- Modify: `Sources/TokenScopeApp/Stores/CodexAccountLoginController.swift`
- Modify: `Sources/TokenScopeCore/Providers/CodexOAuthSupport.swift`
- Modify: `Sources/TokenScopeCore/Providers/ZaiUsageProvider.swift`
- Modify: `Sources/TokenScopeCore/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Localize app-store fallback errors**

Use `L10n.string` for app-only notices:

```swift
notice: L10n.string("Failed to load detailed session records.")
```

For `NSError` descriptions:

```swift
throw NSError(
    domain: "TokenScope",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: L10n.string("Usage is unavailable for this provider.")]
)
```

- [ ] **Step 2: Localize core provider errors**

Use `CoreL10n.string` for `LocalizedError.errorDescription` values:

```swift
return CoreL10n.string("Codex auth.json not found. Please sign in first.")
return CoreL10n.string("Refresh token expired. Please sign in again.")
return CoreL10n.string("Invalid z.ai API credentials.")
```

For messages with details:

```swift
return CoreL10n.string("Failed to decode Codex credentials: %@", message)
return CoreL10n.string("Network error: %@", error.localizedDescription)
return CoreL10n.string("z.ai API error: %@", message)
```

- [ ] **Step 3: Preserve raw diagnostic payloads**

Keep HTTP status codes, API error codes, command names, filenames, and original server messages in interpolated portions:

```swift
return CoreL10n.string("Codex API error %d: %@", code, message)
return CoreL10n.string("z.ai API error: %@", message)
return CoreL10n.string("Failed to start `codex login`: %@", message)
```

- [ ] **Step 4: Run localization gate**

```bash
python3 Scripts/check_zh_hans_localization.py
```

Expected: pass.

- [ ] **Step 5: Commit errors**

```bash
git add Sources/TokenScopeApp/Stores Sources/TokenScopeCore/Providers Sources/TokenScopeCore/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat: localize user-facing errors"
```

## Task 6: Ensure Packaged App Includes Localizations

**Files:**
- Modify: `Scripts/package_app.sh`

- [ ] **Step 1: Copy SwiftPM resource bundles into the app bundle**

After copying the executable, add:

```bash
RESOURCE_DIR="$(dirname "$BUILT_BIN")"
for RESOURCE_BUNDLE in "$RESOURCE_DIR"/TokenScope_*.bundle; do
    if [ -d "$RESOURCE_BUNDLE" ]; then
        cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
    fi
done
```

- [ ] **Step 2: Add localizations to `Info.plist`**

Inside the generated plist `<dict>`, add:

```xml
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
```

- [ ] **Step 3: Build package app**

Run:

```bash
CONFIG=release Scripts/package_app.sh
```

Expected:

- `TokenScope.app` exists.
- `TokenScope.app/Contents/Resources/TokenScope_TokenScopeApp.bundle` exists.
- `TokenScope.app/Contents/Resources/TokenScope_TokenScopeCore.bundle` exists.
- `TokenScope.app/Contents/Resources/TokenScope_TokenScopeApp.bundle/zh-Hans.lproj/Localizable.strings` exists.
- `TokenScope.app/Contents/Resources/TokenScope_TokenScopeCore.bundle/zh-Hans.lproj/Localizable.strings` exists.

- [ ] **Step 4: Commit packaging**

```bash
git add Scripts/package_app.sh
git commit -m "build: package localization resources"
```

## Task 7: Verification And Manual QA

**Files:**
- Read only unless verification reveals defects.

- [ ] **Step 1: Run static localization check**

```bash
python3 Scripts/check_zh_hans_localization.py
```

Expected: `zh-Hans localization check passed`.

- [ ] **Step 2: Run Swift build**

```bash
swift build
```

Expected: exit code `0`.

Note: On the current machine, `swift test --list-tests` previously failed because XCTest could not be located by the installed command line tools. If this persists, fix the local Xcode selection before running XCTest:

```bash
xcode-select -p
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift test
```

- [ ] **Step 3: Run package script**

```bash
CONFIG=release Scripts/package_app.sh
```

Expected: exit code `0` and a signed `TokenScope.app`.

- [ ] **Step 4: Open the app for manual QA**

```bash
open TokenScope.app
```

Check these screens:

- Sidebar shows `仪表盘`, `用量`, `会话`, `价格`, `备份`, `设置`.
- Dashboard cards, quick date menu, toggles, heatmap, and monthly section are Chinese.
- Sessions table headers, search field, loading overlay, and detail modal are Chinese.
- Usage empty states and refresh controls are Chinese.
- Pricing table headers, add/edit sheet, and context menu are Chinese.
- Settings sections/statuses are Chinese while `z.ai API Key`, provider names, paths, and account emails remain unchanged.
- Errors from missing z.ai key and missing Codex credentials display Chinese text while preserving `z.ai`, `Codex`, filenames, and raw diagnostic details.

- [ ] **Step 5: Final residual-English audit**

```bash
rg -n '"[^"]*[A-Za-z][^"]*"' Sources/TokenScopeApp Sources/TokenScopeCore | tee /tmp/tokenscope-residual-english.txt
```

Expected: every remaining English string is a technical identifier, path, domain, format string, provider/model name, raw parser key, or fallback English localization key.

- [ ] **Step 6: Final commit if manual QA required fixes**

```bash
git status --short
git add Package.swift Scripts Sources Tests
git commit -m "fix: complete zh-Hans localization QA"
```

Skip this commit if `git status --short` is clean.

## Self-Review

- Spec coverage: navigation, buttons, table headers, settings, empty states, and user-facing errors are covered by Tasks 3, 4, and 5.
- Technical-term preservation: explicitly covered by Scope Rules, Task 3 Step 3, Task 4 Step 3, and Task 5 Step 3.
- Packaging: covered by Task 6 so the `.app` zip contains SwiftPM resource bundles.
- Testing: covered by a failing-first static localization gate, build, package script, manual QA, and residual-English audit.
- Known environment risk: XCTest is currently unavailable because local command line tools cannot resolve XCTest paths; Task 7 records the remediation and does not rely on XCTest as the only gate.
