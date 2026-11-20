import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = model.palette()
        ZStack {
            ThemeBackground(section: model.showOnboarding ? .junk : model.section)

            if model.showOnboarding {
                OnboardingView()
                    .transition(.screen)
            } else {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 236)
                        .padding(10)
                    ContentArea()
                }
                .transition(.screen)
            }

            ToastView()
            ConfirmOverlay()
            // Hidden once no app is left: the last files are going, then the done screen follows.
            if !model.showOnboarding, model.section == .junk, model.junk.phase == .waitingForApps, !model.junk.waitingApps.isEmpty {
                WaitingAppsPanel()
            }
        }
        .animation(Motion.spring, value: model.junk.phase == .waitingForApps && !model.junk.waitingApps.isEmpty)
        .environment(\.palette, palette)
        .environment(\.animationsLive, model.isActive && !reduceMotion)
        .foregroundStyle(palette.text)
        .preferredColorScheme(.dark)
        // Sparkle, the rules update and auto-clean start once per process in `AppModel.launch()`
        // (from the app delegate): a launch at login has no window. Here only in case the delegate came first without
        // a model (it never does; `launch()` runs once).
        .task { model.launch() }
        #if DEBUG
        .task {
            // `MW_AUTORUN=large`: open Large Files and start a scan (performance checks).
            if ProcessInfo.processInfo.environment["MW_AUTORUN"] == "large" {
                model.showOnboarding = false
                model.section = .largeFiles
                model.largeFiles.startScan()
            }
        }
        #endif
    }
}

/// Header + current screen + primary action.
struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            ZStack {
                switch model.section {
                case .junk: JunkSectionView()
                case .largeFiles: LargeFilesSectionView()
                case .uninstaller: UninstallerSectionView()
                case .disk: DiskSectionView()
                case .privacy: PrivacySectionView()
                case .startup: StartupSectionView()
                case .settings: SettingsView()
                }
            }
            .id(model.section)
            .transition(.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct HeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            if let title = centeredTitle {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.muted)
                    .accessibilityIdentifier("header.title")
                    .transition(.opacity)
            }
            HStack {
                if let back = backAction {
                    Button(action: back) {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            Text("Назад")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hover)
                    .accessibilityIdentifier("header.back")
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer()
                if showsSearch {
                    SearchField()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .animation(Motion.spring, value: backAction == nil)
    }

    private var centeredTitle: LocalizedStringKey? {
        let atIntro = switch model.section {
        case .junk: model.junk.phase == .intro
        case .largeFiles: model.largeFiles.phase == .intro
        case .uninstaller: model.uninstaller.phase == .intro
        // A browser from the start: there is no intro screen.
        case .disk: false
        case .privacy: model.privacy.phase == .intro
        case .startup: model.startup.phase == .intro
        case .settings: true
        }
        return atIntro ? nil : model.section.title
    }

    private var showsSearch: Bool {
        (model.section == .uninstaller && model.uninstaller.phase == .list)
            || (model.section == .junk && model.junk.phase == .results)
            || (model.section == .privacy && model.privacy.phase == .list)
            || (model.section == .startup && model.startup.phase == .list)
    }

    private var backAction: (() -> Void)? {
        switch model.section {
        case .junk where model.junk.phase == .results: model.junk.backToIntro
        case .largeFiles where model.largeFiles.phase == .results: model.largeFiles.backToIntro
        case .uninstaller where model.uninstaller.phase == .list: model.uninstaller.backToIntro
        case .privacy where model.privacy.phase == .list: model.privacy.backToIntro
        case .startup where model.startup.phase == .list: model.startup.backToIntro
        default: nil
        }
    }
}

struct SearchField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        switch model.section {
        case .junk: Binding(get: { model.junk.search }, set: { value in withAnimation(Motion.spring) { model.junk.search = value } })
        case .privacy: Binding(get: { model.privacy.search }, set: { value in withAnimation(Motion.spring) { model.privacy.search = value } })
        case .startup: Binding(get: { model.startup.search }, set: { value in withAnimation(Motion.spring) { model.startup.search = value } })
        default: Binding(get: { model.uninstaller.search }, set: { model.uninstaller.search = $0 })
        }
    }

    var body: some View {
        let text = text
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            TextField(model.section == .junk ? "Поиск по найденному" : model.section == .startup ? "Поиск по автозапуску" : "Поиск программ", text: text)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityIdentifier("search.field")
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.hover)
                .accessibilityLabel("Очистить поиск")
                .accessibilityIdentifier("search.clear")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 10)
        .frame(width: 220, height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? palette.accent.opacity(0.6) : .clear))
    }
}

/// Floating status message.
struct ToastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack {
            Spacer()
            if let toast = model.toast {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(palette.accentSoft)
                        .symbolEffect(.bounce, value: toast.id)
                    Text(toast.text).font(.system(size: 13))
                        .accessibilityIdentifier("toast.text")
                    if toast.offersTrash {
                        Button("Открыть Корзину") {
                            NSWorkspace.shared.open(URL(filePath: NSHomeDirectory()).appending(path: ".Trash"))
                        }
                        .buttonStyle(.hover)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, toast.offersTrash ? 6 : 18)
                .frame(height: 44)
                .glassSurface(.capsule)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                .padding(.bottom, 112)
                .padding(.leading, 256)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
                .id(toast.id)
            }
        }
        .allowsHitTesting(model.toast != nil)
    }
}
