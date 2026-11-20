import MacWashingKit
import SwiftUI
import UniformTypeIdentifiers

struct DiskSectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        let chosen = disk.chosen
        ZStack(alignment: .bottom) {
            HStack(spacing: 12) {
                if disk.showsPlaces {
                    PlacesList()
                        .frame(width: 200)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 0) {
                    DiskHeader()
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                    DiskToolbar()
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    Rectangle().fill(palette.line).frame(height: 1)
                        .padding(.horizontal, 16)
                    DiskContent()
                    PathBar()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .pane(palette)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 12)

            if !chosen.isEmpty {
                let size = disk.size(of: chosen)
                let enabled = disk.canDelete(chosen)
                ActionBar(
                    caption: String(localized: "Выбрано: \(chosen.count)"),
                    total: size.pending && size.bytes == 0 ? "…" : DiskFormat.size(size.bytes) + (size.pending ? "…" : ""),
                    buttonTitle: disk.removalMode == .trash ? "В Корзину" : "Удалить",
                    enabled: enabled,
                    action: { disk.requestDelete(chosen) }
                ) {
                    if !enabled {
                        if disk.needsMissingHelper(chosen) {
                            Button(action: model.openHelperSettings) {
                                Label("Нужен помощник", systemImage: "key")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.muted)
                            }
                            .buttonStyle(.hover)
                            .help(Text("Вне папки пользователя удаляет помощник с правами администратора. Установите его в Настройках."))
                            .accessibilityIdentifier("disk.needsHelper")
                        } else {
                            Label("Защищено от удаления", systemImage: "lock")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.muted)
                                .accessibilityIdentifier("disk.protected")
                        }
                    }
                }
                // Above the path bar along the bottom of the browser.
                .padding(.bottom, 30)
            }
        }
        .animation(Motion.spring, value: chosen.isEmpty)
        .animation(Motion.spring, value: disk.showsPlaces)
        // The source list folds away when the window gets narrow, and comes back when it is wide again.
        .onGeometryChange(for: Bool.self) { $0.size.width < 820 } action: { narrow in disk.showsPlaces = !narrow }
        .background { DiskShortcuts() }
        .onAppear { disk.appear() }
        .onDisappear { disk.disappear() }
    }
}

/// The source list of the section, laid out as Finder's sidebar: «Избранное»; «Места» with the home folder, iCloud
/// Drive and the Trash; and last «Диски», every volume with its free space and an eject button when it can be ejected.
private struct PlacesList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        let current = disk.currentPlace?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !disk.favorites.isEmpty {
                    caption("Избранное")
                    ForEach(disk.favorites) { place in
                        PlaceRow(place: place, selected: current == place.id) { disk.open(place) }
                    }
                }
                caption("Места")
                    .padding(.top, disk.favorites.isEmpty ? 0 : 14)
                ForEach(disk.locations) { place in
                    PlaceRow(place: place, selected: current == place.id) { disk.open(place) }
                }
                caption("Диски")
                    .padding(.top, 14)
                ForEach(disk.disks) { place in
                    let volume = place.volume
                    PlaceRow(place: place, selected: current == place.id, open: { disk.open(place) },
                             eject: volume.flatMap { volume in volume.isEjectable ? { disk.eject(volume) } : nil },
                             ejecting: disk.ejections.contains(place.id))
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 110)
            .animation(Motion.spring, value: disk.disks.map(\.id))
        }
        .scrollIndicators(.never)
    }

    private func caption(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(palette.faint)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }
}

private struct PlaceRow: View {
    @Environment(\.palette) private var palette
    let place: StoragePlace
    let selected: Bool
    let open: () -> Void
    var eject: (() -> Void)?
    /// Being ejected: the row stays, but takes no clicks and shows a spinner in place of its eject button.
    var ejecting = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.accentSoft)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if place.volume?.isReadOnly == true {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(palette.faint)
                                .help(Text("Только для чтения"))
                        }
                    }
                    if let volume = place.volume, volume.totalBytes > 0 {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                Capsule().fill(palette.disk)
                                    .frame(width: proxy.size.width * Double(volume.usedBytes) / Double(max(volume.totalBytes, 1)))
                            }
                        }
                        .frame(height: 3)
                        .help(Text("Свободно \(ByteFormat.string(volume.availableBytes)) из \(ByteFormat.string(volume.totalBytes))"))
                        Text("Свободно \(ByteFormat.string(volume.availableBytes))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.faint)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, eject == nil ? 10 : 32)
            .padding(.vertical, place.volume == nil ? 0 : 7)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .hoverRow(selected: selected, cornerRadius: 9)
        }
        .buttonStyle(.row)
        .disabled(ejecting)
        .help(place.url.fsPath)
        .accessibilityIdentifier("disk.place.\(identifier)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .trailing) {
            // Outside the row's button: a button inside a button would swallow the click.
            if ejecting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .padding(.trailing, 6)
                    .accessibilityIdentifier("disk.ejecting.\(identifier)")
            } else if let eject {
                Button(action: eject) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .padding(.trailing, 6)
                .help(Text("Извлечь"))
                .accessibilityLabel(Text("Извлечь"))
                .accessibilityIdentifier("disk.eject.\(identifier)")
            }
        }
        .appContextMenu {
            AppMenuItem("Показать в Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([place.url]) }
            if let eject {
                AppMenuItem("Извлечь", symbol: "eject", enabled: !ejecting, action: eject)
            }
        }
    }

    /// The Trash folder has no localized name of its own (`displayName` gives «.Trash»).
    private var title: String {
        place.kind == .trash ? String(localized: "Корзина") : place.title
    }

    private var symbol: String {
        switch place.kind {
        case .applications: "a.square"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .home: "house"
        case .iCloud: "icloud"
        case .trash: "trash"
        case .volume:
            if place.volume?.isNetwork == true { "network" }
            else if place.volume?.isEjectable == true { "externaldrive" }
            else { "internaldrive" }
        }
    }

    /// Stable name for UI tests: the kind, and the volume's position for disks.
    private var identifier: String {
        switch place.kind {
        case .applications: "applications"
        case .desktop: "desktop"
        case .documents: "documents"
        case .downloads: "downloads"
        case .home: "home"
        case .iCloud: "iCloud"
        case .trash: "trash"
        case .volume: place.volume?.isStartup == true ? "startup" : "volume.\(place.title)"
        }
    }
}

/// The folder shown, in large type; in the Trash itself, «Очистить корзину» on the right.
private struct DiskHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = model.disk
        HStack(spacing: 12) {
            Text(disk.title(of: disk.folder))
                .font(.system(size: 26, weight: .bold))
                .kerning(-0.5)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .accessibilityIdentifier("disk.title")
            Spacer(minLength: 0)
            if disk.isTrashRoot {
                let enabled = disk.canEmptyTrash
                SecondaryButton(title: "Очистить корзину", height: 30, action: disk.requestEmptyTrash)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.45)
                    .help(Text("Удалить всё, что лежит в Корзине, безвозвратно"))
                    .accessibilityIdentifier("disk.emptyTrash")
            }
        }
    }
}

/// Source list, back, forward and up on the left; the view mode, sorting, hidden files and refresh on the right.
private struct DiskToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        HStack(spacing: 2) {
            navButton("sidebar.left", label: "Боковая панель", id: "disk.places", enabled: true) {
                withAnimation(Motion.spring) { disk.showsPlaces.toggle() }
            }
            .padding(.trailing, 6)
            navButton("chevron.left", label: "Назад", id: "disk.back", enabled: !disk.backStack.isEmpty, action: disk.goBack)
                .keyboardShortcut("[", modifiers: .command)
            navButton("chevron.right", label: "Вперёд", id: "disk.forward", enabled: !disk.forwardStack.isEmpty, action: disk.goForward)
                .keyboardShortcut("]", modifiers: .command)
            navButton("arrow.up", label: "На уровень выше", id: "disk.up", enabled: disk.canGoUp, action: disk.goUp)
                .keyboardShortcut(.upArrow, modifiers: .command)
            Spacer(minLength: 12)
            ViewModePicker()
            if disk.largeRows {
                SortMenu()
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                ToggleSwitch(
                    isOn: Binding(get: { disk.showsHidden }, set: { disk.setShowsHidden($0) }),
                    label: "Скрытые файлы"
                ) { model.play(.toggle) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .accessibilityIdentifier("disk.hidden")
                Text("Скрытые файлы").font(.system(size: 13)).foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            navButton("arrow.clockwise", label: "Обновить", id: "disk.refresh", enabled: !disk.loading, action: disk.refresh)
                .keyboardShortcut("r", modifiers: .command)
                .padding(.leading, 4)
        }
        .animation(Motion.spring, value: disk.largeRows)
    }

    private func navButton(_ symbol: String, label: LocalizedStringKey, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .foregroundStyle(enabled ? palette.muted : palette.faint.opacity(0.5))
        .disabled(!enabled)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}

/// List (the table) or large rows, drawn like the app's segmented control.
private struct ViewModePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Namespace private var namespace

    var body: some View {
        let disk = model.disk
        HStack(spacing: 2) {
            segment("list.bullet", label: "Список", id: "disk.view.list", on: !disk.largeRows) { disk.setLargeRows(false) }
            segment("rectangle.grid.1x2", label: "Крупно", id: "disk.view.large", on: disk.largeRows) { disk.setLargeRows(true) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.field))
    }

    private func segment(_ symbol: String, label: LocalizedStringKey, id: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !on else { return }
            withAnimation(Motion.spring) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? palette.text : palette.muted)
                .frame(width: 32, height: 26)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.14))
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            .matchedGeometryEffect(id: "segment", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Sorting for the large rows, which have no column headers: the same `DiskSort` the table's headers set.
private struct SortMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        AppMenuButton {
            for key in [DiskSort.Key.name, .size, .modified] {
                AppMenuItem(title(key), checked: disk.sort.key == key) { setKey(key) }
            }
            AppMenuDivider()
            AppMenuItem("По возрастанию", checked: disk.sort.ascending) { disk.sort.ascending = true }
            AppMenuItem("По убыванию", checked: !disk.sort.ascending) { disk.sort.ascending = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                Text(title(disk.sort.key)).font(.system(size: 13))
            }
            .foregroundStyle(palette.muted)
        }
        .buttonStyle(.hover)
        .fixedSize()
        .help(Text("Сортировка"))
        .accessibilityIdentifier("disk.sort")
    }

    private func title(_ key: DiskSort.Key) -> LocalizedStringKey {
        switch key {
        case .name: "Имя"
        case .size: "Размер"
        case .modified: "Изменён"
        }
    }

    /// A newly chosen size or date starts with the biggest and newest, as the table's headers do.
    private func setKey(_ key: DiskSort.Key) {
        let disk = model.disk
        guard key != disk.sort.key else { return }
        model.play(.navigate)
        disk.sort = DiskSort(key: key, ascending: key == .name)
    }
}

/// Finder's path bar and status bar in one thin strip along the bottom: the volume and every folder down to the one
/// shown (the middle ones fold into «…» when they do not fit), then what is in the folder and how big it is.
private struct PathBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        let trail = disk.trail
        HStack(spacing: 12) {
            // Its own view, compared by value: the summary on the right changes every few hundred milliseconds while
            // sizes come in, the crumbs only when the folder does.
            PathCrumbs(trail: trail, titles: trail.map(disk.title(of:)))
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if disk.measuring || disk.loading {
                    ProgressView().controlSize(.mini).tint(palette.accent)
                        .accessibilityIdentifier("disk.measuring")
                        .help(Text("Считаю размеры…"))
                }
                Text(summary(disk))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .accessibilityIdentifier("disk.summary")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.muted)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        .animation(Motion.spring, value: disk.measuring)
    }

    private func summary(_ disk: DiskModel) -> String {
        let size = DiskFormat.size(disk.total.bytes)
        return !disk.showsHidden && disk.hiddenCount > 0
            ? String(localized: "Объектов: \(disk.itemCount) · \(size) · скрытых: \(disk.hiddenCount)")
            : String(localized: "Объектов: \(disk.itemCount) · \(size)")
    }
}

/// The folders from the volume's root to the one shown. Only one arrangement is built: the longest of
/// `DiskBrowser.pathVariants` whose measured width fits (all of them inside a ViewThatFits, each with its menu, made
/// every folder change and every size update slow).
private struct PathCrumbs: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let trail: [URL]
    let titles: [String]
    @State private var available: CGFloat = 0

    nonisolated static func == (a: PathCrumbs, b: PathCrumbs) -> Bool { a.trail == b.trail && a.titles == b.titles }

    var body: some View {
        // The crumbs sit in an overlay: whatever their width, they never widen the bar (and so the pane and its table).
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { available = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in available = width }
            })
            .overlay(alignment: .leading) { crumbs(variant) }
            .clipped()
    }

    private var variant: [Int?] {
        let variants = DiskBrowser.pathVariants(count: trail.count)
        guard available > 0 else { return variants.last ?? [] }
        // A little room for what the estimate leaves out (hover insets, rounding).
        return variants.first { width(of: $0) + 12 <= available } ?? variants.last ?? []
    }

    /// The crumbs' width as `crumbs` lays them out: icon 14 + 4 + text + 6 of padding; chevrons and spacing; «…».
    private func width(of variant: [Int?]) -> CGFloat {
        var total: CGFloat = 0
        for (position, index) in variant.enumerated() {
            if position > 0 { total += 3 + 9 + 3 }
            if let index {
                let weight: NSFont.Weight = index == trail.count - 1 ? .semibold : .regular
                let text = (titles[index] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: weight)]).width
                total += 14 + 4 + ceil(text) + 6
            } else {
                total += 18
            }
        }
        return total
    }

    private func crumbs(_ variant: [Int?]) -> some View {
        let disk = model.disk
        let shown = Set(variant.compactMap { $0 })
        let folded = trail.indices.filter { !shown.contains($0) }
        return HStack(spacing: 3) {
            ForEach(Array(variant.enumerated()), id: \.offset) { position, index in
                if position > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.faint)
                }
                if let index {
                    crumb(trail[index], title: titles[index], index: index, current: index == trail.count - 1)
                } else {
                    // The folded folders stay reachable from a menu.
                    AppMenuButton {
                        for index in folded {
                            AppMenuItem(verbatim: titles[index], symbol: "folder") { disk.navigate(to: trail[index]) }
                        }
                    } label: {
                        Text(verbatim: "…").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.muted)
                    }
                    .buttonStyle(.hover)
                    .fixedSize()
                }
            }
        }
        .fixedSize()
    }

    private func crumb(_ url: URL, title: String, index: Int, current: Bool) -> some View {
        Button { model.disk.navigate(to: url) } label: {
            HStack(spacing: 4) {
                Image(nsImage: DiskIcons.folder(url))
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11.5, weight: current ? .semibold : .regular))
            .foregroundStyle(current ? palette.text : palette.muted)
            .padding(.horizontal, 3)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .disabled(current)
        .accessibilityIdentifier("disk.path.\(index)")
    }
}

/// The table, or what to show when there is nothing to list.
private struct DiskContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        if disk.unreadable {
            placeholder(symbol: "lock", title: "Нет доступа к этой папке", text: "Разрешите MacWashing полный доступ к диску, чтобы видеть её содержимое.") {
                SecondaryButton(title: "Открыть Настройки", height: 30, action: Permissions.requestFullDiskAccess)
                    .padding(.top, 6)
            }
        } else if disk.rows.isEmpty && disk.loading {
            ProgressView().controlSize(.small).tint(palette.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if disk.rows.isEmpty {
            placeholder(symbol: "folder", title: "Папка пуста", text: disk.hiddenCount > 0 ? "Здесь только скрытые файлы." : nil) { EmptyView() }
        } else if disk.largeRows {
            DiskLargeList()
                .transition(.opacity)
        } else {
            DiskTable()
                .transition(.opacity)
        }
    }

    private func placeholder<Extra: View>(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey?, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(palette.faint)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.muted)
            if let text {
                Text(text).font(.system(size: 12)).foregroundStyle(palette.faint).multilineTextAlignment(.center)
            }
            extra()
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("disk.placeholder")
        .transition(.opacity)
    }
}

/// Native table: sortable columns, Cmd/Shift multi-selection, arrow keys and the system context menu.
private struct DiskTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var disk = model.disk
        let total = disk.total.bytes
        Table(disk.shownRows, selection: $disk.selection, sortOrder: sortOrder) {
            TableColumn("Имя", value: \DiskRow.name) { row in
                NameCell(row: row, protected: !row.entry.isParentLink && disk.isProtected(row.entry))
            }
            .width(min: 160, ideal: 260)
            TableColumn("Размер", value: \DiskRow.bytes) { row in
                SizeCell(row: row, total: total)
            }
            .width(min: 110, ideal: 130, max: 220)
            TableColumn("Изменён", value: \DiskRow.modified) { row in
                Text(row.entry.isParentLink ? "" : row.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .opacity(row.entry.isHidden ? DiskRowStyle.hiddenOpacity : 1)
            }
            .width(min: 110, ideal: 140, max: 200)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        // Room for the action bar floating over the last rows.
        .contentMargins(.bottom, disk.chosen.isEmpty ? 8 : 96, for: .scrollContent)
        .contextMenu(forSelectionType: String.self) { ids in
            DiskMenu(ids: ids)
        } primaryAction: { ids in
            disk.open(ids: ids)
        }
        // ⌫ (and ⌦) while the table has focus, as in Finder; the search field keeps its own ⌫.
        .onDeleteCommand { disk.requestDelete(disk.chosen) }
        .accessibilityIdentifier("disk.table")
    }

    /// The table's sort descriptor, mapped onto `DiskSort` (which the kit sorts by).
    private var sortOrder: Binding<[KeyPathComparator<DiskRow>]> {
        let disk = model.disk
        return Binding {
            let order: SortOrder = disk.sort.ascending ? .forward : .reverse
            return switch disk.sort.key {
            case .name: [KeyPathComparator(\DiskRow.name, order: order)]
            case .size: [KeyPathComparator(\DiskRow.bytes, order: order)]
            case .modified: [KeyPathComparator(\DiskRow.modified, order: order)]
            }
        } set: { comparators in
            guard let comparator = comparators.first else { return }
            let key: DiskSort.Key = comparator.keyPath == \DiskRow.name ? .name : comparator.keyPath == \DiskRow.modified ? .modified : .size
            // A newly chosen size or date column starts with the biggest and newest, as in Finder.
            let ascending = key != disk.sort.key && key != .name ? false : comparator.order == .forward
            model.play(.navigate)
            disk.sort = DiskSort(key: key, ascending: ascending)
        }
    }
}

/// Large rows, the way the other sections list what they found: a big icon, the name with its date, the share bar and
/// the size in large type. A native `List`, so it stays lazy with tens of thousands of items and keeps the table's
/// Cmd/Shift selection, arrow keys, Return, context menu and double-click.
private struct DiskLargeList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var disk = model.disk
        let total = disk.total.bytes
        List(disk.shownRows, selection: $disk.selection) { row in
            LargeRow(row: row, total: total, protected: !row.entry.isParentLink && disk.isProtected(row.entry))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, disk.chosen.isEmpty ? 8 : 96, for: .scrollContent)
        .contextMenu(forSelectionType: String.self) { ids in
            DiskMenu(ids: ids)
        } primaryAction: { ids in
            disk.open(ids: ids)
        }
        .onDeleteCommand { disk.requestDelete(disk.chosen) }
        .accessibilityIdentifier("disk.table")
    }
}

private struct LargeRow: View {
    @Environment(\.palette) private var palette
    let row: DiskRow
    let total: Int64
    let protected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: DiskIcons.icon(for: row.entry))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if protected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.faint)
                            .help(Text("Защищено от удаления"))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("disk.row.\(row.name)")
                Text(row.entry.isParentLink ? String(localized: "На уровень выше") : row.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            Spacer(minLength: 12)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                if let size = row.size, total > 0, size.bytes > 0 {
                    Capsule().fill(palette.disk)
                        .frame(width: max(3, 96 * min(Double(size.bytes) / Double(total), 1)))
                }
            }
            .frame(width: 96, height: 5)
            .opacity(row.size == nil ? 0 : 1)
            Group {
                if row.isPending {
                    ProgressView().controlSize(.small).tint(palette.accent)
                        .accessibilityLabel(Text("Считаю размер…"))
                } else {
                    Text(row.entry.isParentLink ? "" : DiskFormat.text(row.size))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(width: 96, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("disk.size.\(row.name)")
        }
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .opacity(row.entry.isHidden ? DiskRowStyle.hiddenOpacity : 1)
        .contentShape(Rectangle())
    }
}

enum DiskRowStyle {
    /// Hidden and system items are drawn see-through.
    static let hiddenOpacity = 0.45
}

private struct NameCell: View {
    @Environment(\.palette) private var palette
    let row: DiskRow
    let protected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: DiskIcons.icon(for: row.entry))
                .resizable()
                .frame(width: 18, height: 18)
            Text(row.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            if protected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.faint)
                    .help(Text("Защищено от удаления"))
            }
        }
        .opacity(row.entry.isHidden ? DiskRowStyle.hiddenOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("disk.row.\(row.name)")
    }
}

private struct SizeCell: View {
    @Environment(\.palette) private var palette
    let row: DiskRow
    let total: Int64

    var body: some View {
        HStack(spacing: 10) {
            // Share of the folder, as a subtle bar.
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                if let size = row.size, total > 0, size.bytes > 0 {
                    Capsule().fill(palette.disk)
                        .frame(width: max(2, 40 * min(Double(size.bytes) / Double(total), 1)))
                }
            }
            .frame(width: 40, height: 4)
            .opacity(row.size == nil ? 0 : 1)
            Spacer(minLength: 0)
            if row.isPending {
                ProgressView().controlSize(.mini).tint(palette.accent)
                    .accessibilityLabel(Text("Считаю размер…"))
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .opacity(row.entry.isHidden ? DiskRowStyle.hiddenOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("disk.size.\(row.name)")
    }

    private var text: String { row.entry.isParentLink ? "" : DiskFormat.text(row.size) }
}

/// Right-click (or Control-click) menu of the clicked row, or of the whole selection when the click is on it.
private struct DiskMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<String>

    var body: some View {
        let disk = model.disk
        let items = disk.items(ids)
        if items.isEmpty {
            Button("Показать в Finder") { disk.reveal([]) }
        } else {
            if items.count == 1, let item = items.first, item.isContainer {
                Button("Открыть") { disk.open(item) }
                Divider()
            }
            Button("Показать в Finder") { disk.reveal(items) }
            Divider()
            if disk.zone == .trash {
                // Only where the original place is known: Finder's and `trashItem`'s records, or the helper's journal (`TrashPutBack`).
                if disk.canRestore(ids) {
                    Button("Восстановить") { disk.restore(ids) }
                }
                Button("Удалить безвозвратно", role: .destructive) { disk.requestDelete(ids) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!disk.canDelete(ids))
            } else {
                Button("Удалить", role: .destructive) { disk.requestDelete(ids) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!disk.canDelete(ids))
            }
        }
    }
}

/// Shortcuts without a visible button: ⌘⌫ deletes the selection (after the confirmation), ⌘↓ and Return open it.
/// A plain ⌫ is `onDeleteCommand` of the table and the large list: it works only while they have focus, so typing in
/// the search field never deletes anything.
private struct DiskShortcuts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = model.disk
        ZStack {
            Button { disk.requestDelete(disk.chosen) } label: { EmptyView() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button { disk.open(ids: disk.selection) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            // Return opens, as a double-click does (the table itself would only start renaming).
            Button { disk.open(ids: disk.selection) } label: { EmptyView() }
                .keyboardShortcut(.return, modifiers: [])
        }
        .disabled(disk.confirming)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct DiskConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let disk = model.disk
        let items = disk.pendingDeletion
        let size = disk.pendingDeletionSize
        let toTrash = disk.pendingZone != .trash
        let inTrash = disk.pendingZone == .trash
        VStack(spacing: 0) {
            HStack(spacing: -16) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    Image(nsImage: DiskIcons.large(for: item))
                        .resizable()
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(items.count == 1 ? 0 : Double(index - 1) * 7))
                        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
                        .appearIn(delay: Double(index) * 0.07, offset: 12)
                }
            }
            .frame(height: 64)
            Text(title(items, toTrash: toTrash, inTrash: inTrash))
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityIdentifier("confirm.title")
            Text(message(items, bytes: size.bytes, toTrash: toTrash, inTrash: inTrash))
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .accessibilityIdentifier("confirm.message")
            if disk.pendingZone == .iCloud {
                Label("Они удалятся и из iCloud Drive — на всех ваших устройствах.", systemImage: "icloud")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.warning)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .accessibilityIdentifier("confirm.iCloud")
            }
            let privileged = items.filter { disk.removal(of: $0) == .privileged }
            if !privileged.isEmpty {
                // Outside the home folder the helper removes items as root: say so, and show exactly where.
                VStack(alignment: .leading, spacing: 4) {
                    Label("Удаление с правами администратора", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.warning)
                        .accessibilityIdentifier("confirm.admin")
                    ForEach(privileged.prefix(4)) { item in
                        Text(verbatim: item.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if privileged.count > 4 {
                        Text(String(localized: " и ещё \(privileged.count - 4)").trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.faint)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.warning.opacity(0.1)))
                .padding(.top, 12)
            }
            if size.pending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(palette.accent)
                    Text("Считаю размер…")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.faint)
                .padding(.top, 8)
            }
            ConfirmButtons(confirmTitle: disk.pendingEmptiesTrash ? "Очистить корзину" : toTrash ? "В Корзину" : "Удалить",
                           cancel: disk.cancelConfirm, confirm: disk.delete)
        }
    }

    private func title(_ items: [DiskEntry], toTrash: Bool, inTrash: Bool) -> String {
        if model.disk.pendingEmptiesTrash { return String(localized: "Очистить корзину?") }
        // Already in the Trash: there is no getting it back.
        if inTrash {
            if items.count == 1, let item = items.first { return String(localized: "Удалить «\(item.name)» безвозвратно?") }
            return String(localized: "Удалить объекты безвозвратно: \(items.count)?")
        }
        if items.count == 1, let item = items.first {
            return toTrash ? String(localized: "Переместить «\(item.name)» в Корзину?") : String(localized: "Удалить «\(item.name)» навсегда?")
        }
        return toTrash ? String(localized: "Переместить в Корзину объекты: \(items.count)?") : String(localized: "Удалить объекты навсегда: \(items.count)?")
    }

    private func message(_ items: [DiskEntry], bytes: Int64, toTrash: Bool, inTrash: Bool) -> String {
        let size = DiskFormat.size(bytes)
        if model.disk.pendingEmptiesTrash {
            return String(localized: "Объекты в Корзине: \(items.count) — \(size). Они будут удалены безвозвратно, это действие нельзя отменить.")
        }
        var names = items.prefix(3).map(\.name).joined(separator: ", ")
        if items.count > 3 { names += String(localized: " и ещё \(items.count - 3)") }
        if inTrash {
            return String(localized: "\(names) — \(size) будет удалено безвозвратно. Это действие нельзя отменить.")
        }
        return toTrash
            ? String(localized: "\(names) — \(size) будет перемещено в Корзину. Пока Корзина не очищена, всё можно вернуть.")
            : String(localized: "\(names) — \(size) будет удалено без возможности восстановления.")
    }
}

/// «Вернуть» into a folder that already holds the name, asked as Finder asks: replace (what is there goes to the
/// Trash), skip, or keep both («name 2.ext»); «Применить ко всем» answers the rest the same way. Esc puts nothing back.
struct PutBackClashPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var forAll = false

    var body: some View {
        let disk = model.disk
        if let clash = disk.clashes.first {
            let place = FileManager.default.displayName(atPath: clash.origin.folder)
            VStack(spacing: 0) {
                Image(nsImage: DiskIcons.large(for: clash.entry))
                    .resizable()
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
                Text(String(localized: "«\(clash.origin.name)» уже есть в «\(place)»"))
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .accessibilityIdentifier("putBack.title")
                Text("Заменить его объектом из Корзины? То, что сейчас там, уйдёт в Корзину.")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                if disk.clashes.count > 1 {
                    Toggle(isOn: $forAll) {
                        Text(String(localized: "Применить ко всем (\(disk.clashes.count))"))
                            .font(.system(size: 12))
                            .foregroundStyle(palette.muted)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 14)
                    .accessibilityIdentifier("putBack.forAll")
                }
                HStack(spacing: 8) {
                    choice("Пропустить", id: "putBack.skip") { disk.resolveClash(.skip, forAll: forAll) }
                    choice("Оставить оба", id: "putBack.keepBoth") { disk.resolveClash(.keepBoth, forAll: forAll) }
                    choice("Заменить", prominent: true, id: "putBack.replace") { disk.resolveClash(.replace, forAll: forAll) }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 22)
                .background {
                    Button(action: disk.cancelClashes) { EmptyView() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .id(clash.id)
            .transition(.opacity)
        }
    }

    private func choice(_ title: LocalizedStringKey, prominent: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? palette.onAccent : palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if prominent {
                        HoverFill(color: palette.accent, shape: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle.rounded(12))
        .accessibilityIdentifier(id)
    }
}

/// Sizes as the Storage section shows them.
enum DiskFormat {
    /// A known size. An empty file reads «Zero KB» here: «—» means there is no size (a mounted volume).
    static func size(_ bytes: Int64) -> String {
        bytes > 0 ? ByteFormat.string(bytes) : ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
    }

    /// A row's size, «—» when there is none. A size that misses unreadable folders inside reads plainly too, as in
    /// Finder: a «≥» puzzled people.
    static func text(_ size: DiskSize?) -> String {
        guard let size else { return "—" }
        return self.size(size.bytes)
    }
}

/// Icons for the table: files by type (tens of thousands of them share a few images), folders and bundles by path,
/// since those have icons of their own (Downloads, apps).
@MainActor
enum DiskIcons {
    private static var byType: [String: NSImage] = [:]

    /// Finder's icons: a folder, bundle or link its own (a link or alias shows its target's); a file the document icon
    /// of the app its type opens with (`.js`, `.py` → that editor's), one per extension. A file without an extension —
    /// an alias to an app, a script — gets its own icon: aliases have no extension.
    static func icon(for entry: DiskEntry) -> NSImage {
        if entry.isParentLink { return NSImage(named: NSImage.folderName) ?? NSImage() }
        guard entry.kind == .file else { return IconCache.icon(for: entry.url) }
        let ext = entry.url.pathExtension.lowercased()
        // Aliases have no extension: their own icon (the target's). Other extensionless files share a plain one.
        if ext.isEmpty, isAlias(entry) { return IconCache.icon(for: entry.url) }
        if let hit = byType[ext] { return hit }
        let image = ext.isEmpty ? NSWorkspace.shared.icon(for: .data) : NSWorkspace.shared.icon(forFile: entry.path)
        byType[ext] = image
        return image
    }

    private static var aliases: [String: Bool] = [:]

    /// A Finder alias (one cheap attribute read, remembered per path).
    private static func isAlias(_ entry: DiskEntry) -> Bool {
        if let known = aliases[entry.path] { return known }
        let alias = (try? entry.url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
        if aliases.count > 5_000 { aliases.removeAll() }
        aliases[entry.path] = alias
        return alias
    }

    /// The confirmation shows the item's own icon, as Finder would.
    static func large(for entry: DiskEntry) -> NSImage {
        IconCache.icon(for: entry.url)
    }

    static func folder(_ url: URL) -> NSImage {
        IconCache.icon(for: url)
    }
}
