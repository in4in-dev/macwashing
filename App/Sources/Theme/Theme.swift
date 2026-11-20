import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case junk, largeFiles, uninstaller, disk, privacy, startup, settings

    var id: String { rawValue }
    /// Sections in the sidebar and the «Раздел» menu. `.startup` is built but hidden for now: add it
    /// back here and in the menu in MacWashingApp.swift to show it.
    static let modules: [AppSection] = [.junk, .largeFiles, .uninstaller, .disk, .privacy]

    var title: LocalizedStringKey {
        switch self {
        case .junk: "Сборка мусора"
        case .largeFiles: "Большие файлы"
        case .uninstaller: "Деинсталлятор"
        case .disk: "Хранилище"
        case .privacy: "Приватность"
        case .startup: "Автозапуск"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .junk: "washer"
        case .largeFiles: "doc.text.magnifyingglass"
        case .uninstaller: "square.grid.2x2"
        case .disk: "internaldrive"
        case .privacy: "hand.raised.fill"
        case .startup: "power"
        case .settings: "gearshape"
        }
    }

    /// Icon tile gradient in the sidebar.
    var tile: LinearGradient {
        let colors: [Color] = switch self {
        case .junk: [Color(hex: 0x7FE4F2), Color(hex: 0x2C98C2)]
        case .largeFiles: [Color(hex: 0xFFCF85), Color(hex: 0xE8862C)]
        case .uninstaller: [Color(hex: 0xC3B7FF), Color(hex: 0x7A63EE)]
        case .disk: [Color(hex: 0xA2EBB4), Color(hex: 0x2FA66A)]
        case .privacy: [Color(hex: 0xFF9C94), Color(hex: 0xE0433F)]
        case .startup: [Color(hex: 0x9CC8FF), Color(hex: 0x3F7FE6)]
        case .settings: [Color(hex: 0xA3AAB5), Color(hex: 0x5E646E)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Every color the interface uses, for one section.
struct Palette {
    let section: AppSection

    // Text
    var text: Color { Color(hex: 0xF3F4F6) }
    var muted: Color { text.opacity(0.64) }
    var faint: Color { text.opacity(0.48) }

    // Surfaces
    var sidebar: Color { .white.opacity(0.035) }
    var sidebarStroke: Color { .white.opacity(0.07) }
    var pane: Color { .white.opacity(0.028) }
    var paneStroke: Color { .white.opacity(0.06) }
    var selection: Color { .white.opacity(0.075) }
    var field: Color { .white.opacity(0.06) }
    var card: Color { .white.opacity(0.04) }
    var cardStroke: Color { .white.opacity(0.075) }
    var line: Color { .white.opacity(0.06) }
    var track: Color { .white.opacity(0.08) }
    var sheet: Color { Color(hex: 0x191B21) }

    // Accent
    var accent: Color {
        switch section {
        case .junk, .settings: Color(hex: 0x5BD6E8)
        case .largeFiles: Color(hex: 0xFFB45E)
        case .uninstaller: Color(hex: 0xA897FF)
        case .disk: Color(hex: 0x74DE9C)
        case .privacy: Color(hex: 0xFF7B72)
        case .startup: Color(hex: 0x82B6FF)
        }
    }
    var accentSoft: Color { accent }
    var onAccent: Color { Color(hex: 0x0B0C10) }
    var checkRing: Color { .white.opacity(0.34) }
    var warning: Color { Color(hex: 0xFFC98A) }
    var danger: Color { Color(hex: 0xD93C3F) }
    var disk: LinearGradient {
        LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
    }
}

/// Full-window background: dark graphite lit by the section's accent. Every section's layer is stacked and
/// cross-faded.
struct ThemeBackground: View {
    let section: AppSection

    @State private var shown: AppSection?
    @State private var previous: AppSection?

    /// Every background is always in the stack. The new one fades in on top while the one it replaces stays fully
    /// opaque underneath, so the dark base never shows through halfway. Nothing is inserted or removed during the
    /// change.
    var body: some View {
        let top = shown ?? section
        ZStack {
            Color(hex: 0x0B0C10)
            ForEach(AppSection.allCases) { layerSection in
                layer(layerSection)
                    .opacity(layerSection == top || layerSection == previous ? 1 : 0)
                    .zIndex(layerSection == top ? 2 : (layerSection == previous ? 1 : 0))
            }
        }
        .onAppear { if shown == nil { shown = section } }
        .onChange(of: section) { old, new in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { previous = shown ?? old }
            withAnimation(.easeInOut(duration: 0.8)) { shown = new }
        }
        .ignoresSafeArea()
    }

    private func layer(_ section: AppSection) -> some View {
        let accent = Palette(section: section).accent
        return ZStack {
            Color(hex: 0x0B0C10)
            RadialGradient(colors: [accent.opacity(0.2), .clear], center: UnitPoint(x: 0.88, y: -0.06), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [accent.opacity(0.06), .clear], center: UnitPoint(x: 0.18, y: 1.12), startRadius: 0, endRadius: 480)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(section: .junk)
}

private struct AnimationsLiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Decorative motion runs only while the app is in front and Reduce Motion is off.
    var animationsLive: Bool {
        get { self[AnimationsLiveKey.self] }
        set { self[AnimationsLiveKey.self] = newValue }
    }

    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Shared motion curves.
enum Motion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let bouncy = Animation.spring(response: 0.35, dampingFraction: 0.6)
    static let screen = Animation.spring(response: 0.55, dampingFraction: 0.9)
}
