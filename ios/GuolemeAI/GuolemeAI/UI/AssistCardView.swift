import SwiftUI

struct AssistCardView: View {
    let assist: AssistJSON
    var streaming: Bool
    var meetingMode: Bool
    var displayAsReadable: Bool
    var readableLoading: Bool
    var onClose: () -> Void
    var onReadable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(assist.questionZh?.nilIfEmpty ?? "生成中…")
                    .font(.headline)
                    .foregroundStyle(AppTheme.text)
                Spacer()
                if !meetingMode && assist.expandedAnswerEn == nil {
                    Button(readableLoading ? "…" : "可读答案") { onReadable() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(readableLoading || assist.questionZh == nil)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                        .padding(8)
                }
            }

            section(title: meetingMode ? "简答" : "CONCISE · 一句回答", body: assist.conciseAnswerEn, italic: true, showCursor: streaming && assist.expandedAnswerEn == nil)
            if meetingMode || displayAsReadable || assist.expandedAnswerEn != nil {
                section(title: meetingMode ? "详解" : "EXPANDED · 展开回答", body: assist.expandedAnswerEn, italic: false, showCursor: streaming)
            } else if !assist.keywordsEn.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KEYWORDS · 英文关键词")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    FlowKeywords(words: assist.keywordsEn)
                }
            }
        }
        .padding(16)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func section(title: String, body: String?, italic: Bool, showCursor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            HStack(alignment: .bottom, spacing: 2) {
                if let body, !body.isEmpty {
                    Text(body)
                        .italic(italic)
                        .foregroundStyle(italic ? AppTheme.concise : AppTheme.text)
                        .lineSpacing(4)
                } else {
                    Text("生成中…")
                        .foregroundStyle(AppTheme.muted)
                }
                if showCursor {
                    Capsule()
                        .fill(AppTheme.success)
                        .frame(width: 2, height: 14)
                        .opacity(0.9)
                }
            }
        }
    }
}

private struct FlowKeywords: View {
    let words: [String]
    var body: some View {
        FlexibleWrap(words) { word in
            Text(word)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.accent.opacity(0.18))
                .clipShape(Capsule())
        }
    }
}

private struct FlexibleWrap<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.self) { item in
                    content(item)
                        .padding(4)
                        .alignmentGuide(.leading) { d in
                            if abs(width - d.width) > geo.size.width {
                                width = 0
                                height -= d.height
                            }
                            let result = width
                            if item == items.last { width = 0 } else { width -= d.width }
                            return result
                        }
                        .alignmentGuide(.top) { _ in
                            let result = height
                            if item == items.last { height = 0 }
                            return result
                        }
                }
            }
        }
        .frame(minHeight: 36)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
