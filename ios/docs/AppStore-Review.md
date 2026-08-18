# App Store 审核说明与上架清单

## 产品怎么写（不要写作弊）

- **名称**：过了么AI
- **副标题**：Meeting Prompt Companion
- **类别**：Productivity
- **一句话**：把 iPhone 当第二块屏幕，用麦克风听取电脑外放的会议声音，在本 App 内生成可朗读提词。
- **关键词示例**：meeting, prompt, teleprompter, transcription, bilingual, notes

## 审核备注（Review Notes，粘贴到 App Store Connect）

This app is a companion device. Meetings or interviews run on a computer. The iPhone microphone listens to loudspeaker audio in the room and shows live prompts only inside this app.

- We do not capture other apps’ internal audio.
- We do not overlay other apps.
- The user pastes their own API key (OpenAI / Gemini / DeepSeek / Qwen). API usage is billed by that provider, not through In-App Purchase.
- Microphone, camera, and photo library are used only for in-app prompting.
- Uploaded resumes/JDs stay on device.

## 隐私问卷

- Microphone：App Functionality，不用于追踪
- User Content（简历/JD/笔记）：App Functionality，不用于追踪
- 不使用 ATT / 广告标识符

## Archive 步骤

1. 加入 [Apple Developer Program](https://developer.apple.com/programs/)（$99/年）
2. Xcode 选择 Any iOS Device → Product → Archive
3. Organizer → Distribute App → App Store Connect
4. 在 App Store Connect 填写隐私政策 URL（部署 `ai-interview/privacy.html` 后的公开地址）
5. 上传截图：只拍本 App 的提词界面 +「手机靠近电脑扬声器」示意，不要出现 Zoom/Teams 叠层作弊画面

## 截图建议（6.7" iPhone）

1. 提词卡（一句回答 + 展开）
2. 空态引导（靠近扬声器）
3. 资料库（JD/简历）
4. 翻译总结
5. 设置（服务商与 Key，可打码）
