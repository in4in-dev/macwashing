import MacWashingKit
import SwiftUI

struct StartupSectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let startup = model.startup
        ZStack {
            switch startup.phase {
            case .intro:
                IntroScreen(
                    title: "Автозапуск",
                    text: "Показывает всё, что запускается само: при входе в систему, в фоне и при загрузке Mac — агенты, службы и объекты входа программ.",
                    features: [
                        Feature(symbol: "power", title: "Включить и выключить", text: "Агенты и службы выключаются в launchd, а их файлы остаются на месте — включить обратно можно в любой момент."),
                        Feature(symbol: "exclamationmark.triangle", title: "Сломанные и лишние", text: "Видно, какой программе принадлежит каждый объект и какие остались от удалённых программ."),
                    ],
                    art: .power,
                    buttonTitle: "Показать автозапуск",
                    start: startup.start
                ) { EmptyView() }
                .transition(.screen)
            case .loading:
                ProgressScreen(
                    art: .power,
                    verb: "Ищу автозапуск",
                    progress: Double(startup.readKinds.count + (startup.stateRead ? 1 : 0)) / Double(StartupKind.allCases.count + 1),
                    amount: String(localized: "Групп прочитано: \(startup.readKinds.count)"),
                    path: currentPath(startup),
                    steps: steps(startup),
                    stop: startup.backToIntro
                )
                .transition(.screen)
            case .list:
                StartupListView()
                    .transition(.screen)
            }
        }
        .animation(Motion.screen, value: startup.phase)
    }

    /// The kinds in the order they are read: the launch job folders, then the apps, then launchd's state.
    private static let order: [StartupKind] = [.userAgent, .systemAgent, .systemDaemon, .loginItem]

    private func currentPath(_ startup: StartupModel) -> String {
        let next = Self.order.first { !startup.readKinds.contains($0) }
        return switch next {
        case .userAgent: "~/Library/LaunchAgents"
        case .systemAgent: "/Library/LaunchAgents"
        case .systemDaemon: "/Library/LaunchDaemons"
        case .loginItem: "/Applications"
        case nil: "launchctl print-disabled"
        }
    }

    private func steps(_ startup: StartupModel) -> [ProgressScreen.Step] {
        let running = Self.order.first { !startup.readKinds.contains($0) }
        var steps = Self.order.map { kind in
            ProgressScreen.Step(id: kind.rawValue, title: kind.title,
                                status: startup.readKinds.contains(kind) ? .done : (running == kind ? .running : .waiting), size: 0)
        }
        steps.append(.init(id: "state", title: "Состояние в launchd",
                           status: startup.stateRead ? .done : (running == nil ? .running : .waiting), size: 0))
        return steps
    }
}

extension StartupKind {
    var title: LocalizedStringKey {
        switch self {
        case .loginItem: "Программы при входе"
        case .userAgent: "Агенты пользователя"
        case .systemAgent: "Системные агенты"
        case .systemDaemon: "Системные службы"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .loginItem: "Объекты входа и фоновые объекты, которые программы регистрируют в macOS. Включаются и выключаются в Системных настройках."
        case .userAgent: "~/Library/LaunchAgents · запускаются, когда вы входите в систему"
        case .systemAgent: "/Library/LaunchAgents · запускаются у каждого пользователя · нужны права администратора"
        case .systemDaemon: "/Library/LaunchDaemons · работают от имени системы, даже когда никто не вошёл · нужны права администратора"
        }
    }

    var symbol: String {
        switch self {
        case .loginItem: "person.crop.circle.badge.checkmark"
        case .userAgent: "person.fill"
        case .systemAgent: "person.2.fill"
        case .systemDaemon: "gearshape.2.fill"
        }
    }
}

struct StartupListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let startup = model.startup
        let groups = startup.groups
        VStack(alignment: .leading, spacing: 0) {
            toolbar(startup)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            if let notice = startup.notice {
                noticeView(notice)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        groupHeader(group)
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            StartupRow(item: item)
                                .appearIn(delay: 0.06 + Double(min(index, 12)) * 0.03)
                        }
                    }
                    if groups.isEmpty {
                        empty(startup)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            .staggerList(key: startup.filter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pane(palette)
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        .animation(Motion.spring, value: startup.notice)
        // Coming back from System Settings: show what changed there (not after a quick ⌘-Tab, see `cameBackFromAway`).
        .onChange(of: model.isActive) { _, active in
            if active, model.cameBackFromAway { Task { await startup.reload() } }
        }
    }

    private func toolbar(_ startup: StartupModel) -> some View {
        let filters: [(StartupFilter, LocalizedStringKey)] = [
            (.all, "Все · \(startup.count(.all))"),
            (.on, "Включены · \(startup.count(.on))"),
            (.off, "Выключены · \(startup.count(.off))"),
            (.broken, "Сломанные · \(startup.count(.broken))"),
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                picker(startup, filters).frame(maxWidth: 520)
                Spacer(minLength: 8)
                settingsButton(startup)
            }
            VStack(alignment: .leading, spacing: 10) {
                picker(startup, filters)
                settingsButton(startup)
            }
        }
    }

    private func picker(_ startup: StartupModel, _ filters: [(StartupFilter, LocalizedStringKey)]) -> some View {
        SegmentedPicker(
            options: filters,
            selection: Binding(get: { startup.filter }, set: { startup.filter = $0 }),
            onChange: { model.play(.navigate) },
            identifier: "startup.filter"
        )
    }

    private func settingsButton(_ startup: StartupModel) -> some View {
        SecondaryButton(title: "Объекты входа в Настройках", height: 30, action: startup.openLoginItemsSettings)
            .accessibilityIdentifier("startup.openLoginItems")
    }

    private func groupHeader(_ group: StartupGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: group.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accentSoft)
                .frame(width: 30, height: 30)
                .card(palette, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(group.kind.title).font(.system(size: 15, weight: .semibold))
                    Text("\(group.items.count)")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(palette.muted)
                        .contentTransition(.numericText())
                }
                Text(group.kind.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("startup.group.\(group.kind.rawValue)")
    }

    private func noticeView(_ text: String) -> some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xFFD3A0))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("startup.notice")
            Spacer(minLength: 8)
            if !model.helper.isCurrent && model.sandbox == nil {
                Button("Открыть Настройки") { model.go(to: .settings) }
                    .buttonStyle(.hover)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentSoft)
                    .accessibilityIdentifier("startup.notice.settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xFFD3A0).opacity(0.12)))
    }

    private func empty(_ startup: StartupModel) -> some View {
        VStack(spacing: 10) {
            Image(systemName: startup.items.isEmpty ? "power" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(palette.faint)
            Text(startup.items.isEmpty ? "Сторонние программы ничего не запускают автоматически" : "Ничего не найдено")
                .font(.system(size: 14))
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityIdentifier("startup.empty")
    }
}

/// One startup item: icon, name, owner, what starts it and the path; the switch, or the way to System Settings.
struct StartupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let item: StartupItem

    var body: some View {
        let startup = model.startup
        let busy = startup.switching.contains(item.id)
        HStack(spacing: 12) {
            StartupIcon(item: item, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isBroken {
                        Pill(text: "Сломан", color: Color(hex: 0xFFD3A0), background: Color(hex: 0xFFD3A0).opacity(0.14))
                            .help(Text("Программа, которую он запускает, удалена"))
                            .accessibilityIdentifier("startup.broken.\(axID)")
                    }
                    if item.needsAdmin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.faint)
                            .help(Text("Нужны права администратора"))
                            .accessibilityLabel(Text("Нужны права администратора"))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(item.url.fsPath))
            }
            Spacer(minLength: 8)
            if item.label != nil, item.source != .legacyLoginItem {
                // Loaded into launchd right now (what `launchctl print` sees), whatever the switch says.
                Circle()
                    .fill(item.isLoaded ? Color(hex: 0x34C759) : .clear)
                    .overlay(Circle().strokeBorder(item.isLoaded ? .clear : palette.faint, lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .help(item.isLoaded ? Text("Загружен в launchd сейчас") : Text("Сейчас не загружен в launchd"))
                    .accessibilityLabel(item.isLoaded ? Text("Загружен в launchd сейчас") : Text("Сейчас не загружен в launchd"))
                    .accessibilityIdentifier("startup.loaded.\(axID)")
            }
            Text(item.isEnabled ? "Включён" : "Выключен")
                .font(.system(size: 12))
                .foregroundStyle(item.isEnabled ? palette.muted : palette.faint)
                .accessibilityIdentifier("startup.status.\(axID)")
            control(startup, busy: busy)
                .frame(width: 44, height: 32)
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startup.row.\(axID)")
        .appContextMenu {
            if item.canToggle {
                AppMenuItem(item.isEnabled ? "Выключить" : "Включить", symbol: "power", enabled: !busy) { startup.toggle(item) }
                AppMenuDivider()
            }
            if item.toggleBlock == .systemSettings {
                AppMenuItem("Открыть в Системных настройках", symbol: "gearshape", action: startup.openLoginItemsSettings)
            }
            AppMenuItem("Показать в Finder", symbol: "folder") { startup.reveal(item) }
            if let label = item.label {
                AppMenuItem("Скопировать метку", symbol: "tag") { copy(label) }
            }
            AppMenuItem("Скопировать путь", symbol: "doc.on.doc") { copy(item.url.fsPath) }
        }
    }

    @ViewBuilder
    private func control(_ startup: StartupModel, busy: Bool) -> some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if item.canToggle {
            ToggleSwitch(isOn: Binding(get: { item.isEnabled }, set: { _ in startup.toggle(item) }), verbatim: item.name)
                .accessibilityIdentifier("startup.toggle.\(axID)")
        } else if item.toggleBlock == .systemSettings {
            Button(action: startup.openLoginItemsSettings) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help(Text("Включается и выключается в Системных настройках ▸ Основные ▸ Объекты входа"))
            .accessibilityLabel(Text("Открыть в Системных настройках"))
            .accessibilityIdentifier("startup.settings.\(axID)")
        } else {
            Image(systemName: "lock")
                .font(.system(size: 13))
                .foregroundStyle(palette.faint)
                .help(Text("MacWashing не переключает этот объект: он системный, ссылается на другой файл или его может изменить кто угодно"))
                .accessibilityIdentifier("startup.locked.\(axID)")
        }
    }

    private var axID: String { item.label ?? item.name }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let owner = item.owner {
            if owner.isRemoved {
                parts.append(String(localized: "\(owner.name) · программа удалена"))
            } else if owner.name != item.name {
                parts.append(owner.name)
            }
        }
        parts.append(trigger)
        if item.label != item.name, let label = item.label { parts.append(label) }
        let home = model.home.fsPath
        let path = item.url.fsPath
        parts.append(path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        return parts.joined(separator: " · ")
    }

    private var trigger: String {
        if item.source == .appLoginItem || item.source == .legacyLoginItem { return String(localized: "При входе") }
        if item.keepAlive { return String(localized: "Работает постоянно") }
        if let interval = item.startInterval {
            return interval >= 60 ? String(localized: "Раз в \(interval / 60) мин") : String(localized: "Раз в \(interval) с")
        }
        if item.hasCalendar { return String(localized: "По расписанию") }
        if item.runAtLoad {
            return item.kind == .systemDaemon || item.source == .appDaemon ? String(localized: "При загрузке Mac") : String(localized: "При входе")
        }
        return String(localized: "По запросу")
    }
}

/// The owner's icon, the program's own app, or a generic tool icon.
struct StartupIcon: View {
    let item: StartupItem
    let size: CGFloat

    var body: some View {
        Group {
            if let url = [item.programApp, item.owner?.appURL].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.fsPath) }) {
                Image(nsImage: IconCache.icon(for: url)).resizable()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: .unixExecutable))
                    .resizable()
                    .opacity(0.6)
            }
        }
        .frame(width: size, height: size)
        .saturation(item.isEnabled ? 1 : 0.2)
        .opacity(item.isEnabled ? 1 : 0.75)
    }
}

/// Asked before something that needs an administrator is turned off.
struct StartupConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let startup = model.startup
        if let item = startup.pending {
            VStack(spacing: 0) {
                StartupIcon(item: item, size: 60)
                    .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
                    .frame(height: 64)
                Text("Выключить «\(item.name)»?")
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .accessibilityIdentifier("confirm.title")
                Text(message(item))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                ConfirmButtons(confirmTitle: "Выключить", cancel: startup.cancelConfirm, confirm: startup.confirmTurnOff)
            }
        }
    }

    private func message(_ item: StartupItem) -> String {
        var text = item.kind == .systemDaemon
            ? String(localized: "Это системная служба: MacWashing остановит её и выключит через помощника с правами администратора.")
            : String(localized: "Это системный агент: MacWashing остановит его и выключит через помощника с правами администратора.")
        if let owner = item.owner, !owner.isRemoved {
            text += " " + String(localized: "\(owner.name) может работать хуже без него.")
        }
        text += " " + String(localized: "Файл остаётся на месте — включить обратно можно здесь же.")
        return text
    }
}
