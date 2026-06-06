import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(StoreKitService.self) private var store
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var openAtLogin = LoginItemService.isEnabled

    /// Reads/writes the macOS Login Item registration. Reflects the real system state (the user
    /// can also toggle it in System Settings), and falls back if registration is refused.
    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { openAtLogin },
            set: { newValue in
                let ok = newValue ? LoginItemService.enable() : LoginItemService.disable()
                openAtLogin = ok ? newValue : LoginItemService.isEnabled
            }
        )
    }

    /// Persists the language choice (via AppSettings.didSet) and applies it for AppKit/system.
    private var languageBinding: Binding<String?> {
        Binding(
            get: { env.settings.languageCode },
            set: { newValue in
                env.settings.languageCode = newValue
                LanguageController.apply(newValue)
            }
        )
    }

    var body: some View {
        @Bindable var env = env
        Form {
            Section("Subscription") {
                HStack {
                    VStack(alignment: .leading) {
                        Text(store.state.isPro ? String(localized: "WallPics Pro") : String(localized: "Free Plan"))
                            .font(.headline)
                        Text(store.state.isPro
                             ? String(localized: "Watermark removed. Thank you.")
                             : String(localized: "Free wallpapers carry a small WallPics watermark."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !store.state.isPro {
                        Button("Upgrade") { PaywallPresenter.show() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Manage") {
                            if let url = URL(string: "macappstore://apps.apple.com/account/subscriptions") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                HStack {
                    Button("Restore Purchases") {
                        Task {
                            isRestoring = true
                            restoreMessage = nil
                            let wasPro = store.state.isPro
                            await store.restore()
                            isRestoring = false
                            restoreMessage = store.state.isPro
                                ? (wasPro ? String(localized: "You're all set.") : String(localized: "Purchases restored."))
                                : String(localized: "No purchases found to restore.")
                        }
                    }
                    .disabled(isRestoring)
                    if isRestoring { ProgressView().controlSize(.small) }
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Playback") {
                Toggle("Play on battery power", isOn: $env.settings.playOnBatteryPower)
                    .onChange(of: env.settings.playOnBatteryPower) { _, _ in
                        NotificationCenter.default.post(name: .reapplyPowerState, object: nil)
                    }
                Toggle("Pause in Low Power Mode", isOn: $env.settings.pauseOnLowPowerMode)
                    .onChange(of: env.settings.pauseOnLowPowerMode) { _, _ in
                        NotificationCenter.default.post(name: .reapplyPowerState, object: nil)
                    }
            }

            Section("Cache") {
                Toggle("Cache recent wallpapers (up to 500 MB)", isOn: $env.settings.cacheRecentWallpapers)
                    .onChange(of: env.settings.cacheRecentWallpapers) { _, enabled in
                        Task { await CacheManager.shared.setCacheEnabled(enabled) }
                    }
            }

            Section("Startup") {
                Toggle("Open WallPics at login", isOn: openAtLoginBinding)
                Text("Keeps live & shader wallpapers running after a restart. WallPics launches in the background — close its window and it stays out of your way in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Toggle("Follow system appearance", isOn: $env.settings.respectSystemAppearance)
                    .onChange(of: env.settings.respectSystemAppearance) { _, newValue in
                        NSApp.appearance = newValue ? nil : NSAppearance(named: .darkAqua)
                    }
            }

            Section("Language") {
                Picker("Language", selection: languageBinding) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(String?.some(lang.rawValue))
                    }
                }
                Text("Changes apply right away. Restart the app for the menu bar to switch too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                LabeledContent("Copyright", value: "© \(Calendar.current.component(.year, from: Date())) IgKnight Technologies Ltd")
                Button("Replay Onboarding") {
                    OnboardingPresenter.resetForTesting()
                    env.showOnboarding = true
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { openAtLogin = LoginItemService.isEnabled }
    }
}

extension Bundle {
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
