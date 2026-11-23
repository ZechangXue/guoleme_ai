import SwiftUI
import UIKit

// MARK: - Live section (meeting mode and translate mode)

/// Answer card (when one is showing) plus meeting controls.
struct MeetingLiveSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meeting: MeetingAssistant
    @ObservedObject var profile: MeetingProfileStore
    @Binding var showPrep: Bool
    @Binding var showQuickEn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let card = meeting.visibleCard {
                MeetingCardView(meeting: meeting, card: card)
            }
            controls
            if !model.settings.translateMode, let script = profile.state.prep?.updateScript, !script.isEmpty {
                UpdateScriptStrip(script: script)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                MeetingTag(text: model.settings.meetingScene.label(model.settings.uiLanguage), color: AppTheme.accent)
                MeetingTag(text: model.settings.meetingTrigger.label(model.settings.uiLanguage), color: AppTheme.muted)
                Spacer()
                Button {
                    showPrep = true
                } label: {
                    Label(model.tr("会议准备", "Prep"), systemImage: "target")
                }
                .font(.footnote)
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await meeting.answerNow() }
                } label: {
                    Label(model.tr("回答刚才的问题", "Answer that"), systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(meeting.generating)

                Button {
                    showQuickEn = true
                } label: {
                    Label(model.tr("中→英", "Say it"), systemImage: "character.bubble")
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))

            HStack {
                if meeting.generating {
                    ProgressView().controlSize(.small)
                    Text(model.tr("正在生成答题卡…", "Writing a card…"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                } else if meeting.visibleCard == nil && !meeting.cards.isEmpty {
                    Button(model.tr("看上一张卡", "Show last card")) { meeting.showLatestCard() }
                        .font(.caption)
                }
                Spacer()
                Button(model.tr("结束会议", "End meeting"), role: .destructive) {
                    model.endMeeting()
                }
                .font(.caption)
                .disabled(meeting.transcript.isEmpty && meeting.cards.isEmpty && profile.activeSession == nil)
            }

            if let error = meeting.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .onTapGesture { meeting.errorMessage = nil }
            } else if !model.listening && meeting.transcript.isEmpty && meeting.cards.isEmpty {
                Text(model.tr(
                    "开会前先在「会议准备」里填好画像和本周进展。被点到时会自动弹卡，也可以随时点「回答刚才的问题」。转写需要 OpenAI Key。",
                    "Before the meeting, fill in your profile and this week's notes under Prep. A card pops when you're addressed, or tap \"Answer that\" anytime. Transcription needs an OpenAI key."
                ))
                .font(.footnote)
                .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(14)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MeetingTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18))
            .foregroundStyle(color == AppTheme.muted ? AppTheme.text : color)
            .clipShape(Capsule())
    }
}

private struct UpdateScriptStrip: View {
    @EnvironmentObject private var model: AppModel
    let script: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(script)
                .font(.callout)
                .foregroundStyle(AppTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label(model.tr("我的汇报稿", "My update"), systemImage: "text.alignleft")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Answer card

struct MeetingCardView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meeting: MeetingAssistant
    let card: MeetingCard
    @State private var showExpanded = false

    private var interviewer: Bool { model.settings.meetingScene == .interviewer }
    private var index: Int { meeting.cards.firstIndex { $0.id == card.id } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(card.questionZh.isEmpty ? model.tr("生成中…", "Generating…") : card.questionZh)
                .font(.headline)
                .foregroundStyle(AppTheme.text)
                .textSelection(.enabled)

            if !card.opener.isEmpty {
                block(interviewer ? model.tr("下一个追问", "Ask next") : model.tr("开口一句", "Open with")) {
                    Text(card.opener)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.concise)
                        .textSelection(.enabled)
                }
            }

            if !card.points.isEmpty {
                block(interviewer ? model.tr("追问 / 留意", "Probe for") : model.tr("要点", "Points")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(card.points.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(AppTheme.accent)
                                Text(point).foregroundStyle(AppTheme.text)
                            }
                            .font(.body)
                        }
                    }
                }
            }

            if !card.concise.isEmpty {
                block(interviewer ? model.tr("我的评估（不要说出口）", "My assessment (private)") : model.tr("可以直接说", "Say this")) {
                    Text(card.concise)
                        .font(.body)
                        .foregroundStyle(AppTheme.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }

            if !card.expanded.isEmpty {
                DisclosureGroup(isExpanded: $showExpanded) {
                    Text(card.expanded)
                        .font(.callout)
                        .foregroundStyle(AppTheme.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text(interviewer ? model.tr("更多追问", "More follow-ups") : model.tr("展开回答", "Longer answer"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
            }

            if !card.done && card.error == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.tr("生成中…", "Generating…"))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
            }

            if !card.source.isEmpty || !card.caution.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !card.caution.isEmpty {
                        Label(card.caution, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !card.source.isEmpty {
                        Text(model.tr("依据：", "Source: ") + card.source)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }
                }
                .padding(.top, 2)
            }

            if let error = card.error {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer()
                    Button(model.tr("重试", "Retry")) { meeting.retry(cardId: card.id) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.accent.opacity(0.6), lineWidth: 1)
        )
        .onChange(of: card.id) { _, _ in showExpanded = false }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !card.qType.isEmpty && !interviewer {
                MeetingTag(text: qTypeLabel(card.qType), color: AppTheme.accent)
            }
            MeetingTag(text: triggerLabel(card.trigger), color: AppTheme.muted)
            Spacer()
            if meeting.cards.count > 1 {
                Button { meeting.showPreviousCard() } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Text("\(index + 1)/\(meeting.cards.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.muted)
                Button { meeting.showNextCard() } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= meeting.cards.count - 1)
            }
            Button { meeting.closeCard() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                    .padding(6)
            }
        }
        .font(.footnote)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            content()
        }
    }

    private func qTypeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "progress": return model.tr("进展", "Progress")
        case "reasoning": return model.tr("思路", "Reasoning")
        case "detail": return model.tr("细节", "Detail")
        case "challenge": return model.tr("质疑", "Challenge")
        case "opinion": return model.tr("看法", "Opinion")
        default: return model.tr("其他", "Other")
        }
    }

    private func triggerLabel(_ trigger: MeetingTriggerKind) -> String {
        switch trigger {
        case .auto: return model.tr("检测到问题", "Question")
        case .mention: return model.tr("点到我", "Addressed")
        case .manual: return model.tr("手动", "Manual")
        case .screenshot: return model.tr("截图", "Screenshot")
        }
    }
}

// MARK: - Live transcript

struct MeetingTranscriptView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meeting: MeetingAssistant
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if meeting.transcript.isEmpty {
                Text(model.listening ? model.tr("正在听…", "Listening…") : model.tr("开始监听后显示对方的发言", "Speech appears here once you start listening"))
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(meeting.transcript.suffix(40).reversed()) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.clock.string(from: Date(timeIntervalSince1970: line.at)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.muted)
                            Text(line.text)
                                .font(.callout)
                                .foregroundStyle(AppTheme.text)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text(model.tr("实时转写（\(meeting.transcript.count)）", "Live transcript (\(meeting.transcript.count))"))
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Quick Chinese → spoken English

struct QuickEnSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meeting: MeetingAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var results: [QuickResult] = []

    struct QuickResult: Identifiable {
        let id = UUID()
        let input: String
        let say: String
        let shorter: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(model.tr("用中文写你想说的…", "Type your thought (any language)…"), text: $input, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(busy ? model.tr("生成中…", "Working…") : model.tr("变成可以说出口的话", "Make it speakable"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }

                    ForEach(results) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.input)
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                            Text(r.say)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(AppTheme.concise)
                                .textSelection(.enabled)
                            if !r.shorter.isEmpty {
                                Text(r.shorter)
                                    .font(.callout)
                                    .foregroundStyle(AppTheme.text)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(AppTheme.bg)
            .navigationTitle(model.tr("中 → 英口语", "Say it in English"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.tr("完成", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let r = try await meeting.quickTranslate(text)
            results.insert(QuickResult(input: text, say: r.say, shorter: r.shorter), at: 0)
            if results.count > 4 { results.removeLast() }
            input = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Prep sheet: scene & trigger, profile, this week, memory

struct MeetingPrepSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meeting: MeetingAssistant
    @ObservedObject var profile: MeetingProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var personaDraft = ""
    @State private var notesDraft = ""
    @State private var message: String?
    @State private var loaded = false
    @State private var confirmClearMemory = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $tab) {
                        Text(model.tr("场景", "Scene")).tag(0)
                        Text(model.tr("画像", "Profile")).tag(1)
                        Text(model.tr("本周", "This week")).tag(2)
                        Text(model.tr("记忆", "Memory")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if let message {
                    Section {
                        Text(message).font(.footnote)
                    }
                }

                switch tab {
                case 0: sceneSections
                case 1: personaSections
                case 2: weekSections
                default: memorySections
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.bg)
            .navigationTitle(model.tr("会议准备", "Meeting prep"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.tr("完成", "Done")) {
                        saveDrafts()
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                personaDraft = profile.state.personaText
                notesDraft = profile.state.weeklyNotes
                loaded = true
            }
            .onChange(of: tab) { _, _ in
                saveDrafts()
                message = nil
            }
            .alert(model.tr("清空全部会议记忆？", "Clear all meeting memory?"), isPresented: $confirmClearMemory) {
                Button(model.tr("清空", "Clear"), role: .destructive) { profile.clearSessions() }
                Button(model.tr("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(model.tr("删除后无法恢复。", "This cannot be undone."))
            }
        }
    }

    private func saveDrafts() {
        if personaDraft != profile.state.personaText { profile.setPersona(personaDraft) }
        if notesDraft != profile.state.weeklyNotes { profile.setWeeklyNotes(notesDraft) }
        profile.flush()
    }

    // Scene & trigger

    @ViewBuilder
    private var sceneSections: some View {
        Section {
            Picker(model.tr("会议场景", "Scene"), selection: sceneBinding) {
                ForEach(MeetingScene.allCases) { scene in
                    Text(scene.label(model.settings.uiLanguage)).tag(scene)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(model.tr("会议场景", "Meeting type"))
        } footer: {
            Text(model.tr(
                "合作方会谈会自动注意保密边界；「我是面试官」会改为给追问建议和评估。",
                "Partner meetings add confidentiality guard rails. \"I'm the interviewer\" switches cards to follow-up questions and assessment."
            ))
        }

        Section {
            Picker(model.tr("弹卡方式", "Pop cards"), selection: triggerBinding) {
                ForEach(MeetingTrigger.allCases) { trigger in
                    Text(trigger.label(model.settings.uiLanguage)).tag(trigger)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Text(model.settings.meetingTrigger.hint(model.settings.uiLanguage))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(model.tr("什么时候弹卡", "When to pop a card"))
        }

        Section {
            TextField(model.tr("例如：Zechang, Zach, 泽昌", "e.g. Zechang, Zach"), text: keywordsBinding, axis: .vertical)
                .lineLimit(1...3)
        } header: {
            Text(model.tr("点名关键词", "Name keywords"))
        } footer: {
            Text(model.tr(
                "你的名字和转写里常见的误拼，用逗号分隔。也会作为转写提示，提高人名识别率。",
                "Your name and common mis-transcriptions, comma-separated. Also used as a transcription hint."
            ))
        }
    }

    // Profile

    @ViewBuilder
    private var personaSections: some View {
        Section {
            TextEditor(text: $personaDraft)
                .font(.footnote)
                .frame(minHeight: 280)
            HStack {
                Button(model.tr("保存", "Save")) {
                    profile.setPersona(personaDraft)
                    profile.flush()
                    message = model.tr("画像已保存", "Profile saved")
                }
                .disabled(personaDraft == profile.state.personaText)
                Spacer()
                Button(meeting.personaBusy ? model.tr("生成中…", "Drafting…") : model.tr("从资料库生成草稿", "Draft from library")) {
                    Task { await draftPersona() }
                }
                .disabled(meeting.personaBusy)
            }
            .buttonStyle(.borderless)
        } header: {
            Text(model.tr("我的画像（\(personaDraft.count) 字）", "My profile (\(personaDraft.count) chars)"))
        } footer: {
            Text(model.tr(
                "写清角色、产品、架构与关键数字、同事分工、沟通风格。答题卡会以你的身份、第一人称作答；画像里没有的数字不会编。",
                "Role, products, architecture and key numbers, who does what, how you communicate. Cards answer as you, in the first person, and won't invent numbers."
            ))
        }
    }

    private func draftPersona() async {
        message = nil
        do {
            let draft = try await meeting.draftPersona()
            if !draft.isEmpty {
                personaDraft = draft
                message = model.tr("草稿已生成，检查修改后点「保存」", "Draft ready — review it, then tap Save")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // This week

    @ViewBuilder
    private var weekSections: some View {
        Section {
            TextEditor(text: $notesDraft)
                .font(.footnote)
                .frame(minHeight: 160)
            HStack {
                Button(model.tr("保存", "Save")) {
                    profile.setWeeklyNotes(notesDraft)
                    profile.flush()
                    message = model.tr("已保存", "Saved")
                }
                .disabled(notesDraft == profile.state.weeklyNotes)
                Spacer()
                Button(meeting.prepBusy ? model.tr("生成中…", "Preparing…") : model.tr("生成汇报稿和可能追问", "Prepare update & Q&A")) {
                    Task { await generatePrep() }
                }
                .disabled(meeting.prepBusy || notesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.borderless)
        } header: {
            Text(model.tr("本周进展（中文几条就行）", "This week (a few notes, any language)"))
        } footer: {
            Text(model.tr("被问到进展时，答题卡优先用这里的内容。", "Progress questions are answered from these notes first."))
        }

        if let prep = profile.state.prep {
            if !prep.updateScript.isEmpty {
                Section {
                    Text(prep.updateScript)
                        .font(.callout)
                        .textSelection(.enabled)
                } header: {
                    Text(model.tr("汇报稿", "Spoken update"))
                }
            }
            if !prep.likelyQuestions.isEmpty {
                Section {
                    ForEach(prep.likelyQuestions) { q in
                        DisclosureGroup {
                            Text(q.answerEn)
                                .font(.callout)
                                .textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.questionEn).font(.subheadline.weight(.semibold))
                                if let zh = q.questionZh {
                                    Text(zh).font(.caption).foregroundStyle(.secondary)
                                }
                                if let asker = q.asker {
                                    Text(asker).font(.caption2).foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text(model.tr("可能被追问", "Likely questions"))
                }
            }
            if !prep.decisionsNeeded.isEmpty {
                Section {
                    ForEach(prep.decisionsNeeded, id: \.self) { d in
                        Text(d).font(.callout).textSelection(.enabled)
                    }
                } header: {
                    Text(model.tr("需要团队拍板", "Decisions to ask for"))
                }
            }
            Section {
                Button(model.tr("清除汇报稿", "Clear prepared update"), role: .destructive) {
                    profile.setPrep(nil)
                }
            } footer: {
                Text(model.tr("生成于 ", "Generated ") + MeetingPrompt.dateString(prep.generatedAt, withTime: true))
            }
        }
    }

    private func generatePrep() async {
        message = nil
        profile.setWeeklyNotes(notesDraft)
        do {
            try await meeting.generatePrep()
            message = model.tr("已生成，开会时答题卡也会参考这份汇报稿", "Ready — cards will use this update during the meeting")
        } catch {
            message = error.localizedDescription
        }
    }

    // Memory

    @ViewBuilder
    private var memorySections: some View {
        Section {
            if profile.state.sessions.isEmpty {
                Text(model.tr("还没有会议记录。结束会议后会自动提炼：被问到什么、怎么答的、答应了什么。", "No meetings yet. After a meeting ends, what you were asked, what you said and what you committed to is saved here."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.state.sessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(MeetingPrompt.dateString(session.startedAt, withTime: true))
                            .font(.subheadline.weight(.semibold))
                        Text(session.scene.label(model.settings.uiLanguage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if session.id == profile.state.activeSessionId {
                            Text(model.tr("进行中", "Live"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.success)
                        }
                    }
                    Text(model.tr("\(session.cards.count) 张卡 · \(session.transcript.count) 段转写", "\(session.cards.count) cards · \(session.transcript.count) lines"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let digest = session.digestZh, !digest.isEmpty {
                        Text(digest).font(.footnote)
                    } else if session.endedAt != nil {
                        Text(model.tr("（尚未提炼）", "(not digested yet)"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.commitments ?? [], id: \.self) { c in
                        Label(c, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.concise)
                    }
                }
                .swipeActions {
                    Button(model.tr("删除", "Delete"), role: .destructive) {
                        profile.deleteSession(id: session.id)
                    }
                }
            }
        } header: {
            Text(model.tr("会议记忆", "Meeting memory"))
        } footer: {
            Text(model.tr("最近 3 场的提炼会作为上下文带进下次会议。左滑删除。", "Digests of the last 3 meetings are used as context next time. Swipe to delete."))
        }

        if !profile.state.sessions.isEmpty {
            Section {
                Button(model.tr("提炼未处理的会议", "Digest pending meetings")) {
                    Task { await meeting.digestPendingSessions() }
                }
                .disabled(profile.undigestedEndedSessions().isEmpty)
                Button(model.tr("清空全部记忆", "Clear all memory"), role: .destructive) {
                    confirmClearMemory = true
                }
            }
        }
    }

    // Bindings

    private var sceneBinding: Binding<MeetingScene> {
        Binding(get: { model.settings.meetingScene }, set: { value in
            model.settingsStore.update { $0.meetingScene = value }
        })
    }

    private var triggerBinding: Binding<MeetingTrigger> {
        Binding(get: { model.settings.meetingTrigger }, set: { value in
            model.settingsStore.update { $0.meetingTrigger = value }
        })
    }

    private var keywordsBinding: Binding<String> {
        Binding(get: { model.settings.meetingTriggerKeywords }, set: { value in
            model.settingsStore.update { $0.meetingTriggerKeywords = value }
        })
    }
}
