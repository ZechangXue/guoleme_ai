# 过了么AI iOS（伴机版）

没有 Mac 时：把仓库推到 GitHub，用 Actions 打 IPA，再用 Sideloadly 装到自己手机。步骤见仓库根目录 [IOS-TEST.md](../IOS-TEST.md)。

SwiftUI 原生 App，与仓库里的 Windows Electron 桌面端共存。iPhone 用麦克风听电脑外放，提词只显示在手机上。

## 打开工程

必须在 **Mac + Xcode 16+** 上操作（Windows 无法编译 iOS）：

```bash
open ios/GuolemeAI/GuolemeAI.xcodeproj
```

1. Signing & Capabilities → 选择你的 Team（Apple Developer）
2. Bundle ID：`com.interviewteleprompter.guoleme`（若被占用可改，同时改 Live Activity 为 `….LiveActivity`）
3. 真机或模拟器运行（麦克风请用真机）

## 功能

- **会议助手**（与桌面 v3.0.0 同一思路，组会模式和翻译总结模式共用）：
  - 提词页「会议准备」：会议场景（周组会 / 新项目探讨 / 合作方会谈 / 我是面试官）、弹卡方式与点名关键词、个人画像（可从资料库生成草稿）、本周进展 → 汇报稿与可能追问、会议记忆
  - 会中逐段 Whisper 转写，被点到时弹出第一人称答题卡（开口一句、要点、可直接说的回答、依据、风险提醒），也可点「回答刚才的问题」
  - 「中→英」：中文想法变成可以说出口的英文
  - 结束会议后自动提炼「被问到什么、怎么答的、答应了什么」，下次会议作为上下文
- OpenAI Realtime 一体音频直通（面试模式默认）
- Whisper + Chat Completions 备用路径
- OpenAI / Gemini / DeepSeek / 千问
- 粘贴或导入 PDF / TXT / DOCX 作为 JD、简历、会议文档
- 翻译总结 / 总结回应
- 相册或相机看题
- 会话 PDF 导出
- Dynamic Island / Live Activity 显示「监听中」

Prompt 与桌面端共用 [`shared/prompts/`](../../shared/prompts/)，构建时拷进 App Bundle。

## 上架

见 [docs/AppStore-Review.md](../docs/AppStore-Review.md)。隐私政策页面在 [`ai-interview/privacy.html`](../../ai-interview/privacy.html)。
