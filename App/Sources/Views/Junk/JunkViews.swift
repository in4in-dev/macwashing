import MacWashingKit
import SwiftUI

extension JunkCategoryID {
    var title: LocalizedStringKey {
        switch self {
        // One category with appCaches after the scan (JunkCategory.mergingCaches); both steps show while scanning.
        case .userCaches: "Кэш программ"
        case .appCaches: "Кэш внутри программ"
        case .installers: "Установщики"
        case .xcode: "Мусор Xcode"
        case .editors: "Мусор редакторов"
        case .projectDependencies: "Зависимости проектов"
        case .userLogs: "Журналы программ"
        case .leftovers: "Остатки программ"
        case .afterRemoval: "Осталось после удаления"
        case .systemLogs: "Системные журналы"
        case .systemCaches: "Системный кэш"
        case .brokenLoginItems: "Сломанные элементы входа"
        }
    }

    /// Same as `title`, as a plain localizable string for composed captions.
    var titleString: String.LocalizationValue {
        switch self {
        case .userCaches: "Кэш программ"
        case .appCaches: "Кэш внутри программ"
        case .installers: "Установщики"
        case .xcode: "Мусор Xcode"
        case .editors: "Мусор редакторов"
        case .projectDependencies: "Зависимости проектов"
        case .userLogs: "Журналы программ"
        case .leftovers: "Остатки программ"
        case .afterRemoval: "Осталось после удаления"
        case .systemLogs: "Системные журналы"
        case .systemCaches: "Системный кэш"
        case .brokenLoginItems: "Сломанные элементы входа"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .userCaches: "Кэши ускоряют запуск программ, но со временем разрастаются до десятков гигабайт. Программы пересоздадут их сами."
        case .appCaches: "Кэши, которые программы держат рядом со своими данными: Chrome, Slack, Discord, Notion, VS Code и другие. Программы создадут их заново сами."
        case .installers: "Образы дисков и пакеты установки, оставшиеся в Загрузках и на Рабочем столе."
        case .xcode: "Промежуточные файлы сборки, данные для отладки старых версий iOS и симуляторы, которые Xcode больше не использует."
        case .editors: "Кэш Final Cut Pro, iMovie, Premiere, After Effects и DaVinci Resolve, превью Lightroom Classic. Ваши фото, видео и проекты не затрагиваются: редакторы сделают эти файлы заново. Кэш оптимизации и кэш Resolve делаются заново долго и только по команде, поэтому сами они не отмечены."
        case .projectDependencies: "Папки node_modules, Pods, .venv и подобные в проектах, которые вы не открывали больше 90 дней. Их можно скачать заново, но на это нужны интернет и время, поэтому сами они не отмечены."
        case .userLogs: "Журналы нужны разработчикам для диагностики ошибок. Для работы программ они не требуются."
        case .leftovers: "Настройки, данные и кэши программ, которых уже нет на Mac. Крупные папки с данными отмечены как «Осторожно»: там могут быть ваши документы."
        case .afterRemoval: "Системные файлы тех же удалённых программ: службы, плагины, утилиты и следы установки."
        case .systemLogs: "Записи системных служб о работе и ошибках. macOS начнёт вести их заново."
        case .systemCaches: "Кэши системных служб. macOS создаст их заново после перезагрузки."
        case .brokenLoginItems: "Фоновые компоненты удалённых программ. Они не работают, но macOS всё ещё пытается их запускать."
        }
    }

    var symbol: String {
        switch self {
        case .userCaches, .systemCaches: "cylinder.split.1x2"
        case .appCaches: "square.stack.3d.up"
        case .installers: "shippingbox"
        case .xcode: "hammer"
        case .editors: "film.stack"
        case .projectDependencies: "puzzlepiece.extension"
        case .userLogs, .systemLogs: "doc.text"
        case .leftovers: "questionmark.folder"
        case .afterRemoval: "shippingbox.and.arrow.backward"
        case .brokenLoginItems: "power"
        }
    }

    var tile: LinearGradient {
        let colors: (UInt32, UInt32) = switch self {
        case .userCaches: (0xFFB36B, 0xEE6A35)
        case .appCaches: (0xFFD66B, 0xE0981F)
        case .installers: (0xC6CDD8, 0x6F7888)
        case .xcode: (0x72B8FF, 0x2B66E6)
        case .editors: (0xFF9ACB, 0xD9408A)
        case .projectDependencies: (0x8FE3A8, 0x2FA35A)
        case .userLogs: (0x9AAEC4, 0x4B5D73)
        case .leftovers: (0xC8AEFF, 0x7A56E8)
        case .afterRemoval: (0xE0A8FF, 0x9B45D6)
        case .systemLogs: (0x8E97A8, 0x474F60)
        case .systemCaches: (0x7CC8FF, 0x2C82DE)
        case .brokenLoginItems: (0xFF9C8C, 0xDE4F47)
        }
        return LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct JunkSectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let junk = model.junk
        ZStack {
            switch junk.phase {
            case .intro:
                IntroScreen(
                    title: "Сборка мусора",
                    text: "Находит кэши, журналы, остатки удалённых программ и мусор Xcode — всё, что можно удалить без вреда для системы.",
                    features: [
                        Feature(symbol: "checkmark.shield", title: "Безопасно по умолчанию", text: "Системные файлы и данные установленных программ защищены правилами базы."),
                        Feature(symbol: "sparkles", title: "Видно, что удаляется", text: "Каждую находку можно раскрыть, проверить и снять с неё галочку."),
                    ],
                    art: .washer,
                    buttonTitle: "Начать сканирование",
                    start: junk.startScan
                ) { EmptyView() }
                .transition(.screen)
            case .scanning, .cleaning, .waitingForApps:
                ProgressScreen(
                    art: .washer,
                    verb: junk.phase == .scanning ? "Ищу мусор" : "Очищаю",
                    progress: junk.progress,
                    amount: junk.phase == .scanning ? ByteFormat.live(max(junk.foundBytes, 1)) : ByteFormat.live(junk.freedBytes),
                    path: junk.currentPath,
                    steps: junk.steps.map { .init(id: $0.id.rawValue, title: $0.id.title, status: .init($0.status), size: $0.size) },
                    stop: junk.cancel
                )
                // «Осталось закрыть программы» is WaitingAppsPanel in RootView: over the whole window like the other
                // dialogs, not clipped to this screen.
                .transition(.screen)
            case .results:
                JunkResultsView()
                    .transition(.screen)
            case .done:
                let report = junk.report ?? CleanReport()
                DoneScreen(
                    freed: ByteFormat.string(report.removedBytes),
                    stats: [
                        (ByteFormat.string(report.removedBytes), String(localized: "освобождено на диске")),
                        ("\(report.removedCount)", String(localized: "объектов удалено")),
                        ("\(report.failures.count)", String(localized: "пропущено")),
                    ],
                    note: junk.skippedForRunningApps.isEmpty ? nil
                        : String(localized: "Пропущено, программы были открыты: \(junk.skippedForRunningApps.joined(separator: ", "))"),
                    failures: report.failures,
                    secondary: junk.autoCleanChoice.map { choice in .init(
                        title: "Настроить автоочистку", identifier: "done.autoClean",
                        action: { model.autoClean.offerSetup(choice: choice) }
                    ) },
                    finish: junk.finish
                )
                .transition(.screen)
            }
        }
        .animation(Motion.screen, value: junk.phase)
    }
}

extension ProgressScreen.Step.Status {
    init(_ status: JunkModel.StepState.Status) {
        self = switch status {
        case .waiting: .waiting
        case .running: .running
        case .done: .done
        }
    }
}

struct JunkResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let junk = model.junk
        ZStack(alignment: .bottom) {
            HStack(spacing: 12) {
                categoryList(junk)
                    .frame(width: 300)
                detail(junk)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 12)

            ActionBar(
                caption: String(localized: "Будет очищено"),
                total: ByteFormat.string(junk.selectedBytes),
                buttonTitle: "Очистить",
                enabled: junk.selectedBytes > 0,
                action: junk.requestClean
            ) { EmptyView() }
        }
    }

    private func categoryList(_ junk: JunkModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                let everything = junk.allChecked
                Button(everything ? "Снять все" : "Выбрать все", action: junk.toggleAll)
                    .buttonStyle(.hover)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentSoft)
                    .accessibilityIdentifier("junk.toggleAll")
                Spacer()
                Text("По размеру").font(.system(size: 12)).foregroundStyle(palette.faint)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)

            let hits = junk.searchHits
            let shown = junk.isSearching ? junk.categories.filter { junk.hitCount(in: $0.id, hits: hits) > 0 } : junk.categories
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, category in
                        categoryRow(category, junk: junk, hits: junk.isSearching ? junk.hitCount(in: category.id, hits: hits) : nil)
                            .appearIn(delay: 0.08 + Double(min(index, 12)) * 0.035)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.never)
            .staggerList()
        }
    }

    private func categoryRow(_ category: JunkCategory, junk: JunkModel, hits: Int?) -> some View {
        let leaves = category.leaves
        let state = junk.state(of: leaves)
        let selectedCount = leaves.filter { junk.checked.contains($0.id) }.count
        let isFocused = hits == nil && junk.focused?.id == category.id
        return HStack(spacing: 4) {
            CheckButton(state: state, label: String(localized: "Выбрать категорию")) { junk.toggle(leaves) }
                .accessibilityIdentifier("junk.category.\(category.id.rawValue).check")
            Button {
                // Picking a category while searching leaves the search for that category.
                if hits != nil { withAnimation(Motion.spring) { junk.search = "" } }
                junk.focus(category.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: category.id.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(category.id.tile))
                        .scaleEffect(isFocused ? 1.06 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.id.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Group {
                            if let hits {
                                Text("Совпадений: \(hits)")
                            } else {
                                Text("\(selectedCount) из \(leaves.count) выбрано")
                            }
                        }
                            .font(.system(size: 12))
                            .foregroundStyle(palette.faint)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("junk.category.\(category.id.rawValue).subtitle")
                    }
                    Spacer(minLength: 4)
                    Text(ByteFormat.string(category.totalSize))
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(state == .off ? palette.faint : palette.text)
                }
                .frame(height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.row)
            .accessibilityIdentifier("junk.category.\(category.id.rawValue)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .hoverRow(selected: isFocused, cornerRadius: 14)
    }

    @ViewBuilder
    private func detail(_ junk: JunkModel) -> some View {
        if junk.isSearching {
            searchDetail(junk)
        } else if let category = junk.focused {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.id.title)
                        .font(.system(size: 26, weight: .bold))
                        .kerning(-0.5)
                        .accessibilityIdentifier("junk.detail.title")
                    Text(category.id.summary)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: 470, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    let leaves = category.leaves
                    let selected = leaves.filter { junk.checked.contains($0.id) }
                    HStack(spacing: 10) {
                        // The category's own «select all», same as its check in the list on the left.
                        Button(junk.state(of: leaves) == .on ? "Снять все" : "Выбрать все") { junk.toggle(leaves) }
                            .buttonStyle(.hover)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.accentSoft)
                            .accessibilityIdentifier("junk.detail.toggleAll")
                        Text("\(selected.count) из \(leaves.count) выбрано · \(ByteFormat.string(selected.reduce(0) { $0 + $1.size }))")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.faint)
                            .monospacedDigit()
                            .accessibilityIdentifier("junk.detail.subtitle")
                        Spacer()
                        Text("По размеру").font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                    .frame(height: 32)
                    .padding(.top, 10)
                    Rectangle().fill(palette.line).frame(height: 1)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .id(category.id)
                .transition(.opacity)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows(for: category, junk: junk).enumerated()), id: \.element.id) { index, row in
                            EntryRow(row: row, junk: junk)
                                .appearIn(delay: 0.1 + Double(min(index, 14)) * 0.028)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 110)
                    .id(category.id)
                }
                .scrollIndicators(.never)
            .staggerList(key: category.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .pane(palette)
        }
    }

    private func searchDetail(_ junk: JunkModel) -> some View {
        let hits = junk.searchHits
        let total = hits.reduce(Int64(0)) { $0 + $1.entry.size }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Результаты поиска")
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                Text("«\(junk.search)» · найдено \(hits.count) · \(ByteFormat.string(total))")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .accessibilityIdentifier("junk.search.summary")
                HStack {
                    let leaves = hits.flatMap(\.entry.leaves)
                    let allOn = !leaves.isEmpty && leaves.allSatisfy { junk.checked.contains($0.id) }
                    Button(allOn ? "Снять найденное" : "Выбрать найденное") { junk.toggle(leaves) }
                        .buttonStyle(.hover)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accentSoft)
                        .disabled(leaves.isEmpty)
                        .accessibilityIdentifier("junk.selectFound")
                    Spacer()
                    Text("По размеру").font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                .frame(height: 32)
                .padding(.top, 10)
                Rectangle().fill(palette.line).frame(height: 1)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)

            if hits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(palette.faint)
                    Text("Ничего не найдено").font(.system(size: 14)).foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            let caption = [String(localized: hit.category.titleString), hit.parent].compactMap { $0 }.joined(separator: " › ")
                            EntryRow(row: Row(entry: hit.entry, depth: 0, caption: caption), junk: junk)
                                .appearIn(delay: 0.05 + Double(min(index, 14)) * 0.02)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 110)
                }
                .scrollIndicators(.never)
                .staggerList(key: junk.search)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pane(palette)
    }

    struct Row: Identifiable {
        let entry: JunkEntry
        let depth: Int
        var caption: String?
        var id: String { entry.id + "/\(depth)" }
    }

    private func rows(for category: JunkCategory, junk: JunkModel) -> [Row] {
        category.entries.flatMap { entry -> [Row] in
            var result = [Row(entry: entry, depth: 0)]
            if !entry.children.isEmpty, junk.expanded.contains(entry.id) {
                result += entry.children.map { Row(entry: $0, depth: 1) }
            }
            return result
        }
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let row: JunkResultsView.Row
    let junk: JunkModel

    var body: some View {
        let entry = row.entry
        let state = junk.state(of: entry.leaves)
        HStack(spacing: 0) {
            CheckButton(state: state, label: entry.title) { junk.toggle(entry.leaves) }
                .accessibilityIdentifier("junk.entry.\(entry.title)")
                .padding(.leading, row.depth == 0 ? -6 : 34)
            EntryIcon(entry: entry)
                .padding(.leading, 8)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if case .developerTools = entry.kind, !entry.children.isEmpty {
                            Text("Инструменты разработчика")
                        } else {
                            Text(entry.title)
                        }
                    }
                    .font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                    if let caption = row.caption {
                        Text(caption).font(.system(size: 12)).foregroundStyle(palette.faint).lineLimit(1)
                    }
                }
                switch entry.ownerNote {
                case .olderVersion?:
                    Pill(text: "Старая версия", color: palette.muted, background: .white.opacity(0.1))
                        .help(Text("Файлы прежних версий этой программы: новая версия ими не пользуется"))
                case .sharedComponent?:
                    Pill(text: "Общий компонент", color: palette.muted, background: .white.opacity(0.1))
                        .help(Text("Библиотека, которую встраивают многие программы разных производителей"))
                case nil:
                    EmptyView()
                }
                if entry.isGray {
                    Pill(text: "Осторожно", color: palette.warning, background: Color(hex: 0xFFB45E, opacity: 0.16))
                }
                if entry.needsPrivileges {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.faint)
                        .help(Text("Удаляется через помощник"))
                }
            }
            .padding(.leading, 12)
            Spacer(minLength: 8)
            if !entry.children.isEmpty {
                let open = junk.expanded.contains(entry.id)
                Button { junk.toggleExpanded(entry) } label: {
                    HStack(spacing: 4) {
                        Text(open ? "Скрыть" : "Показать")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .accessibilityIdentifier("junk.expand.\(entry.title)")
                .padding(.trailing, 10)
            }
            Text(ByteFormat.string(entry.size))
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(state == .off ? palette.faint : palette.text)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .appContextMenu {
            // A group of one owner is not a folder of its own: show the folders in it.
            AppMenuItem("Показать в Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(entry.children.isEmpty ? [entry.url] : entry.leaves.map(\.url))
            }
        }
    }
}

struct EntryIcon: View {
    let entry: JunkEntry

    var body: some View {
        Group {
            switch entry.kind {
            case .app(_, let url?):
                Image(nsImage: IconCache.icon(for: url)).resizable()
            case .vendor(_, let apps) where !apps.isEmpty:
                // The vendor's apps, stacked: there is no vendor icon, but its apps are recognized at once.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(apps.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                        Image(nsImage: IconCache.icon(for: url)).resizable()
                            .frame(width: apps.count == 1 ? 28 : 20, height: apps.count == 1 ? 28 : 20)
                            .offset(x: CGFloat(index) * 4, y: CGFloat(index) * 4)
                    }
                }
                .frame(width: 28, height: 28, alignment: .topLeading)
            case .system:
                Image(nsImage: IconCache.icon(for: URL(filePath: "/System/Library/CoreServices/Finder.app"))).resizable()
            case .developerTools:
                Image(nsImage: IconCache.icon(for: URL(filePath: "/System/Applications/Utilities/Terminal.app"))).resizable()
            default:
                Image(nsImage: IconCache.icon(for: entry.url)).resizable()
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// The end of cleaning when some files belong to open apps: they go the moment an app quits (the user may quit it by
/// hand) and its row leaves the list. Each row has its own «Закрыть» (then «Принудительно» if it is still open after a
/// few seconds); «Закрыть все» asks every app at once, «Не трогать» leaves their files.
struct WaitingAppsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let junk = model.junk
        ZStack {
            Color.black.opacity(0.52)
                .background(.ultraThinMaterial.opacity(0.4))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Text("Осталось закрыть программы")
                    .font(.system(size: 17, weight: .semibold))
                Text("Их файлы сейчас заняты. Как только программа закроется, очистка продолжится сама.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                VStack(spacing: 8) {
                    ForEach(junk.waitingApps) { app in
                        HStack(spacing: 10) {
                            Group {
                                if let url = app.appURL {
                                    Image(nsImage: IconCache.icon(for: url)).resizable()
                                } else {
                                    Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(palette.muted)
                                }
                            }
                            .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).font(.system(size: 14)).lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(ByteFormat.string(app.bytes)).monospacedDigit().foregroundStyle(palette.muted)
                                    if app.stillOpen {
                                        Text("· не закрылась").foregroundStyle(palette.warning)
                                    } else if app.closing {
                                        Text("· закрывается…").foregroundStyle(palette.faint)
                                    }
                                }
                                .font(.system(size: 12))
                                .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            rowAction(app, junk)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("junk.waiting.\(app.id)")
                    }
                }
                .padding(.top, 16)
                Text("Программы, закрытые кнопкой, откроются снова, когда очистка закончится.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                // Once every app was asked and one did not quit (often a save dialog), the same button force-quits
                // the stuck ones; its label is long in Russian, so «Не трогать» narrows to give it room.
                let stuck = junk.someAppStuck && !junk.someAppNotAsked
                HStack(spacing: 10) {
                    Button(action: junk.leaveWaitingApps) {
                        Text("Не трогать")
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: stuck ? 120 : .infinity, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle.rounded(12))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("junk.waiting.leave")
                    Button {
                        if stuck { junk.forceQuitStuckApps() } else { junk.quitWaitingApps() }
                    } label: {
                        Text(stuck ? "Завершить принудительно" : junk.waitingApps.count > 1 ? "Закрыть все" : "Закрыть сейчас")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(HoverFill(color: palette.danger, shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle.rounded(12))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!stuck && !junk.someAppNotAsked)
                    .help(stuck ? Text("Как «Завершить принудительно» в меню Apple: несохранённые изменения пропадут") : Text(verbatim: ""))
                    .accessibilityIdentifier("junk.waiting.quit")
                }
                .animation(Motion.spring, value: stuck)
                .padding(.top, 20)
            }
            .frame(width: 390)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 22)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(palette.sheet))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
        }
        .transition(.opacity)
        .animation(Motion.spring, value: junk.waitingApps.map(\.id))
    }

    /// The row's own button: «Закрыть», a spinner while it closes, «Принудительно» once it did not quit in time.
    @ViewBuilder
    private func rowAction(_ app: JunkModel.WaitingApp, _ junk: JunkModel) -> some View {
        if app.stillOpen {
            Button { junk.forceQuit(app.id) } label: {
                Text("Принудительно")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(HoverFill(color: palette.danger, shape: Capsule()))
                    .contentShape(Capsule())
                    .fixedSize()
            }
            .buttonStyle(PressableStyle.capsule)
            .help(Text("Как «Завершить принудительно» в меню Apple: несохранённые изменения пропадут"))
            .accessibilityIdentifier("junk.waiting.\(app.id).force")
        } else if app.closing {
            ProgressView().controlSize(.small)
                .frame(height: 26)
        } else {
            SecondaryButton(title: "Закрыть", height: 26) { junk.quitWaitingApp(app.id) }
                .accessibilityIdentifier("junk.waiting.\(app.id).quit")
        }
    }
}

struct JunkConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let junk = model.junk
        let rows = junk.categories.compactMap { category -> (JunkCategoryID, Int64)? in
            let bytes = category.leaves.filter { junk.planned.contains($0.id) }.reduce(0) { $0 + $1.size }
            return bytes > 0 ? (category.id, bytes) : nil
        }
        let planned = junk.plannedBytes
        let permanent = model.junkRemoval == .delete
        VStack(spacing: 0) {
            SectionArt(kind: .washer, size: 72)
            Text("Очистить \(ByteFormat.string(planned))?")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 14)
            VStack(spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0.title)
                        Spacer()
                        Text(ByteFormat.string(row.1)).monospacedDigit().foregroundStyle(palette.muted)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(.top, 14)
            Text(permanent ? "Файлы будут удалены без Корзины." : "Файлы будут перемещены в Корзину.")
                .font(.system(size: 12))
                .foregroundStyle(palette.faint)
                .padding(.top, 12)
            let privileged = junk.privilegedCheckedWithoutHelper
            if privileged > 0 {
                NoticeBanner(text: String(localized: "Системных объектов без помощника не удалить: \(privileged). Они будут пропущены."), symbol: "key")
                    .padding(.top, 12)
                    .accessibilityIdentifier("confirm.helperMissing")
            }
            ConfirmButtons(confirmTitle: "Очистить", cancel: junk.cancelConfirm, confirm: junk.clean)
        }
    }
}

/// Before a junk scan without Full Disk Access. «Выдать доступ» opens System Settings ▸ Full Disk Access and the dialog
/// stays: once the app is in front again with the access, it closes and the whole scan starts by itself. «Пропустить»
/// scans without the places macOS asks about (`ScanEnvironment.skipsConsentPlaces`). Esc closes it without scanning.
struct JunkConsentPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let junk = model.junk
        VStack(spacing: 0) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(palette.accent)
            Text("Нужен полный доступ к диску")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 14)
                .accessibilityIdentifier("junk.consent.title")
            Text("Без него MacWashing не может проверить данные других программ, «Загрузки», «Рабочий стол», «Документы» и iCloud Drive.")
                .font(.system(size: 13))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text("Когда доступ будет выдан, сканирование начнётся само. Или пропустите эти места: мусор в них не найдётся.")
                .font(.system(size: 12))
                .foregroundStyle(palette.faint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            ConfirmButtons(confirmTitle: "Выдать доступ", cancelTitle: "Пропустить", destructive: false,
                           cancelID: "junk.consent.skip", confirmID: "junk.consent.fullDiskAccess", cancelOnEscape: false,
                           escape: junk.cancelConsent, confirmKeepsOpen: true,
                           cancel: junk.scanSkippingConsentPlaces, confirm: junk.grantFullDiskAccess)
        }
        // Back from System Settings: the access given there starts the scan.
        .onChange(of: model.isActive) { _, active in
            if active { junk.fullDiskAccessMayHaveChanged() }
        }
    }
}
