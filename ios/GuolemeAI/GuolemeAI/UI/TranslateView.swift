import SwiftUI

struct TranslateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(model.t(.translateSummary)) {
                    Task { await model.summarizeTranslate(withReply: false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(model.translateSummarizing)

                Button(model.t(.translateReply)) {
                    Task { await model.summarizeTranslate(withReply: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.teal)
                .disabled(model.translateSummarizing)
            }

            if model.listening {
                Text(model.t(.translateListening))
                    .font(.caption)
                    .foregroundStyle(AppTheme.success)
            }

            if model.translateEntries.isEmpty {
                Text(model.t(.translateIdle))
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
