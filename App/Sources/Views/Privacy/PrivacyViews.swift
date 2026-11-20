import Combine
import MacWashingKit
import SwiftUI

struct PrivacySectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let privacy = model.privacy
        ZStack {
            switch privacy.phase {
            case .intro:
                IntroScreen(
                    title: "Приватность",
                    text: "Показывает, каким программам вы дали доступ к камере, микрофону, экрану, файлам и другим данным — как «Конфиденциальность и безопасность» в Системных настройках, только на одном экране.",
                    features: [
                        Feature(symbol: "hand.raised.fill", title: "Все разрешения сразу", text: "Камера, микрофон, запись экрана, файлы, автоматизация и остальные списки macOS."),
                        Feature(symbol: "arrow.counterclockwise", title: "Отозвать доступ", text: "Программа сразу теряет доступ и может запросить его снова, когда он ей понадобится."),
                    ],
                    art: .shield,
                    buttonTitle: "Показать разрешения",
                    canStart: privacy.hasAccess,
                    start: privacy.start
                ) {
                    if !privacy.hasAccess { PrivacyAccessCard() }
                }
                .transition(.screen)
            case .loading:
                ProgressScreen(
                    art: .shield,
                    verb: "Читаю разрешения",
                    progress: Double(privacy.readStores.count) / Double(TCCStore.allCases.count),
                    amount: String(localized: "Баз прочитано: \(privacy.readStores.count)"),
                    path: TCCDatabase.userDatabase(home: model.home).fsPath.replacingOccurrences(of: model.home.fsPath, with: "~"),
                    steps: [
                        .init(id: "user", title: "Разрешения пользователя", status: privacy.readStores.contains(.user) ? .done : .running, size: 0),
                        .init(id: "system", title: "Системные разрешения",
                              status: privacy.readStores.contains(.system) ? .done : (privacy.readStores.contains(.user) ? .running : .waiting), size: 0),
                    ],
                    stop: privacy.backToIntro
                )
                .transition(.screen)
            case .list:
                PrivacyListView()
                    .transition(.screen)
            }
        }
        .animation(Motion.screen, value: privacy.phase)
    }
}

/// Shown on the intro while Full Disk Access is missing: the TCC databases cannot be read without it.
struct PrivacyAccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var asked = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.warning)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.warning.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Нужен полный доступ к диску").font(.system(size: 15, weight: .semibold))
                Text("macOS хранит разрешения в защищённой базе. Включите MacWashing в списке «Полный доступ к диску» — раздел откроется сам.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    SecondaryButton(title: "Открыть Настройки", height: 30) {
                        asked = true
                        Permissions.requestFullDiskAccess()
                    }
                    .accessibilityIdentifier("privacy.grantAccess")
                    if asked {
                        Button("Показать в Finder", action: Permissions.revealAppInFinder)
                            .buttonStyle(.hover)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accentSoft)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.warning.opacity(0.35)))
        .padding(.top, 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.noAccess")
        .animation(Motion.spring, value: asked)
        .onReceive(timer) { _ in model.privacy.refreshAccess() }
    }
}

struct PrivacyListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let privacy = model.privacy
        let shown = privacy.shownGroups
        let selection = privacy.effectiveSelection
        HStack(spacing: 12) {
            categoryList(privacy, shown: shown, selection: selection)
                .frame(width: 300)
            detail(privacy, selection: selection)
        }
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        // Coming back from System Settings: show what changed there (not after a quick ⌘-Tab, see `cameBackFromAway`).
        .onChange(of: model.isActive) { _, active in
            if active, model.cameBackFromAway { Task { await privacy.reload() } }
        }
    }

    // MARK: Categories

    private func categoryList(_ privacy: PrivacyModel, shown: [PrivacyGroup], selection: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                    categoryRow(group.category, count: group.appCount, selected: selection == group.id) { privacy.select(group.id) }
                        .appearIn(delay: 0.06 + Double(min(index, 14)) * 0.024)
                }
                if shown.isEmpty && !privacy.search.isEmpty {
                    Text("Ничего не найдено")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.muted)
                        .padding(.vertical, 16)
                }
                Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 6)
                categoryRow(PrivacyCatalog.location, count: nil, selected: selection == PrivacyModel.locationID) {
                    privacy.select(PrivacyModel.locationID)
                }
            }
            .padding(.leading, 6)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .staggerList()
    }

    private func categoryRow(_ category: PrivacyCategory, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CategoryTile(category: category, size: 28)
                Text(category.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(palette.muted)
                        .contentTransition(.numericText())
                } else {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .contentShape(Rectangle())
            .hoverRow(selected: selected, cornerRadius: 11)
        }
        .buttonStyle(.row)
        .accessibilityIdentifier("privacy.category.\(category.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(Text(category.title))
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ privacy: PrivacyModel, selection: String) -> some View {
        Group {
            if selection == PrivacyModel.locationID {
                locationPane(privacy)
            } else if let group = privacy.selectedGroup {
                groupPane(privacy, group: group)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 28))
                        .foregroundStyle(palette.faint)
                    Text("Ни одна программа пока не просила разрешений")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pane(palette)
        .id(selection)
        .transition(.opacity)
    }

    /// Title and the System Settings button on one row when they fit, the button under the title otherwise.
    private func header(_ category: PrivacyCategory, subtitle: String) -> some View {
        let titles = HStack(spacing: 16) {
            CategoryTile(category: category, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                // Long names («Доступ к ключам входа для браузеров») wrap rather than end in «…».
                Text(category.title)
                    .font(.system(size: 24, weight: .bold))
                    .kerning(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("privacy.title")
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .accessibilityIdentifier("privacy.subtitle")
            }
        }
        let button = SecondaryButton(title: "Открыть в Системных настройках", height: 30) { model.privacy.openSettings(category) }
            .accessibilityIdentifier("privacy.openSettings")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                titles
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 14) {
                titles
                button
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func locationPane(_ privacy: PrivacyModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(PrivacyCatalog.location, subtitle: String(localized: "Хранятся отдельно от остальных разрешений"))
            note(String(localized: "Геолокацию macOS хранит отдельно — посмотреть и изменить её можно только в Системных настройках."),
                 symbol: "info.circle", color: palette.accentSoft)
                .padding(.top, 20)
            Spacer()
        }
        .padding(28)
    }

    private func groupPane(_ privacy: PrivacyModel, group: PrivacyGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(group.category, subtitle: String(localized: "Программ с доступом: \(group.appCount)"))
                if let notice = privacy.notice {
                    note(notice.text, symbol: "exclamationmark.triangle", color: Color(hex: 0xFFD3A0))
                        .accessibilityIdentifier("privacy.notice")
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if privacy.failures[.system] != nil {
                    note(String(localized: "Системная база разрешений не прочиталась: запись экрана, полный доступ к диску и универсальный доступ могут быть неполными."),
                         symbol: "exclamationmark.triangle", color: Color(hex: 0xFFD3A0))
                        .padding(.top, 14)
                }
                if group.category.id == "automation" {
                    Text("Запрет отзывает у программы управление всеми программами из списка сразу.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.faint)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 12)
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 28)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        PrivacyRow(item: item)
                            .appearIn(delay: 0.06 + Double(min(index, 12)) * 0.03)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.never)
            .staggerList(key: group.id)
        }
        .animation(Motion.spring, value: privacy.notice)
    }

    private func note(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
    }
}

/// Square icon of a permission type: a colored tile, as in System Settings.
struct CategoryTile: View {
    @Environment(\.palette) private var palette
    let category: PrivacyCategory
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(LinearGradient(colors: Self.colors(category.id), startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .white.opacity(0.35), radius: 0, y: 0.5)
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    /// Close to the tile colors System Settings uses for each list.
    static func colors(_ id: String) -> [Color] {
        let pair: (UInt32, UInt32) = switch id {
        case "location", "contacts", "photos", "bluetooth", "automation", "appManagement", "home": (0x6FB6FF, 0x2B7CF0)
        case "calendars", "microphone", "reminders": (0xFF8A7A, 0xE8453C)
        case "camera", "speech", "developerTools", "sysAdmin", "other": (0xA3AAB5, 0x5E646E)
        case "media": (0xFF7A9C, 0xE83E6C)
        case "filesAndFolders", "fullDiskAccess", "appData": (0x7FC8FF, 0x3A8EE6)
        case "focus", "passkeys": (0xA38BFF, 0x6A4EE8)
        case "accessibility", "inputMonitoring", "remoteDesktop": (0x6FB6FF, 0x2F6FE0)
        case "screenRecording": (0xFF8A7A, 0xD9443C)
        case "tracking": (0xFFB45E, 0xE8862C)
        default: (0x8BEBCF, 0x23A57F)
        }
        return [Color(hex: pair.0), Color(hex: pair.1)]
    }
}

/// One app with access: icon, name (→ target for Automation), details and date, and how to take the access away.
struct PrivacyRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let item: PrivacyItem

    var body: some View {
        let privacy = model.privacy
        let resetting = privacy.resetting.contains(item.id)
        HStack(spacing: 12) {
            ClientIcon(client: item.client, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.client.isNameKnown ? item.client.name : String(localized: "Программа удалена"))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if let target = item.target {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.faint)
                        ClientIcon(client: target, size: 16)
                        Text(target.isInstalled ? target.name : target.id)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                    }
                    if item.client.isApple {
                        Pill(text: "Apple", color: palette.muted, background: palette.field)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if resetting {
                ProgressView().controlSize(.small).frame(width: 90)
            } else if item.resetBlock == nil {
                SecondaryButton(title: "Запретить", height: 28) { privacy.requestReset(item) }
                    .accessibilityIdentifier("privacy.reset.\(axID)")
            } else {
                Button { privacy.openSettings(item.service.category) } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help(Text(blockReason))
                .accessibilityLabel(Text("Открыть в Системных настройках"))
                .accessibilityIdentifier("privacy.settings.\(axID)")
            }
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.row.\(axID)")
        .appContextMenu {
            if item.resetBlock == nil {
                AppMenuItem("Запретить", symbol: "hand.raised", enabled: !resetting) { privacy.requestReset(item) }
                AppMenuDivider()
            }
            AppMenuItem("Открыть в Системных настройках", symbol: "gearshape") { privacy.openSettings(item.service.category) }
            if let url = item.client.iconURL, item.client.isInstalled {
                AppMenuItem("Показать в Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            AppMenuItem(item.client.kind == .app ? "Скопировать bundle ID" : "Скопировать путь", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.client.id, forType: .string)
            }
        }
    }

    /// `Camera.com.example.zoom`, `AppleEvents.com.example.a→com.example.b` for UI tests.
    private var axID: String {
        "\(item.service.shortName).\(item.client.id)" + (item.target.map { "→" + $0.id } ?? "")
    }

    private var subtitle: String {
        var parts: [String] = []
        // A deleted app known by name: «Программа удалена · <bundle id>»; otherwise the id or path alone.
        if !item.client.isInstalled && item.client.isNameKnown { parts.append(String(localized: "Программа удалена")) }
        if !item.client.isInstalled || item.client.kind == .path { parts.append(item.client.id) }
        if item.target == nil, let detail = item.service.detail { parts.append(detail) }
        if item.isLimited { parts.append(String(localized: "Ограниченный доступ")) }
        if let date = item.entry.lastModified {
            parts.append(String(localized: "изменено \(date.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }

    private var blockReason: String {
        switch item.resetBlock {
        case .pathClient: String(localized: "Запретить доступ этой программе можно только в Системных настройках")
        case .appleClient: String(localized: "Разрешения программ Apple меняются в Системных настройках")
        case .ownApp: String(localized: "Без этого разрешения MacWashing не увидит список")
        case .unsupportedService, nil: String(localized: "Это разрешение можно изменить только в Системных настройках")
        }
    }
}

/// The app's icon, or a generic one when it is gone.
struct ClientIcon: View {
    let client: PrivacyClient
    let size: CGFloat

    var body: some View {
        Group {
            if let url = client.iconURL, client.isInstalled {
                Image(nsImage: IconCache.icon(for: url)).resizable()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: client.kind == .app ? .applicationBundle : .unixExecutable))
                    .resizable()
                    .opacity(0.6)
            }
        }
        .frame(width: size, height: size)
    }
}

struct PrivacyConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let privacy = model.privacy
        if let item = privacy.pending {
            let name = item.client.isNameKnown ? item.client.name : item.client.id
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    ClientIcon(client: item.client, size: 60)
                        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
                    CategoryTile(category: item.service.category, size: 26)
                        .offset(x: 8, y: 6)
                }
                .frame(height: 64)
                Text("Запретить доступ «\(item.service.category.title)» для \(name)?")
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .accessibilityIdentifier("confirm.title")
                Text(message(item, name: name))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Button("Открыть в Системных настройках") { privacy.openSettings(item.service.category) }
                    .buttonStyle(.hover)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentSoft)
                    .padding(.top, 10)
                    .accessibilityIdentifier("confirm.openSettings")
                ConfirmButtons(confirmTitle: "Запретить", cancel: privacy.cancelConfirm, confirm: privacy.confirmReset)
            }
        }
    }

    private func message(_ item: PrivacyItem, name: String) -> String {
        // `tccutil reset` clears the decision: access ends now, and the app may ask again.
        var text = String(localized: "\(name) сразу потеряет доступ и сможет запросить его снова позже.")
        if item.service.shortName == "AppleEvents" {
            text += " " + String(localized: "Программа потеряет доступ ко всем программам, которыми управляет.")
        } else if let detail = item.service.detail, item.service.isKnown {
            text += " " + String(localized: "Только: \(detail).")
        }
        if model.privacy.needsHelper(item) {
            text += " " + String(localized: "Это системное разрешение: без помощника macOS может отказать.")
        }
        return text
    }
}
