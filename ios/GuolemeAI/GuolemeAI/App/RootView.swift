import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ListenView()
                .tabItem { Label("提词", systemImage: "waveform") }
            ContextView()
                .tabItem { Label("资料", systemImage: "doc.text") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
    }
}
