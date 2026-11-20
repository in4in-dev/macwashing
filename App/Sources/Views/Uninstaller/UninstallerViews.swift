import MacWashingKit
import SwiftUI

struct UninstallerSectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let uninstaller = model.uninstaller
        ZStack {
            switch uninstaller.phase {
            case .intro:
                IntroScreen(
                    title: "Деинсталлятор",
                    text: "Удаляет программы полностью — вместе с настройками, кэшами и фоновыми компонентами, которые обычно остаются на диске.",
                    features: [
                        Feature(symbol: "square.grid.2x2", title: "Несколько программ за раз", text: "Отмечайте программы целиком или отдельные папки внутри них."),
                        Feature(symbol: "trash", title: "Без остатков", text: "Находит всё, что программа разложила по Mac, даже в скрытых папках."),
                    ],
                    art: .apps,
                    buttonTitle: "Показать программы",
                    start: uninstaller.start
                ) { EmptyView() }
                .transition(.screen)
            case .loading:
                ProgressScreen(
                    art: .apps,
                    verb: "Составляю список программ",
                    progress: uninstaller.progress,
                    amount: String(localized: "Программ: \(uninstaller.loadedCount)"),
                    path: uninstaller.apps.first.map { $0.app.url.deletingLastPathComponent().fsPath } ?? "/Applications",
                    steps: [],
                    stop: uninstaller.backToIntro
                )
                .transition(.screen)
            case .list:
                UninstallerListView()
                    .transition(.screen)
            }
        }
        .animation(Motion.screen, value: uninstaller.phase)
    }
}

struct UninstallerListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let uninstaller = model.uninstaller
        let summary = uninstaller.summary
        ZStack(alignment: .bottom) {
            VStack(spacing: 10) {
                if uninstaller.scannedWithoutFullDiskAccess {
                    NoticeBanner(
                        text: String(localized: "Без полного доступа к диску часть связанных файлов в защищённых папках не найдена — размеры могут быть меньше настоящих."),
                        symbol: "lock.shield",
                        actionTitle: "Открыть Настройки",
                        action: Permissions.requestFullDiskAccess
                    )
                    .accessibilityIdentifier("uninstaller.notice.fullDiskAccess")
                }
                HStack(spacing: 12) {
                    appList(uninstaller)
                        .frame(width: 320)
                    detail(uninstaller)
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 12)

            ActionBar(
                caption: uninstaller.waitingForRelated ? String(localized: "Ищу связанные файлы…") : caption(summary),
                total: ByteFormat.string(summary.bytes),
                buttonTitle: "Удалить",
                // An app ticked before its files were found: «Удалить» waits for them (a second or two).
                // Removing goes on in the queue; what is ticked meanwhile is sent after it.
                enabled: summary.bytes > 0 && !uninstaller.waitingForRelated,
                action: uninstaller.requestUninstall
            ) { EmptyView() }
        }
    }

    private func caption(_ summary: UninstallerModel.Summary) -> String {
        var parts: [String] = []
        if !summary.apps.isEmpty { parts.append(String(localized: "программ: \(summary.apps.count)")) }
        if summary.looseItems > 0 { parts.append(String(localized: "объектов: \(summary.looseItems)")) }
        return parts.isEmpty ? String(localized: "Ничего не выбрано") : String(localized: "Выбрано \(parts.joined(separator: ", "))")
    }

    private func appList(_ uninstaller: UninstallerModel) -> some View {
        VStack(spacing: 0) {
            SegmentedPicker(
                options: [(UninstallerModel.Sort.size, LocalizedStringKey("Размер")), (.name, LocalizedStringKey("Имя")), (.lastUsed, LocalizedStringKey("Запуск"))],
                selection: Binding(get: { uninstaller.sort }, set: { uninstaller.setSort($0) }),
                onChange: { model.play(.navigate) },
                identifier: "uninstaller.sort"
            )
            .padding(.leading, 6)
            .padding(.trailing, 2)

            HStack {
                Button("Выбрать неиспользуемые · \(uninstaller.unused.count)", action: uninstaller.selectUnused)
                    .buttonStyle(.hover)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentSoft)
                    .disabled(uninstaller.unused.isEmpty)
                    .accessibilityIdentifier("uninstaller.selectUnused")
                Spacer()
                if !uninstaller.checked.isEmpty {
                    Button("Снять выбор", action: uninstaller.clearSelection)
                        .buttonStyle(.hover)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .accessibilityIdentifier("uninstaller.clearSelection")
                        .transition(.opacity)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 36)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(uninstaller.sorted.enumerated()), id: \.element.id) { index, entry in
                        appRow(entry, uninstaller: uninstaller)
                            .appearIn(delay: 0.06 + Double(min(index, 14)) * 0.024)
                    }
                    if uninstaller.sorted.isEmpty {
                        Text("Ничего не найдено")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.muted)
                            .padding(.top, 24)
                    }
                }
                .padding(.bottom, 110)
            }
            .scrollIndicators(.never)
            .staggerList()
        }
    }

    private func appRow(_ entry: UninstallerModel.AppEntry, uninstaller: UninstallerModel) -> some View {
        let state = uninstaller.state(of: entry.id)
        let focused = uninstaller.focused?.id == entry.id
        let usage = RelativeDate.lastUsed(entry.app.lastUsed ?? entry.app.approximateLastUsed, approximate: entry.dateIsApproximate)
        let removal = uninstaller.removalState(of: entry.id)
        return HStack(spacing: 4) {
            if removal != nil {
                // In the queue: its check is not to be changed; the ring on the right says where it is.
                Color.clear.frame(width: 32, height: 32)
            } else if uninstaller.isLocked(entry) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
                    .frame(width: 32, height: 32)
                    .help(Text("Системная программа"))
            } else {
                CheckButton(state: state, label: entry.app.name) { uninstaller.toggleApp(entry.id) }
                    .accessibilityIdentifier("uninstaller.app.\(entry.app.name).check")
            }
            Button { uninstaller.focus(entry.id) } label: {
                HStack(spacing: 12) {
                    Image(nsImage: IconCache.icon(for: entry.iconURL))
                        .resizable()
                        .frame(width: 36, height: 36)
                        .scaleEffect(focused ? 1.06 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.app.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            if removal == .removing {
                                Text("Удаляется…")
                            } else if removal == .waiting {
                                Text("В очереди на удаление")
                            } else if entry.isRunning {
                                Circle().fill(Color(hex: 0x34C759)).frame(width: 6, height: 6)
                                Text("Запущена")
                            } else if entry.app.isSystem {
                                Text("Системная программа")
                            } else if !(entry.tool?.dependents.isEmpty ?? true) {
                                Text("Нужна другим утилитам")
                            } else {
                                Text(usage.text)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(entry.isUnused || entry.neverOpened ? palette.warning : palette.faint)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let removal {
                        RemovalRing(waiting: removal == .waiting) { uninstaller.cancelRemoval(entry.id) }
                            .accessibilityIdentifier("uninstaller.app.\(entry.app.name).removal")
                    } else if let size = entry.size {
                        Text(ByteFormat.string(size))
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(state == .off ? palette.muted : palette.text)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.row)
            .accessibilityIdentifier("uninstaller.app.\(entry.app.name)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .hoverRow(selected: focused)
    }

    @ViewBuilder
    private func detail(_ uninstaller: UninstallerModel) -> some View {
        if let entry = uninstaller.focused {
            let items = uninstaller.items(of: entry.id)
            let state = uninstaller.state(of: entry.id)
            let appChecked = items.contains { $0.isApplicationBundle && uninstaller.checked.contains($0.id) }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 18) {
                        Image(nsImage: IconCache.icon(for: entry.iconURL))
                            .resizable()
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.app.name)
                                .font(.system(size: 26, weight: .bold))
                                .kerning(-0.5)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(versionLine(entry))
                                .font(.system(size: 13))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        modePill(entry: entry, state: state, appChecked: appChecked)
                    }

                    HStack(spacing: 10) {
                        stat("Всего", items.isEmpty ? (entry.size.map(ByteFormat.string) ?? "—") : ByteFormat.string(items.reduce(0) { $0 + $1.size }))
                        stat("Программа", entry.size.map(ByteFormat.string) ?? "—")
                        stat("Данные и кэши", ByteFormat.string(items.filter { !$0.isApplicationBundle }.reduce(0) { $0 + $1.size }))
                        stat("Последний запуск", lastRunShort(entry))
                    }
                    .padding(.top, 22)

                    if let note = note(for: entry) {
                        Label(note.text, systemImage: note.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xFFD3A0))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xFFC27A, opacity: 0.12)))
                            .padding(.top, 12)
                    }

                    HStack {
                        Text("Состав · \(items.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(palette.faint)
                            .accessibilityIdentifier("uninstaller.itemCount")
                        Spacer()
                        if !uninstaller.isLocked(entry), uninstaller.removalState(of: entry.id) == nil, !items.isEmpty {
                            // Literally everything the user may tick, «Возможно» items too (the app's check above takes
                            // only the sure ones); shared items still go only with the other apps using them.
                            Button(uninstaller.hasEverything(entry.id) ? "Снять всё" : "Выбрать всё") { uninstaller.toggleEverything(entry.id) }
                                .buttonStyle(.hover)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.accentSoft)
                                .accessibilityIdentifier("uninstaller.toggleFocused")
                        }
                    }
                    .frame(height: 32)
                    .padding(.top, 16)
                    Rectangle().fill(palette.line).frame(height: 1)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)

                if items.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                itemRow(item, entry: entry, uninstaller: uninstaller)
                                    .appearIn(delay: 0.06 + Double(min(index, 12)) * 0.03)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 110)
                        .id(entry.id)
                    }
                    .scrollIndicators(.never)
            .staggerList(key: entry.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .pane(palette)
            .id(entry.id)
            .transition(.opacity)
        }
    }

    private func itemRow(_ item: RelatedItem, entry: UninstallerModel.AppEntry, uninstaller: UninstallerModel) -> some View {
        let on = uninstaller.checked.contains(item.id)
        let home = model.home.fsPath
        return HStack(spacing: 0) {
            if uninstaller.removalState(of: entry.id) != nil {
                Color.clear.frame(width: 32, height: 32).padding(.leading, -6)
            } else if uninstaller.isLocked(entry) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
                    .frame(width: 32, height: 32)
                    .padding(.leading, -6)
            } else {
                CheckButton(state: on ? .on : .off, label: item.url.lastPathComponent) { uninstaller.toggleItem(item) }
                    .accessibilityIdentifier("uninstaller.item.\(item.location)/\(item.url.lastPathComponent)")
                    .padding(.leading, -6)
            }
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: 28, height: 28)
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.url.lastPathComponent).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                    if item.isLikely {
                        Pill(text: "Возможно", color: palette.warning, background: Color(hex: 0xFFB45E, opacity: 0.16))
                            .help(item.likelyReason.hint)
                    }
                }
                Text(item.location.replacingOccurrences(of: home, with: "~"))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            Spacer(minLength: 8)
            if item.needsPrivileges {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
                    .help(Text("Удаляется через помощник"))
                    .padding(.trailing, 8)
            }
            Text(ByteFormat.string(item.size))
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(on ? palette.text : palette.faint)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .appContextMenu {
            AppMenuItem("Показать в Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Four equal cards on a narrow window: a long label or value («Последний запуск», «11 мес. назад») shrinks a
            // little instead of being cut off.
            Text(label).font(.system(size: 11)).foregroundStyle(palette.faint).lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card(palette, radius: 12)
    }

    private func modePill(entry: UninstallerModel.AppEntry, state: CheckState, appChecked: Bool) -> some View {
        let (text, color, background): (LocalizedStringKey, Color, Color) =
            if model.uninstaller.removalState(of: entry.id) == .removing { ("Удаляется…", Color(hex: 0xFF9EA0), palette.danger.opacity(0.18)) }
            else if model.uninstaller.removalState(of: entry.id) == .waiting { ("В очереди на удаление", palette.warning, Color(hex: 0xFFB45E, opacity: 0.16)) }
            else if entry.app.isSystem { ("Защищена", palette.muted, palette.field) }
            else if state == .on { ("Удаляется полностью", Color(hex: 0xFF9EA0), palette.danger.opacity(0.18)) }
            else if appChecked { ("Удаляется, часть файлов останется", palette.warning, Color(hex: 0xFFB45E, opacity: 0.16)) }
            else if state == .mixed { ("Только выбранные папки", palette.accentSoft, palette.accent.opacity(0.18)) }
            else { ("Не выбрана", palette.muted, palette.field) }
        return Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .accessibilityIdentifier("uninstaller.modePill")
            .animation(Motion.spring, value: state)
    }

    private func versionLine(_ entry: UninstallerModel.AppEntry) -> String {
        var parts = entry.app.version.isEmpty ? [] : [String(localized: "Версия \(entry.app.version)")]
        if let vendor = entry.app.vendor { parts.append(vendor) }
        if entry.tool != nil, entry.tool?.isHomebrew != true { parts.append(String(localized: "Установлена отдельным установщиком")) }
        return parts.joined(separator: " · ")
    }

    private func lastRunShort(_ entry: UninstallerModel.AppEntry) -> String {
        if entry.isRunning { return String(localized: "Сейчас") }
        guard let days = entry.shownDaysUnused else { return String(localized: "Никогда") }
        let mark = entry.dateIsApproximate ? "≈ " : ""
        if days == 0 { return mark + String(localized: "Сегодня") }
        if days < 30 { return mark + String(localized: "\(days) дн. назад") }
        if days < 365 { return mark + String(localized: "\(days / 30) мес. назад") }
        return mark + String(localized: "\(days / 365) г. назад")
    }

    private func note(for entry: UninstallerModel.AppEntry) -> (text: String, symbol: String)? {
        if entry.app.isSystem { return (String(localized: "Системные программы Apple защищены macOS и не удаляются."), "lock") }
        let broken = model.uninstaller.breaking(entry)
        if !broken.isEmpty {
            let names = broken.prefix(4).joined(separator: ", ") + (broken.count > 4 ? "…" : "")
            return (String(localized: "Без неё перестанут работать: \(names). Удалить её всё равно можно."), "exclamationmark.triangle")
        }
        if let tool = entry.tool, entry.isRunning {
            return (String(localized: "\(tool.name) сейчас работает в фоне — перед удалением служба будет остановлена."), "exclamationmark.triangle")
        }
        if entry.isRunning { return (String(localized: "\(entry.app.name) сейчас запущена — перед удалением программа будет закрыта."), "exclamationmark.triangle") }
        if entry.isUnused { return (String(localized: "\(RelativeDate.lastUsed(entry.app.lastUsed).text) — возможно, она больше не нужна."), "clock") }
        return nil
    }
}

struct UninstallConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let uninstaller = model.uninstaller
        let summary = uninstaller.summary
        let touched = uninstaller.touched
        VStack(spacing: 0) {
            HStack(spacing: -16) {
                ForEach(Array(touched.prefix(3).enumerated()), id: \.element.id) { index, entry in
                    Image(nsImage: IconCache.icon(for: entry.iconURL))
                        .resizable()
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(touched.count == 1 ? 0 : Double(index - 1) * 7))
                        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
                        .appearIn(delay: Double(index) * 0.07, offset: 12)
                }
            }
            .frame(height: 64)
            Text(title(summary, touched: touched))
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityIdentifier("confirm.title")
            Text(message(touched: touched, bytes: summary.bytes))
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            let broken = uninstaller.brokenBySelection
            if !broken.isEmpty {
                let names = broken.prefix(6).joined(separator: ", ") + (broken.count > 6 ? "…" : "")
                NoticeBanner(
                    text: String(localized: "Перестанут работать: \(names). Им нужны удаляемые утилиты Homebrew."),
                    symbol: "exclamationmark.triangle"
                )
                .padding(.top, 12)
                .accessibilityIdentifier("confirm.brokenFormulae")
            }
            let privileged = uninstaller.privilegedCheckedWithoutHelper
            if privileged > 0 {
                NoticeBanner(
                    text: String(localized: "Системных объектов без помощника не удалить: \(privileged). Они будут пропущены."),
                    symbol: "key"
                )
                .padding(.top, 12)
                .accessibilityIdentifier("confirm.helperMissing")
            }
            ConfirmButtons(confirmTitle: "Удалить", cancel: uninstaller.cancelConfirm, confirm: uninstaller.uninstall)
        }
    }

    private func title(_ summary: UninstallerModel.Summary, touched: [UninstallerModel.AppEntry]) -> String {
        if summary.apps.count == 1 && summary.looseItems == 0 { return String(localized: "Удалить \(summary.apps[0].app.name)?") }
        if summary.apps.isEmpty { return String(localized: "Удалить выбранные папки: \(summary.looseItems)?") }
        if summary.looseItems == 0 { return String(localized: "Удалить программы: \(summary.apps.count)?") }
        return String(localized: "Удалить программы (\(summary.apps.count)) и папки (\(summary.looseItems))?")
    }

    /// The Uninstaller removes for good, whatever Settings say about the Trash.
    private func message(touched: [UninstallerModel.AppEntry], bytes: Int64) -> String {
        var names = touched.prefix(3).map(\.app.name).joined(separator: ", ")
        if touched.count > 3 { names += String(localized: " и ещё \(touched.count - 3)") }
        let size = ByteFormat.string(bytes)
        return String(localized: "\(names) — \(size) будет удалено без возможности восстановления.")
    }
}

extension RelatedItem.LikelyReason {
    /// Why a "Возможно" item is not checked.
    var hint: Text {
        switch self {
        case .nameOnly: Text("Найдено только по имени папки. Проверьте перед удалением")
        case .userData: Text("Лежит вне Library: там могут быть ваши файлы. Проверьте перед удалением")
        case .appData: Text("Здесь программа хранит ваши данные: модели, образы дисков, библиотеки. Проверьте перед удалением")
        }
    }
}

/// Where an app in the removal queue is: a spinning ring while it goes, and while it waits a ring with a cross that takes
/// it off the queue (nothing of it was touched yet).
struct RemovalRing: View {
    let waiting: Bool
    let cancel: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            ProgressView().controlSize(.small)
            if waiting {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text("Не удалять"))
            }
        }
        .frame(width: 28, height: 28)
    }
}
