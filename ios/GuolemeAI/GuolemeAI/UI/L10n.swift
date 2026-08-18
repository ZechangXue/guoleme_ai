import Foundation

enum UILanguage: String, Codable, CaseIterable, Identifiable {
    case zh
    case en
    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

enum L10n {
    enum Key: String {
        case appName
        case tabPrompter, tabLibrary, tabSettings
        case modeInterview, modeMeeting, modeTranslate
        case startListening, pauseListening
        case albumQA, captureScreen, recognizing
        case waitQuestion, waitMeetingQuestion
        case emptyHint
        case tipMic, tipVolume, tipLock
        case generating, notGenerated
        case concise, expanded, brief, detail, keywords
        case readableAnswer
        case libraryTitle, libraryHelp
        case pasteSection, importSection
        case pasteResume, pasteJD, pasteNotes, savePaste
        case pickFile, typeLabel, libraryEmpty, libraryCount
        case charsUnit, clearLibrary
        case settingsTitle
        case uiLanguage, uiLanguageHint
        case answerLanguage, answerLanguagePicker
        case sectionMode, meetingToggle, translateToggle, autoDismiss, realtimeToggle
        case sectionProvider, model, apiKey, saveKey, testConnection, testing
        case keySaved, keyMissing, connectOK, clearKey
        case sectionStyle, styleConcise, styleReadable
        case sectionExport, exportPDF, exporting, clearSession
        case sectionAbout, aboutBody, privacy
        case translateSummary, translateReply
        case translateListening, translateIdle
        case noSpeech, noOpenAIKey, noAPIKey, translateFail
        case needMic, needAPIKey
        case visionNeedKey, imageBad, recognizingStatus, imageUnclear, generatingCode, imageFail, albumFail
        case micFail, fallbackNeedOpenAI
        case contextEmpty, contextConnected
        case docResume, docJD, docNotes, docProject, docMeeting
        case onboardingTitle, onboardingSubtitle
        case chooseChinese, chooseEnglish
        case audioLevel
        case qwen
        case continueListening, recognizingQuestion, keySavedShort
        case libraryHelpTitle, stylePicker, apiPicker
        case liveHoldNearSpeaker, liveListening, livePaused
        case noSessionContent
        case pdfTitle, pdfSummary, pdfInterviewer, pdfQuestion, pdfConcise, pdfExpanded
    }

    static func t(_ key: Key, language: UILanguage) -> String {
        table[key]?[language] ?? table[key]?[.zh] ?? key.rawValue
    }

    private static let table: [Key: [UILanguage: String]] = [
        .appName: [.zh: "过了么AI", .en: "Guoleme AI"],
        .tabPrompter: [.zh: "提词", .en: "Prompter"],
        .tabLibrary: [.zh: "资料", .en: "Library"],
        .tabSettings: [.zh: "设置", .en: "Settings"],
        .modeInterview: [.zh: "面试提词", .en: "Interview"],
        .modeMeeting: [.zh: "会议模式", .en: "Meeting"],
        .modeTranslate: [.zh: "翻译总结", .en: "Translate & summary"],
        .startListening: [.zh: "开始监听", .en: "Start listening"],
        .pauseListening: [.zh: "暂停监听", .en: "Pause listening"],
        .albumQA: [.zh: "相册看题", .en: "Album"],
        .captureScreen: [.zh: "拍摄屏幕", .en: "Camera"],
        .recognizing: [.zh: "识图中…", .en: "Reading…"],
        .waitQuestion: [.zh: "等待捕捉下一条「对方提问」…", .en: "Waiting for the next question…"],
        .waitMeetingQuestion: [.zh: "会议模式：等待捕捉提问…", .en: "Meeting mode: waiting for a question…"],
        .emptyHint: [
            .zh: "把 iPhone 靠近电脑扬声器，开始监听后会在本机显示提词。不要覆盖其他 App，也不采集系统内部音频。",
            .en: "Place your iPhone near the computer speaker. Prompts appear in this app after you start listening. It does not capture other apps’ internal audio."
        ],
        .tipMic: [.zh: "手机麦克风对准电脑外放", .en: "Point the mic at the computer speaker"],
        .tipVolume: [.zh: "外放音量开大，减少环境噪音", .en: "Turn speaker volume up and reduce noise"],
        .tipLock: [.zh: "锁屏后仍可继续听（通知栏会显示监听中）", .en: "Listening continues with the screen locked"],
        .generating: [.zh: "生成中…", .en: "Generating…"],
        .notGenerated: [.zh: "（未生成）", .en: "(Not generated)"],
        .concise: [.zh: "CONCISE · 一句回答", .en: "CONCISE · One-line answer"],
        .expanded: [.zh: "EXPANDED · 展开回答", .en: "EXPANDED · Full answer"],
        .brief: [.zh: "简答", .en: "Brief"],
        .detail: [.zh: "详解", .en: "Detail"],
        .keywords: [.zh: "KEYWORDS · 英文关键词", .en: "KEYWORDS"],
        .readableAnswer: [.zh: "可读答案", .en: "Readable answer"],
        .libraryTitle: [.zh: "资料库", .en: "Library"],
        .libraryHelp: [
            .zh: "面试模式会用简历 / JD / 笔记来针对性作答。组会模式优先用「会议 / 项目文档」；如果还没传项目文档，会回退使用已入库的简历和笔记，避免空泛回答。资料只存在本机。",
            .en: "Interview mode uses resume / JD / notes. Meeting mode prefers project docs; if none are uploaded it falls back to resume and notes. Files stay on this device."
        ],
        .pasteSection: [.zh: "纯文本粘贴", .en: "Paste text"],
        .importSection: [.zh: "导入文件（PDF / TXT / DOCX）", .en: "Import files (PDF / TXT / DOCX)"],
        .pasteResume: [.zh: "简历 / CV", .en: "Resume / CV"],
        .pasteJD: [.zh: "职位描述 / JD", .en: "Job description / JD"],
        .pasteNotes: [.zh: "笔记", .en: "Notes"],
        .savePaste: [.zh: "保存粘贴内容到资料库", .en: "Save pasted text to library"],
        .pickFile: [.zh: "从文件 App 选择", .en: "Choose from Files"],
        .typeLabel: [.zh: "类型", .en: "Type"],
        .libraryEmpty: [.zh: "还没有文档", .en: "No documents yet"],
        .libraryCount: [.zh: "已入库 (%d)", .en: "In library (%d)"],
        .charsUnit: [.zh: "%d 字", .en: "%d chars"],
        .clearLibrary: [.zh: "清空资料库", .en: "Clear library"],
        .settingsTitle: [.zh: "设置", .en: "Settings"],
        .uiLanguage: [.zh: "界面语言", .en: "Interface language"],
        .uiLanguageHint: [.zh: "只改 App 界面文案，不影响「答案语言」。", .en: "Changes the app UI only. Answer language stays separate."],
        .answerLanguage: [.zh: "答案语言", .en: "Answer language"],
        .answerLanguagePicker: [.zh: "语言", .en: "Language"],
        .sectionMode: [.zh: "模式", .en: "Modes"],
        .meetingToggle: [.zh: "会议 / 项目介绍模式", .en: "Meeting / project mode"],
        .translateToggle: [.zh: "翻译总结模式", .en: "Translate & summary mode"],
        .autoDismiss: [.zh: "下一题自动切换卡片", .en: "Switch card on new question"],
        .realtimeToggle: [.zh: "OpenAI Realtime 一体（最低延迟）", .en: "OpenAI Realtime (lowest latency)"],
        .sectionProvider: [.zh: "服务商", .en: "Provider"],
        .model: [.zh: "模型", .en: "Model"],
        .apiKey: [.zh: "API Key", .en: "API Key"],
        .saveKey: [.zh: "保存 Key", .en: "Save key"],
        .testConnection: [.zh: "测试连接", .en: "Test connection"],
        .testing: [.zh: "测试中…", .en: "Testing…"],
        .keySaved: [.zh: "已保存 %@ Key", .en: "%@ key saved"],
        .keyMissing: [.zh: "尚未保存 Key", .en: "No key saved yet"],
        .connectOK: [.zh: "连接成功", .en: "Connected"],
        .clearKey: [.zh: "清除 Key", .en: "Delete key"],
        .sectionStyle: [.zh: "提词风格", .en: "Prompt style"],
        .styleConcise: [.zh: "极简一句", .en: "Concise"],
        .styleReadable: [.zh: "可读展开", .en: "Readable"],
        .sectionExport: [.zh: "导出", .en: "Export"],
        .exportPDF: [.zh: "导出本次会话 PDF", .en: "Export session PDF"],
        .exporting: [.zh: "导出中…", .en: "Exporting…"],
        .clearSession: [.zh: "清空本机会话实录", .en: "Clear session log"],
        .sectionAbout: [.zh: "关于", .en: "About"],
        .aboutBody: [
            .zh: "伴机模式：面试在电脑上进行，本 App 只用 iPhone 麦克风听外放声音，提词显示在手机上。不采集其他 App 音频，不覆盖第三方会议窗口。",
            .en: "Companion mode: the interview happens on a computer. This app only uses the iPhone mic to hear the speaker and shows prompts here. It does not capture other apps’ audio or overlay third-party meeting windows."
        ],
        .privacy: [.zh: "隐私政策", .en: "Privacy policy"],
        .translateSummary: [.zh: "翻译总结", .en: "Summarize"],
        .translateReply: [.zh: "总结回应", .en: "Summarize & reply"],
        .translateListening: [.zh: "正在监听…点击按钮生成当前段落总结", .en: "Listening… tap to summarize this segment"],
        .translateIdle: [.zh: "点击「开始监听」后，可生成当前段落总结或回应", .en: "Start listening, then generate a summary or reply"],
        .noSpeech: [.zh: "（未检测到有效语音）", .en: "(No valid speech detected)"],
        .noOpenAIKey: [.zh: "（未配置 OpenAI API Key，无法转写音频）", .en: "(OpenAI API key required for transcription)"],
        .noAPIKey: [.zh: "（未配置 API Key，无法翻译）", .en: "(API key required for translation)"],
        .translateFail: [.zh: "（翻译失败：%@）", .en: "(Translation failed: %@)"],
        .needMic: [.zh: "需要麦克风权限才能听电脑外放的声音", .en: "Microphone permission is required to hear the computer speaker"],
        .needAPIKey: [.zh: "请先在设置中保存 API Key", .en: "Save an API key in Settings first"],
        .visionNeedKey: [.zh: "识图需要 OpenAI 或 Gemini 的 API Key（当前服务商不支持看图）", .en: "Image QA needs an OpenAI or Gemini API key"],
        .imageBad: [.zh: "无法处理这张图片，请换一张或靠近屏幕重拍", .en: "Could not process this image. Try another photo or move closer."],
        .recognizingStatus: [.zh: "正在识图出题…", .en: "Reading the question…"],
        .imageUnclear: [.zh: "没看清题目，请靠近屏幕、对焦后再拍", .en: "Could not read the question. Move closer and refocus."],
        .generatingCode: [.zh: "正在生成完整代码…", .en: "Generating the full solution…"],
        .imageFail: [.zh: "识图失败：%@", .en: "Image QA failed: %@"],
        .albumFail: [.zh: "无法读取相册图片，请换一张再试", .en: "Could not read that photo. Try another one."],
        .micFail: [.zh: "无法启动麦克风：%@", .en: "Could not start the microphone: %@"],
        .fallbackNeedOpenAI: [.zh: "备用路径需要 OpenAI Key 做 Whisper 转写", .en: "Fallback listening needs an OpenAI key for Whisper"],
        .contextEmpty: [.zh: "资料库为空，回答会比较笼统", .en: "Library is empty — answers will be more generic"],
        .contextConnected: [.zh: "已接入：%@（%d 字）", .en: "Loaded: %@ (%d chars)"],
        .docResume: [.zh: "简历", .en: "Resume"],
        .docJD: [.zh: "JD", .en: "JD"],
        .docNotes: [.zh: "笔记", .en: "Notes"],
        .docProject: [.zh: "项目文档", .en: "Project docs"],
        .docMeeting: [.zh: "会议 / 项目文档", .en: "Meeting / project doc"],
        .onboardingTitle: [.zh: "选择界面语言", .en: "Choose interface language"],
        .onboardingSubtitle: [
            .zh: "这只影响 App 按钮和说明的显示语言。回答用中文还是英文，之后可在设置里单独选择。",
            .en: "This only changes the app UI. You can still pick Chinese or English answers later in Settings."
        ],
        .chooseChinese: [.zh: "中文", .en: "中文"],
        .chooseEnglish: [.zh: "English", .en: "English"],
        .audioLevel: [.zh: "音量", .en: "Volume"],
        .qwen: [.zh: "千问 (Qwen)", .en: "Qwen"],
        .continueListening: [.zh: "继续监听", .en: "Still listening"],
        .recognizingQuestion: [.zh: "正在识图…", .en: "Reading image…"],
        .keySavedShort: [.zh: "已保存", .en: "Saved"],
        .libraryHelpTitle: [.zh: "使用说明", .en: "How it works"],
        .stylePicker: [.zh: "风格", .en: "Style"],
        .apiPicker: [.zh: "API", .en: "API"],
        .liveHoldNearSpeaker: [.zh: "把手机靠近电脑扬声器", .en: "Hold the phone near the computer speaker"],
        .liveListening: [.zh: "监听中", .en: "Listening"],
        .livePaused: [.zh: "已暂停", .en: "Paused"],
        .noSessionContent: [.zh: "（无实录内容）", .en: "(No session notes)"],
        .pdfTitle: [.zh: "过了么AI · 会话复盘", .en: "Guoleme AI · Session recap"],
        .pdfSummary: [.zh: "中文总结", .en: "Summary"],
        .pdfInterviewer: [.zh: "面试官原话：%@", .en: "Interviewer: %@"],
        .pdfQuestion: [.zh: "题摘要：%@", .en: "Question: %@"],
        .pdfConcise: [.zh: "一句回答：%@", .en: "Concise: %@"],
        .pdfExpanded: [.zh: "展开：%@", .en: "Expanded: %@"]
    ]
}
