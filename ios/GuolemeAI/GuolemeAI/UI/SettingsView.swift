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
                Section {
                    Picker(model.t(.uiLanguage), selection: uiLanguageBinding) {
                        ForEach(UILanguage.allCases) { lang in
                            Text(lang.pickerLabel).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(model.t(.uiLanguageHint))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(model.t(.uiLanguage))
                }

                Section {
                    Picker(model.t(.answerLanguagePicker), selection: languageBinding) {
                        ForEach(AnswerLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(model.t(.answerLanguage))
                }

                Section {
                    Toggle(model.t(.meetingToggle), isOn: meetingBinding)
                    Toggle(model.t(.translateToggle), isOn: translateBinding)
                    Toggle(model.t(.autoDismiss), isOn: autoDismissBinding)
                    Toggle(model.t(.realtimeToggle), isOn: realtimeBinding)
                        .disabled(model.settings.apiProvider != .openai)
                } header: {
                    Text(model.t(.sectionMode))
                }

                Section {
                    Picker(model.t(.apiPicker), selection: providerBinding) {
                        ForEach(ApiProvider.allCases) { p in
                            Text(p.displayName(for: model.settings.uiLanguage)).tag(p)
                        }
                    }
                    TextField(model.t(.model), text: modelBinding)
                    SecureField(model.t(.apiKey), text: $apiKeyInput)
                    HStack {
                        Button(model.t(.saveKey)) { saveKey() }
                        Button(testing ? model.t(.testing) : model.t(.testConnection)) {
                            Task { await test() }
                        }
                        .disabled(testing)
                    }
                    if model.hasApiKey {
                        Text(model.t(.keySaved, model.settings.apiProvider.displayName(for: model.settings.uiLanguage)))
                            .foregroundStyle(AppTheme.success)
                    }
                    if let testMessage {
                        Text(testMessage).font(.footnote)
                    }
                    Button(model.t(.clearKey), role: .destructive) {
                        KeychainStore.delete(provider: model.settings.apiProvider)
                        model.refreshKeyStatus()
                    }
                } header: {
                    Text(model.t(.sectionProvider))
                }

                Section {
                    Picker(model.t(.stylePicker), selection: styleBinding) {
                        Text(model.t(.styleConcise)).tag(ResponseStyle.concise)
                        Text(model.t(.styleReadable)).tag(ResponseStyle.readable)
                    }
                } header: {
                    Text(model.t(.sectionStyle))
                }

                Section {
                    Button(model.exportBusy ? model.t(.exporting) : model.t(.exportPDF)) {
                        Task {
                            if let url = await model.exportSession() {
                                exportURL = url
                                showShare = true
                            }
                        }
                    }
                    .disabled(model.exportBusy || model.sessionLog.entries.isEmpty)
                    Button(model.t(.clearSession), role: .destructive) {
                        model.sessionLog.clear()
                    }
                } header: {
                    Text(model.t(.sectionExport))
                }

                Section {
                    Text(model.t(.aboutBody))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(model.t(.privacy), destination: URL(string: "https://zechangxue.github.io/ai_interview/privacy.html")!)
                } header: {
                    Text(model.t(.sectionAbout))
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.bg)
            .navigationTitle(model.t(.settingsTitle))
            .sheet(isPresented: $showShare) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
        }
    }

    private var uiLanguageBinding: Binding<UILanguage> {
        Binding(get: { model.settings.uiLanguage }, set: { value in
            model.settingsStore.update { $0.uiLanguage = value }
        })
    }
    private var languageBinding: Binding<AnswerLanguage> {
        Binding(get: { model.settings.answerLanguage }, set: { value in
            model.settingsStore.update { $0.answerLanguage = value }
        })
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
        Binding(get: { model.settings.autoDismissCardOnNewQuestion }, set: { value in
            model.settingsStore.update { $0.autoDismissCardOnNewQuestion = value }
        })
    }
    private var realtimeBinding: Binding<Bool> {
        Binding(get: { model.settings.useRealtimeAllInOne }, set: { value in
            model.settingsStore.update { $0.useRealtimeAllInOne = value }
        })
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
        Binding(get: { model.settings.model }, set: { value in
            model.settingsStore.update { $0.model = value }
        })
    }
    private var styleBinding: Binding<ResponseStyle> {
        Binding(get: { model.settings.responseStyle }, set: { value in
            model.settingsStore.update { $0.responseStyle = value }
        })
    }

    private func saveKey() {
        let value = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try? KeychainStore.save(provider: model.settings.apiProvider, key: value)
        apiKeyInput = ""
        model.refreshKeyStatus()
        testMessage = model.t(.keySavedShort)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let key = KeychainStore.load(provider: model.settings.apiProvider) else {
            testMessage = model.t(.keyMissing)
            return
        }
        do {
            try await LLMClient().testConnection(provider: model.settings.apiProvider, apiKey: key, model: model.settings.model)
            testMessage = model.t(.connectOK)
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
