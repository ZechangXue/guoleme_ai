import SwiftUI

struct TranslateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("翻译总结") {
                    Task { await model.summarizeTranslate(withReply: false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(model.translateSummarizing)

                Button("总结回应") {
                    Task { await model.summarizeTranslate(withReply: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.teal)
                .disabled(model.translateSummarizing)
            }

            if model.listening {
                Text("正在监听…点击按钮生成当前段落总结")
                    .font(.caption)
                    .foregroundStyle(AppTheme.success)
            }

            if model.translateEntries.isEmpty {
                Text("点击「开始监听」后，可生成当前段落总结或回应")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ForEach(model.translateEntries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.timestamp)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                            Rectangle().fill(AppTheme.border).frame(height: 1)
                        }
                        Text(entry.text + (entry.streaming ? "▍" : ""))
                            .font(.body)
                            .foregroundStyle(AppTheme.text)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(14)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
