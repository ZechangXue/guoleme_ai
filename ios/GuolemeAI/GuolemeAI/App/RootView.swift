import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ListenView()
                .tabItem { Label(model.t(.tabPrompter), systemImage: "waveform") }
            ContextView()
                .tabItem { Label(model.t(.tabLibrary), systemImage: "doc.text") }
            SettingsView()
                .tabItem { Label(model.t(.tabSettings), systemImage: "gearshape") }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .overlay {
            if !model.settings.didChooseUILanguage {
                LanguageOnboardingView()
            }
        }
    }
}

private struct LanguageOnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppTheme.bg.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("选择界面语言")
                        .font(.title2.weight(.bold))
                    Text("Choose interface language")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                }
                VStack(spacing: 6) {
                    Text("只改 App 按钮和说明，不影响回答语言。")
                        .font(.footnote)
                    Text("Changes the app UI only. Answer language stays separate.")
                        .font(.footnote)
                }
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    languageButton(title: "中文", language: .zh)
                    languageButton(title: "English", language: .en)
                }
                .padding(.top, 8)
            }
            .padding(28)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func languageButton(title: String, language: UILanguage) -> some View {
        Button {
            model.settingsStore.update {
                $0.uiLanguage = language
                $0.didChooseUILanguage = true
            }
        } label: {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accent)
    }
}
