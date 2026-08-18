import SwiftUI

enum AppTheme {
    static let bg = Color(red: 0.008, green: 0.024, blue: 0.090)
    static let elevated = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let border = Color(red: 0.58, green: 0.64, blue: 0.72).opacity(0.35)
    static let text = Color(red: 0.98, green: 0.98, blue: 0.98)
    static let muted = Color(red: 0.58, green: 0.64, blue: 0.72)
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let concise = Color(red: 0.58, green: 0.77, blue: 0.99)
    static let success = Color(red: 0.06, green: 0.73, blue: 0.51)
}

struct AudioLevelView: View {
    let level: Double
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { i in
                let threshold = Double(i) * 0.04
                Capsule()
                    .fill(level > threshold ? AppTheme.success : AppTheme.muted.opacity(0.25))
                    .frame(width: 4, height: 8 + CGFloat(i) * 2)
            }
        }
        .accessibilityLabel("音量")
    }
}
