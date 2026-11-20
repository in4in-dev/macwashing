import MacWashingKit
import SwiftUI

extension AutoCleanFrequency {
    var title: LocalizedStringKey {
        switch self {
        case .daily: "Ежедневно"
        case .weekly: "Раз в неделю"
        case .monthly: "Раз в месяц"
        #if DEBUG
        case .everyMinute: "Каждую минуту"
        #endif
        }
    }
}

/// «Мусор Xcode, Установщики» in the interface's language.
enum CategoryList {
    static func string(_ categories: [JunkCategoryID]) -> String {
        categories.map { String(localized: $0.titleString) }.formatted(.list(type: .and))
    }
}

/// One choice of what auto-clean removes: a round mark, a title and a line under it.
struct ModeOption: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey
    let detail: String
    let selected: Bool
    var identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                CheckMark(state: selected ? .on : .off)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// «18:30» in the interface's locale, for minutes after midnight.
enum ClockTime {
    static func string(_ minutes: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Every half hour of the day.
    static let choices = Array(stride(from: 0, to: 24 * 60, by: 30))
}

/// A capsule that opens a menu of choices (the app's own, `AppMenuButton`), like the language menu in Settings.
struct CapsuleMenu<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    let choices: [Value]
    let selection: Value
    let title: (Value) -> String
    let pick: (Value) -> Void
    var identifier: String

    var body: some View {
        AppMenuButton(minWidth: 120) {
            for choice in choices {
                AppMenuItem(verbatim: title(choice), checked: choice == selection) { pick(choice) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title(selection)).monospacedDigit()
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
        .accessibilityIdentifier(identifier)
    }
}

/// The sheet behind «Настроить автоочистку» on the done screen of System Junk (in `ConfirmOverlay`).
struct AutoCleanSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var autoClean = model.autoClean
        VStack(spacing: 0) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(palette.accent)
            Text("Автоочистка")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 12)
                .accessibilityIdentifier("autoClean.setup.title")
            Text("MacWashing будет сам удалять мусор по расписанию, когда Mac включён: без окон и вопросов.")
                .font(.system(size: 13))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            SegmentedPicker(options: AutoCleanFrequency.regular.map { ($0, $0.title) }, selection: $autoClean.draftFrequency,
                            onChange: { model.play(.toggle) }, identifier: "autoClean.setup.frequency")
                .padding(.top, 18)
            HStack {
                Text("Время").font(.system(size: 13))
                Text(dayHint).font(.system(size: 12)).foregroundStyle(palette.faint)
                Spacer()
                CapsuleMenu(choices: ClockTime.choices, selection: autoClean.draftTime, title: ClockTime.string,
                            pick: { autoClean.draftTime = $0; model.play(.toggle) }, identifier: "autoClean.setup.time")
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 10) {
                Text("Что удалять")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
                // «Matches your choice» only when it really does: cleaned «Осторожно» items are never auto-cleaned.
                let choice = autoClean.draftChoice
                ModeOption(title: "Рекомендуемое",
                           detail: choice?.matchesRecommended == true && choice?.cautious == 0
                               ? String(localized: "Всё, что сканирование отмечает само. Совпадает с вашим выбором в этой очистке")
                               : String(localized: "Всё, что сканирование отмечает само"),
                           selected: autoClean.draftMode == .recommended, identifier: "autoClean.setup.recommended") {
                    autoClean.draftMode = .recommended
                    model.play(.tick)
                }
                if let choice = autoClean.draftChoice, !choice.matchesRecommended {
                    ModeOption(title: "Запомнить мой выбор",
                               detail: String(localized: "Всё рекомендуемое, кроме: \(CategoryList.string(choice.leftOut))"),
                               selected: autoClean.draftMode == .custom, identifier: "autoClean.setup.custom") {
                        autoClean.draftMode = .custom
                        model.play(.tick)
                    }
                }
                let cautious = (choice?.cautious ?? 0) > 0
                Group {
                    if cautious {
                        Text("Отмеченное вами с пометкой «Осторожно» в автоочистку не войдёт: такие объекты и файлы открытых программ она не трогает.")
                    } else {
                        Text("Объекты с пометкой «Осторожно» и файлы открытых программ автоочистка не трогает.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(cautious ? palette.muted : palette.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .card(palette, radius: 12)
            .padding(.top, 14)

            ConfirmButtons(confirmTitle: "Включить", destructive: false, cancelID: "autoClean.setup.cancel",
                           confirmID: "autoClean.setup.save", cancel: autoClean.cancelSetup, confirm: autoClean.saveSetup)
        }
    }

    /// Which day a weekly or monthly run falls on: the day it is set up.
    private var dayHint: String {
        let calendar = Calendar.current
        let today = Date()
        switch model.autoClean.draftFrequency {
        case .daily: return ""
        case .weekly: return calendar.standaloneWeekdaySymbols[calendar.component(.weekday, from: today) - 1]
        case .monthly: return String(localized: "\(calendar.component(.day, from: today)) числа")
        #if DEBUG
        case .everyMinute: return ""
        #endif
        }
    }
}
