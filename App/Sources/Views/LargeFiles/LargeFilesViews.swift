import MacWashingKit
import SwiftUI

struct LargeFilesSectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let large = model.largeFiles
        ZStack {
            switch large.phase {
            case .intro:
                IntroScreen(
                    title: "Большие файлы",
                    text: "Находит крупные и давно забытые файлы на выбранных дисках и помогает решить, что с ними делать.",
                    features: [
                        Feature(symbol: "doc.text.magnifyingglass", title: "Находит залежи файлов", text: "Видео, архивы и образы дисков, о которых вы давно забыли."),
                        Feature(symbol: "slider.horizontal.3", title: "Удобные фильтры", text: "По типу, размеру и дате последнего открытия."),
                    ],
                    art: .folder,
                    buttonTitle: "Найти большие файлы",
                    canStart: !large.selectedVolumes.isEmpty,
                    start: large.startScan
                ) { VolumePicker() }
                .transition(.screen)
                .onAppear { large.refreshVolumes() }
            case .scanning:
                ProgressScreen(
                    art: .folder,
                    verb: "Ищу большие файлы",
                    progress: large.progress,
                    amount: large.foundBytes > 0 ? ByteFormat.live(large.foundBytes) : " ",
                    path: large.currentPath,
                    steps: large.volumes.filter { large.selectedVolumes.contains($0.id) }.map {
                        .init(id: $0.id, verbatim: $0.name, status: .running, size: 0)
                    },
                    stop: large.cancel
                )
                .transition(.screen)
            case .results:
                LargeFilesResultsView()
                    .transition(.screen)
            }
        }
        .animation(Motion.screen, value: large.phase)
    }
}

struct VolumePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let large = model.largeFiles
        VStack(alignment: .leading, spacing: 8) {
            Text("Где искать")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(palette.faint)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(large.volumes.enumerated()), id: \.element.id) { index, volume in
                    let on = large.selectedVolumes.contains(volume.id)
                    HStack(spacing: 10) {
                        CheckButton(state: on ? .on : .off, label: volume.name) { large.toggleVolume(volume) }
                            .accessibilityIdentifier("largeFiles.volume.\(index)")
                        Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                            .font(.system(size: 16))
                            .foregroundStyle(palette.muted)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: volume.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(volume.isStartup
                                 ? "Занято \(ByteFormat.string(volume.usedBytes)) · свободно \(ByteFormat.string(volume.availableBytes))"
                                 : "Занято \(ByteFormat.string(volume.usedBytes))")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                        }
                        Spacer()
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                Capsule().fill(palette.disk)
                                    .frame(width: proxy.size.width * Double(volume.usedBytes) / Double(max(volume.totalBytes, 1)))
                            }
                        }
                        .frame(width: 56, height: 4)
                        Text(ByteFormat.string(volume.totalBytes))
                            .font(.system(size: 13))
                            .foregroundStyle(palette.muted)
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 14)
                    .frame(height: 54)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(palette.line).frame(height: 1) } }
                }
                Button(action: large.chooseFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                        Image(systemName: "folder").font(.system(size: 16)).frame(width: 20)
                        Text("Выбрать папку…").font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(palette.accentSoft)
                    .padding(.leading, 6)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
                .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
            }
            .card(palette)
        }
        .padding(.top, 26)
    }
}

struct LargeFilesResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    private typealias Filter = LargeFilesModel.Filter

    private var groups: [(title: LocalizedStringKey?, items: [(Filter, LocalizedStringKey)])] {
        [
            (nil, [(.all, "Все файлы")]),
            ("По типу", [(.kind(.archive), "Архивы"), (.kind(.document), "Документы"), (.kind(.image), "Изображения"),
                         (.kind(.movie), "Фильмы"), (.kind(.music), "Музыка"), (.kind(.other), "Другое")]),
            ("По размеру", [(.huge, "Огромные · от 1 ГБ"), (.medium, "Средние · 100 МБ–1 ГБ"), (.small, "Маленькие · до 100 МБ")]),
            ("По дате открытия", [(.olderThanYear, "Больше года назад"), (.olderThanMonth, "Больше месяца назад"), (.lastWeek, "На прошлой неделе")]),
        ]
    }

    var body: some View {
        @Bindable var large = model.largeFiles
        ZStack(alignment: .bottom) {
            HStack(spacing: 12) {
                filters(large)
                    .frame(width: 256)
                list(large)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 12)

            ActionBar(
                caption: large.selected.isEmpty ? String(localized: "Ничего не выбрано") : String(localized: "Выбрано файлов: \(large.selected.count)"),
                total: ByteFormat.string(large.selectedBytes),
                buttonTitle: large.deleteImmediately ? "Удалить" : "В Корзину",
                enabled: !large.selected.isEmpty && !large.deleting,
                action: large.requestDelete
            ) {
                HStack(spacing: 8) {
                    ToggleSwitch(isOn: $large.deleteImmediately, label: "Минуя Корзину") { model.play(.toggle) }
                        .accessibilityIdentifier("largeFiles.deleteImmediately")
                    Text("Минуя Корзину").font(.system(size: 13)).foregroundStyle(palette.muted)
                }
            }
        }
    }

    private func filters(_ large: LargeFilesModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(palette.faint)
                            .padding(.horizontal, 14)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                    }
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                        Button { large.setFilter(item.0) } label: {
                            HStack {
                                Text(item.1).font(.system(size: 14))
                                Spacer()
                                Text(ByteFormat.string(large.size(of: item.0)))
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.muted)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                            .hoverRow(selected: large.filter == item.0, cornerRadius: 10)
                        }
                        .buttonStyle(.row)
                        .accessibilityIdentifier("largeFiles.filter.\(identifier(for: item.0))")
                        .accessibilityAddTraits(large.filter == item.0 ? .isSelected : [])
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .scrollIndicators(.never)
            .staggerList()
    }

    private func list(_ large: LargeFilesModel) -> some View {
        let shown = large.shown
        let allOn = !shown.isEmpty && shown.allSatisfy { large.checked.contains($0.id) }
        let volumeNames = large.volumes.filter { large.selectedVolumes.contains($0.id) }.map(\.name).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title(for: large.filter))
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                    .contentTransition(.opacity)
                Text("Файлов: \(shown.count) · \(ByteFormat.string(large.shownBytes)) · \(volumeNames)")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("largeFiles.summary")
                if large.refining {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini).tint(palette.accent)
                        Text("Досканирую пакеты и скрытые папки…")
                            .foregroundStyle(palette.muted)
                        Text(large.currentPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("largeFiles.refining")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                HStack {
                    Button(allOn ? "Снять все" : "Выбрать все", action: large.toggleShown)
                        .buttonStyle(.hover)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accentSoft)
                        .accessibilityIdentifier("largeFiles.toggleAll")
                    Spacer()
                    Text("По размеру").font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                .frame(height: 32)
                .padding(.top, 12)
                Rectangle().fill(palette.line).frame(height: 1)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)

            if shown.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundStyle(palette.faint)
                    Text("Файлов больше 50 МБ здесь нет").font(.system(size: 14)).foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
                .transition(.opacity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                            fileRow(file, large: large)
                                .appearIn(delay: 0.08 + Double(min(index, 14)) * 0.028)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 110)
                    .id(large.filter)
                }
                .scrollIndicators(.never)
            .staggerList(key: large.filter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pane(palette)
    }

    private func fileRow(_ file: LargeFile, large: LargeFilesModel) -> some View {
        let on = large.checked.contains(file.id)
        let home = model.home.fsPath
        return HStack(spacing: 0) {
            CheckButton(state: on ? .on : .off, label: file.name) { large.toggle(file) }
                .accessibilityIdentifier("largeFiles.file.\(file.name)")
                .padding(.leading, -6)
            Image(nsImage: IconCache.icon(for: file.url))
                .resizable()
                .frame(width: 34, height: 34)
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: file.url.deletingLastPathComponent().fsPath.replacingOccurrences(of: home, with: "~"))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.leading, 12)
            Spacer(minLength: 12)
            Text(RelativeDate.opened(file.lastOpened))
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .frame(width: 160, alignment: .leading)
            Text(ByteFormat.string(file.size))
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(on ? palette.text : palette.muted)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { large.reveal(file) }
        .appContextMenu {
            AppMenuItem("Показать в Finder", symbol: "folder") { large.reveal(file) }
        }
    }

    private func title(for filter: Filter) -> LocalizedStringKey {
        groups.flatMap(\.items).first { $0.0 == filter }?.1 ?? "Все файлы"
    }

    /// Stable name of a filter for accessibility identifiers.
    private func identifier(for filter: Filter) -> String {
        switch filter {
        case .all: "all"
        case .kind(let kind): kind.rawValue
        case .huge: "huge"
        case .medium: "medium"
        case .small: "small"
        case .olderThanYear: "olderThanYear"
        case .olderThanMonth: "olderThanMonth"
        case .lastWeek: "lastWeek"
        }
    }
}

struct LargeFilesConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let large = model.largeFiles
        let count = large.selected.count
        let size = ByteFormat.string(large.selectedBytes)
        VStack(spacing: 0) {
            Image(systemName: "trash")
                .font(.system(size: 26))
                .foregroundStyle(palette.muted)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08)))
                .modifier(BounceOnAppear())
            Text(large.deleteImmediately ? "Удалить файлы навсегда: \(count)?" : "Переместить в Корзину файлы: \(count)?")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityIdentifier("confirm.title")
            Text(large.deleteImmediately
                 ? "\(size) будет удалено без возможности восстановления."
                 : "Место (\(size)) освободится, когда вы очистите Корзину.")
                .font(.system(size: 13))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            if large.pendingPrivileged > 0 {
                NoticeBanner(
                    text: String(localized: "Без помощника не удалить файлов: \(large.pendingPrivileged). Они останутся на месте; установить помощник можно в Настройках."),
                    symbol: "key"
                )
                .padding(.top, 12)
                .accessibilityIdentifier("confirm.helperMissing")
            }
            ConfirmButtons(
                confirmTitle: large.deleteImmediately ? "Удалить" : "В Корзину",
                cancel: large.cancelConfirm,
                confirm: large.delete
            )
        }
    }
}

/// One bounce of the symbol when the view appears. The indefinite `.bounce` with `.nonRepeating` needs macOS 15; before
/// it the symbol stays still.
private struct BounceOnAppear: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.symbolEffect(.bounce, options: .nonRepeating)
        } else {
            content
        }
    }
}
