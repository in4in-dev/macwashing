import Combine
import MacWashingKit
import MacWashingXPC
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.palette) var palette

    enum Tab: String, CaseIterable, Identifiable {
        case general, autoClean, exclusions, about
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .general: "Основные"
            case .autoClean: "Автоочистка"
            case .exclusions: "Исключения"
            case .about: "О программе"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .autoClean: "clock.arrow.circlepath"
            case .exclusions: "folder.badge.minus"
            case .about: "info.circle"
            }
        }
    }

    @AppStorage("settingsTab") private var tab = Tab.general
    /// Less than the 28 between the tabs and the content, so the scroll view never covers the tabs.
    private static let glowRoom: CGFloat = 24
    /// Read again every couple of seconds while Settings is on screen: the user grants access in System Settings and
    /// comes back, and the row must not keep saying «Открыть Настройки».
    @State private var fullDiskAccess = Permissions.hasFullDiskAccess
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Настройки")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                    .padding(.bottom, 16)
                ForEach(Tab.allCases) { item in
                    tabButton(item)
                }
            }
            .frame(width: 180, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general: general
                    case .autoClean: autoClean
                    case .exclusions: exclusions
                    case .about: about
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 36)
                .padding(.bottom, 48)
                // Room for the glow of a `PrimaryButton` at the left edge: the scroll view clips to its bounds, and
                // the negative padding below puts the content back where it was.
                .padding(.horizontal, Self.glowRoom)
                .id(tab)
                .transition(.opacity)
            }
            .scrollIndicators(.never)
            .padding(.horizontal, -Self.glowRoom)
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .animation(Motion.spring, value: tab)
        .onAppear { model.helper.refresh() }
        .onReceive(permissionTimer) { _ in
            guard model.isActive else { return }
            let granted = Permissions.hasFullDiskAccess
            if granted != fullDiskAccess { withAnimation(Motion.spring) { fullDiskAccess = granted } }
            model.helper.refresh()
        }
    }


    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        return Button {
            guard !selected else { return }
            model.play(.toggle)
            tab = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 20)
                Text(item.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? palette.text : palette.muted)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.selection) }
            }
            .contentShape(Rectangle())
            .hoverRow(cornerRadius: 9)
        }
        .buttonStyle(.row)
        .accessibilityIdentifier("settings.tab.\(item.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Tabs

    @ViewBuilder
    private var general: some View {
        @Bindable var model = model
        group("Оформление", index: 0) {
            row("Звуки интерфейса", hint: "Тихие отклики на действия и окончание очистки") {
                ToggleSwitch(isOn: $model.soundEnabled, label: "Звуки интерфейса") {
                    if model.soundEnabled { model.play(.found) }
                }
                .accessibilityIdentifier("settings.sound")
            }
            divider
            row("Показывать в строке меню", hint: model.autoClean.keepsRunningInMenuBar ? "Автоочистка работает и без значка" : nil) {
                ToggleSwitch(isOn: Binding(get: { model.menuBarIconShown }, set: { model.showsMenuBarIcon = $0 }),
                             label: "Показывать в строке меню") { model.play(.toggle) }
                    .accessibilityIdentifier("settings.menuBarIcon")
            }
        }

        group("Удаление", index: 1) {
            row("Сборка мусора", hint: "Кэши и журналы пересоздаются, Корзина им не нужна") {
                SegmentedPicker(options: [(RemovalMode.delete, "Сразу"), (.trash, "В Корзину")], selection: $model.junkRemoval, onChange: {
                    model.play(.toggle)
                }, identifier: "settings.junkRemoval")
                .frame(width: 200)
            }
            divider
            // The Uninstaller removes for good, always.
            row("Большие файлы") {
                SegmentedPicker(options: [(RemovalMode.delete, "Сразу"), (.trash, "В Корзину")], selection: $model.otherRemoval, onChange: {
                    model.play(.toggle)
                }, identifier: "settings.otherRemoval")
                .frame(width: 200)
            }
            divider
            row("Спрашивать подтверждение перед удалением") {
                ToggleSwitch(isOn: $model.confirmBeforeDelete, label: "Спрашивать подтверждение") { model.play(.toggle) }
                    .accessibilityIdentifier("settings.confirm")
            }
        }

        group("Вход в систему", index: 2) {
            row("Запускать при старте системы", symbol: "power",
                hint: model.loginItem.state == .needsApproval
                    ? "Выключено в Системных настройках ▸ Объекты входа"
                    : "MacWashing запустится без окна, только в строке меню") {
                if model.loginItem.state == .needsApproval {
                    SecondaryButton(title: "Открыть Настройки", height: 30, action: model.loginItem.openSystemSettings)
                } else {
                    ToggleSwitch(isOn: Binding(get: { model.loginItem.isOn }, set: { model.autoClean.setLaunchAtLogin($0) }),
                                 label: "Запускать при старте системы") { model.play(.toggle) }
                        .accessibilityIdentifier("settings.launchAtLogin")
                }
            }
        }

        group("Язык интерфейса", index: 3) {
            row("Язык", symbol: "globe", hint: model.languageChanged ? "Язык сменится после перезапуска" : nil) {
                HStack(spacing: 10) {
                    if model.languageChanged {
                        SecondaryButton(title: "Перезапустить", height: 30, action: model.restart)
                            .transition(.opacity)
                    }
                    languageMenu
                }
            }
        }

        group("Доступ", index: 4) {
            row("Полный доступ к диску", symbol: "checkmark.shield") {
                if fullDiskAccess {
                    status("Разрешён", ok: true)
                } else {
                    SecondaryButton(title: "Открыть Настройки", height: 30, action: Permissions.requestFullDiskAccess)
                }
            }
            divider
            row(text: Text("Помощник для системных папок"), symbol: "key", hint: helperHint) {
                switch model.helper.status {
                case .enabled: status("Установлен · \(HelperConstants.version)", ok: true)
                case .outdated: SecondaryButton(title: "Обновить", height: 30, action: model.helper.reinstall)
                case .notResponding: SecondaryButton(title: "Переустановить", height: 30, action: model.helper.reinstall)
                case .needsApproval: SecondaryButton(title: "Разрешить в Настройках", height: 30, action: model.helper.install)
                case .notInstalled, .unavailable: SecondaryButton(title: "Установить", height: 30, action: model.helper.install)
                }
            }
        }

        updatesGroup
    }

    /// App updates (Sparkle) and rules updates; shown only for what this build can do (both are off in debug builds).
    @ViewBuilder
    private var updatesGroup: some View {
        @Bindable var updates = model.updates
        @Bindable var rules = model.rulesUpdates
        if updates.isAvailable || rules.isAvailable {
            group("Обновления", index: 5) {
                if updates.isAvailable {
                    row("Проверять обновления автоматически", symbol: "arrow.triangle.2.circlepath") {
                        ToggleSwitch(isOn: $updates.automaticallyChecks, label: "Проверять обновления автоматически") { model.play(.toggle) }
                            .accessibilityIdentifier("settings.updates.check")
                    }
                    divider
                    row("Устанавливать обновления автоматически", symbol: "arrow.down.circle",
                        hint: "Загружаются в фоне и ставятся, когда вы закрываете программу") {
                        ToggleSwitch(isOn: $updates.automaticallyInstalls, label: "Устанавливать обновления автоматически") { model.play(.toggle) }
                            .accessibilityIdentifier("settings.updates.install")
                    }
                    if rules.isAvailable { divider }
                }
                if rules.isAvailable {
                    row("Обновлять базу правил автоматически", symbol: "cylinder.split.1x2",
                        hint: "Новые правила начинают работать после перезапуска") {
                        ToggleSwitch(isOn: $rules.isEnabled, label: "Обновлять базу правил автоматически") { model.play(.toggle) }
                            .accessibilityIdentifier("settings.updates.rules")
                    }
                }
                if updates.isAvailable {
                    divider
                    row(text: Text("Проверить сейчас"), hint: updates.lastCheck.map { Text("Последняя проверка: \($0, format: .dateTime.day().month().hour().minute())") }) {
                        SecondaryButton(title: "Проверить", height: 30, action: updates.checkNow)
                            .accessibilityIdentifier("settings.updates.checkNow")
                    }
                }
            }
        }
    }

    // MARK: Auto-clean

    @ViewBuilder
    private var autoClean: some View {
        let autoClean = model.autoClean
        let settings = autoClean.settings
        group("Автоочистка", index: 0) {
            row("Автоочистка", symbol: "clock.arrow.circlepath", hint: "Удаляет мусор по расписанию, когда Mac включён") {
                ToggleSwitch(isOn: Binding(get: { settings?.isEnabled == true }, set: { autoClean.setEnabled($0) }),
                             label: "Автоочистка") { model.play(.toggle) }
                    .accessibilityIdentifier("settings.autoClean.enabled")
            }
            // Switched off, only the switch shows; the saved schedule comes back with it.
            if let settings, settings.isEnabled {
                divider
                row("Как часто", symbol: "calendar") {
                    SegmentedPicker(options: AutoCleanFrequency.allCases.map { ($0, $0.title) },
                                    selection: Binding(get: { settings.schedule.frequency },
                                                       set: { value in autoClean.setSchedule { $0.frequency = value } }),
                                    onChange: { model.play(.toggle) }, identifier: "settings.autoClean.frequency")
                        // Debug has a fourth choice, «Каждую минуту».
                        .frame(width: AutoCleanFrequency.allCases.count > 3 ? 400 : 330)
                }
                divider
                row(text: Text("Когда"), symbol: "clock", hint: nextRunHint(autoClean)) {
                    whenControls(settings.schedule, autoClean)
                }
                divider
                modeRow(settings, autoClean)
                divider
                row(text: lastRunText(autoClean), symbol: "checkmark.circle", hint: lastRunHint(autoClean)) {
                    EmptyView()
                }
                divider
                row("Уведомлять о результате", symbol: "bell", hint: "Если освобождено больше 2 ГБ") {
                    ToggleSwitch(isOn: Binding(get: { settings.notifies }, set: { autoClean.setNotifies($0) }),
                                 label: "Уведомлять о результате") { model.play(.toggle) }
                        .accessibilityIdentifier("settings.autoClean.notify")
                }
            }
        }
        Text("Объекты с пометкой «Осторожно» и файлы открытых программ автоочистка не трогает. Системные объекты удаляются, только если установлен помощник. Пока автоочистка включена, кнопка закрытия окна оставляет MacWashing в строке меню.")
            .font(.system(size: 12))
            .foregroundStyle(palette.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.leading, 4)
    }

    /// The day (weekly, monthly) and the time; nothing for Debug's minute.
    @ViewBuilder
    private func whenControls(_ schedule: AutoCleanSchedule, _ autoClean: AutoCleanModel) -> some View {
        if !schedule.frequency.isShort {
            HStack(spacing: 8) {
                switch schedule.frequency {
                case .weekly:
                    CapsuleMenu(choices: Array(1...7), selection: schedule.weekday,
                                title: { Calendar.current.standaloneWeekdaySymbols[$0 - 1] },
                                pick: { day in autoClean.setSchedule { $0.weekday = day }; model.play(.toggle) },
                                identifier: "settings.autoClean.weekday")
                case .monthly:
                    CapsuleMenu(choices: Array(1...31), selection: schedule.day,
                                title: { String(localized: "\($0) числа") },
                                pick: { day in autoClean.setSchedule { $0.day = day }; model.play(.toggle) },
                                identifier: "settings.autoClean.day")
                default: EmptyView()
                }
                CapsuleMenu(choices: ClockTime.choices, selection: schedule.hour * 60 + schedule.minute,
                            title: ClockTime.string,
                            pick: { time in autoClean.setSchedule { $0.hour = time / 60; $0.minute = time % 60 }; model.play(.toggle) },
                            identifier: "settings.autoClean.time")
            }
        }
    }

    /// «Что удаляет»: «Рекомендуемое», or «Мой выбор» with how it differs and «Вернуть рекомендуемое».
    private func modeRow(_ settings: AutoCleanSettings, _ autoClean: AutoCleanModel) -> some View {
        let custom = settings.mode == .custom
        let hint: Text = !custom ? Text("Всё, что сканирование отмечает само")
            : settings.leftOut.isEmpty ? Text("Совпадает с рекомендуемым")
            : Text("Всё рекомендуемое, кроме: \(CategoryList.string(settings.leftOut))")
        return row(text: custom ? Text("Что удаляет: мой выбор") : Text("Что удаляет: рекомендуемое"), symbol: "checklist", hint: hint) {
            if custom {
                SecondaryButton(title: "Вернуть рекомендуемое", height: 30, action: autoClean.useRecommended)
                    .accessibilityIdentifier("settings.autoClean.recommended")
            }
        }
        .accessibilityIdentifier("settings.autoClean.mode")
    }

    private func nextRunHint(_ autoClean: AutoCleanModel) -> Text? {
        guard autoClean.isActive, let next = autoClean.nextRun else { return nil }
        return Text("Следующий запуск: \(next, format: .dateTime.weekday().day().month().hour().minute())")
    }

    private func lastRunText(_ autoClean: AutoCleanModel) -> Text {
        guard let run = autoClean.lastRun else { return Text("Автоочистка ещё не запускалась") }
        return Text("Последний запуск: \(run.date, format: .dateTime.day().month().hour().minute())")
    }

    private func lastRunHint(_ autoClean: AutoCleanModel) -> Text? {
        guard let run = autoClean.lastRun else { return nil }
        return run.skipped > 0
            ? Text("Освобождено \(ByteFormat.string(run.freed)) · пропущено \(run.skipped)")
            : Text("Освобождено \(ByteFormat.string(run.freed))")
    }

    private var helperHint: Text? {
        if case .outdated(let running) = model.helper.status {
            return Text("Запущена старая версия \(running). Обновите помощника, чтобы удаление системных папок работало полностью")
        }
        if model.helper.status == .notResponding {
            return Text("Помощник не отвечает. Переустановите его — macOS попросит разрешить его снова")
        }
        return model.helper.lastError.map { Text(verbatim: $0) }
    }

    @ViewBuilder
    private var exclusions: some View {
        group("Исключения", index: 0) {
            ForEach(Array(model.exclusions.enumerated()), id: \.element) { index, path in
                if index > 0 { divider }
                row(text: Text(verbatim: path.replacingOccurrences(of: NSHomeDirectory(), with: "~")), symbol: "folder") {
                    Button {
                        model.play(.untick)
                        withAnimation(Motion.spring) { model.exclusions.removeAll { $0 == path } }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.hover)
                    .foregroundStyle(palette.faint)
                    .accessibilityLabel("Убрать из исключений")
                    .accessibilityIdentifier("settings.exclusion.remove")
                }
            }
            if !model.exclusions.isEmpty { divider }
            Button(action: addExclusion) {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text("Добавить папку…").font(.system(size: 14))
                    Spacer()
                }
                .foregroundStyle(palette.accentSoft)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.row)
            .accessibilityIdentifier("settings.exclusion.add")
        }
        Text("Сюда не заглядывают ни Сборка мусора, ни Большие файлы, ни Деинсталлятор.")
            .font(.system(size: 12))
            .foregroundStyle(palette.faint)
            .padding(.top, 10)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private var about: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        // The version only: the build number in brackets is for us, not for users.
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        HStack(spacing: 16) {
            AquaIcon().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "MacWashing").font(.system(size: 20, weight: .bold))
                Text("Версия \(version)").font(.system(size: 13)).foregroundStyle(palette.muted)
            }
        }
        .padding(.top, 8)
        group("Программа", index: 0) {
            row("База правил", symbol: "cylinder.split.1x2",
                hint: LocalizedStringKey("\(model.database.ruleCount) правил · \(model.database.appCount) программ")) {
                Text("Версия \(model.database.version)")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
            }
            if let pending = model.rulesUpdates.pending {
                divider
                row(text: Text("Загружена база правил \(pending)"), symbol: "arrow.down.circle",
                    hint: Text("Она начнёт работать после перезапуска")) {
                    SecondaryButton(title: "Перезапустить", height: 30, action: model.restart)
                        .accessibilityIdentifier("settings.rules.restart")
                }
            }
            if model.rulesUpdates.newerLevel != nil {
                divider
                row("Есть новые правила", symbol: "sparkles", hint: "Они требуют новой версии программы") {
                    if model.updates.isAvailable {
                        SecondaryButton(title: "Обновить", height: 30, action: model.updates.checkNow)
                            .accessibilityIdentifier("settings.rules.updateApp")
                    }
                }
            }
            divider
            row("Исходный код", symbol: "chevron.left.forwardslash.chevron.right",
                hint: "MacWashing — свободная программа с открытым кодом (GPL-3.0)") {
                SecondaryButton(title: "GitHub", height: 30) { NSWorkspace.shared.open(AppLinks.repository) }
                    .accessibilityIdentifier("settings.about.source")
            }
            if model.dryRun {
                divider
                row("Тестовый режим", symbol: "testtube.2", hint: "Отладочная сборка: файлы не удаляются") {
                    status("DevMode", ok: false)
                }
            }
        }
    }

    var divider: some View {
        Rectangle().fill(palette.line).frame(height: 1)
    }

    func group<Content: View>(_ title: LocalizedStringKey, index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(palette.faint)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .card(palette)
        }
        .padding(.top, 24)
        .appearIn(delay: 0.06 * Double(index + 1))
    }

    func row<Trailing: View>(_ label: LocalizedStringKey, symbol: String? = nil, hint: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        row(text: Text(label), symbol: symbol, hint: hint.map { Text($0) }, trailing: trailing)
    }

    /// For labels that come from the disk or the system (a folder path, an app name, an error): `Text(verbatim:)`, so a
    /// `%` in them is shown, not parsed as a format.
    func row<Trailing: View>(text label: Text, symbol: String? = nil, hint: Text? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(palette.muted).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                label.font(.system(size: 14))
                if let hint {
                    hint.font(.system(size: 12)).foregroundStyle(palette.faint)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    /// Twelve languages don't fit a segmented control: a capsule that opens a menu of their own names (`AppMenuButton`).
    private var languageMenu: some View {
        AppMenuButton(minWidth: 160) {
            for language in AppModel.languages {
                AppMenuItem(verbatim: language.name, checked: model.language == language.code) {
                    guard model.language != language.code else { return }
                    model.language = language.code
                    model.play(.toggle)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: AppModel.languages.first { $0.code == model.language }?.name ?? model.language)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(palette.field))
            .overlay(Capsule().strokeBorder(palette.cardStroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("settings.language")
    }

    func status(_ text: LocalizedStringKey, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color(hex: 0x34C759) : palette.warning).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13)).foregroundStyle(palette.muted)
        }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Исключить")
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.fsPath).filter { !model.exclusions.contains($0) }
        model.play(.tick)
        withAnimation(Motion.spring) { model.exclusions += paths }
    }
}
