import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKeyInput = ""
    @State private var testMessage: String?
    @State private var testing = false
    @State private var exportURL: URL?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Form {
                Section("答案语言") {
                    Picker("语言", selection: languageBinding) {
                        ForEach(AnswerLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("模式") {
                    Toggle("会议 / 项目介绍模式", isOn: meetingBinding)
                    Toggle("翻译总结模式", isOn: translateBinding)
                    Toggle("下一题自动切换卡片", isOn: autoDismissBinding)
                    Toggle("OpenAI Realtime 一体（最低延迟）", isOn: realtimeBinding)
                        .disabled(model.settings.apiProvider != .openai)
                }
                Section("服务商") {
                    Picker("API", selection: providerBinding) {
                        ForEach(ApiProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    TextField("模型", text: modelBinding)
                    SecureField("API Key", text: $apiKeyInput)
                    HStack {
                        Button("保存 Key") { saveKey() }
                        Button(testing ? "测试中…" : "测试连接") {
                            Task { await test() }
                        }
                        .disabled(testing)
                    }
                    if model.hasApiKey {
                        Text("已保存 \(model.settings.apiProvider.displayName) Key")
                            .foregroundStyle(AppTheme.success)
                    }
                    if let testMessage {
                        Text(testMessage).font(.footnote)
                    }
                    Button("清除 Key", role: .destructive) {
                        KeychainStore.delete(provider: model.settings.apiProvider)
                        model.refreshKeyStatus()
                    }
                }
                Section("提词风格") {
                    Picker("风格", selection: styleBinding) {
                        Text("极简一句").tag(ResponseStyle.concise)
                        Text("可读展开").tag(ResponseStyle.readable)
                    }
                }
                Section("导出") {
                    Button(model.exportBusy ? "导出中…" : "导出本次会话 PDF") {
                        Task {
                            if let url = await model.exportSession() {
                                exportURL = url
                                showShare = true
                            }
                        }
                    }
                    .disabled(model.exportBusy || model.sessionLog.entries.isEmpty)
                    Button("清空本机会话实录", role: .destructive) {
                        model.sessionLog.clear()
                    }
                }
                Section("关于") {
                    Text("伴机模式：面试在电脑上进行，本 App 只用 iPhone 麦克风听外放声音，提词显示在手机上。不采集其他 App 音频，不覆盖第三方会议窗口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("隐私政策", destination: URL(string: "https://zechangxue.github.io/ai_interview/privacy.html")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.bg)
            .navigationTitle("设置")
            .sheet(isPresented: $showShare) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
        }
    }

    private var languageBinding: Binding<AnswerLanguage> {
        Binding(get: { model.settings.answerLanguage }, set: { model.settingsStore.update { $0.answerLanguage = $1 } })
    }
    private var meetingBinding: Binding<Bool> {
        Binding(get: { model.settings.meetingMode }, set: { value in
            model.settingsStore.update {
                $0.meetingMode = value
                if value { $0.translateMode = false }
            }
        })
    }
    private var translateBinding: Binding<Bool> {
        Binding(get: { model.settings.translateMode }, set: { value in
            model.settingsStore.update {
                $0.translateMode = value
                if value { $0.meetingMode = false }
            }
        })
    }
    private var autoDismissBinding: Binding<Bool> {
        Binding(get: { model.settings.autoDismissCardOnNewQuestion }, set: { model.settingsStore.update { $0.autoDismissCardOnNewQuestion = $1 } })
    }
    private var realtimeBinding: Binding<Bool> {
        Binding(get: { model.settings.useRealtimeAllInOne }, set: { model.settingsStore.update { $0.useRealtimeAllInOne = $1 } })
    }
    private var providerBinding: Binding<ApiProvider> {
        Binding(get: { model.settings.apiProvider }, set: { provider in
            model.settingsStore.update {
                $0.apiProvider = provider
                $0.model = ProviderConfig.defaultModel(for: provider)
                if provider != .openai { $0.useRealtimeAllInOne = false }
            }
            model.refreshKeyStatus()
        })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { model.settings.model }, set: { model.settingsStore.update { $0.model = $1 } })
    }
    private var styleBinding: Binding<ResponseStyle> {
        Binding(get: { model.settings.responseStyle }, set: { model.settingsStore.update { $0.responseStyle = $1 } })
    }

    private func saveKey() {
        let value = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try? KeychainStore.save(provider: model.settings.apiProvider, key: value)
        apiKeyInput = ""
        model.refreshKeyStatus()
        testMessage = "已保存"
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let key = KeychainStore.load(provider: model.settings.apiProvider) else {
            testMessage = "尚未保存 Key"
            return
        }
        do {
            try await LLMClient().testConnection(provider: model.settings.apiProvider, apiKey: key, model: model.settings.model)
            testMessage = "连接成功"
        } catch {
            testMessage = error.localizedDescription
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
