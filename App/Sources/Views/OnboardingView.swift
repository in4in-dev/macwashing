import Combine
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var fullDiskAccess = Permissions.hasFullDiskAccess
    @State private var askedForAccess = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let helperReady = model.helper.isCurrent
        // Outdated or silent: both are fixed by registering it again.
        let helperOutdated = { if case .outdated = model.helper.status { true } else { false } }() || model.helper.status == .notResponding
        let ready = fullDiskAccess && helperReady
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    AquaIcon().frame(width: 48, height: 48)
                    Text("MacWashing").font(.system(size: 17, weight: .semibold))
                }
                .appearIn(delay: 0.05)
                Text("Два разрешения — и можно начинать")
                    .font(.system(size: 34, weight: .bold))
                    .kerning(-0.7)
                    .padding(.top, 32)
                    .appearIn(delay: 0.1)
                Text("MacWashing работает только на этом Mac и ничего не отправляет в сеть. Без этих разрешений он не увидит кэши и журналы.")
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(palette.muted)
                    .padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .appearIn(delay: 0.15)

                VStack(spacing: 12) {
                    step(1, id: "onboarding.fullDiskAccess", done: fullDiskAccess, title: "Полный доступ к диску",
                         text: "Чтобы видеть кэши и журналы в ~/Library. Включите переключатель у MacWashing в списке «Полный доступ к диску».",
                         button: "Открыть Настройки", action: {
                             askedForAccess = true
                             Permissions.requestFullDiskAccess()
                         }) {
                        if askedForAccess && !fullDiskAccess {
                            HStack(spacing: 6) {
                                Text("Нет в списке? Нажмите «+» или перетащите приложение.")
                                    .foregroundStyle(palette.faint)
                                Button("Показать в Finder", action: Permissions.revealAppInFinder)
                                    .buttonStyle(.hover)
                                    .foregroundStyle(palette.accentSoft)
                            }
                            .font(.system(size: 12))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .appearIn(delay: 0.22)
                    step(2, id: "onboarding.helper", done: helperReady, title: "Помощник для системных папок",
                         text: "Нужен, чтобы убирать остатки программ из общих папок Mac. macOS попросит разрешить его один раз.",
                         button: helperOutdated ? "Обновить" : model.helper.status == .needsApproval ? "Разрешить" : "Установить",
                         action: helperOutdated ? model.helper.reinstall : model.helper.install) {
                        EmptyView()
                    }
                    .appearIn(delay: 0.3)
                }
                .padding(.top, 32)

                HStack(spacing: 8) {
                    PrimaryButton(title: "Начать", enabled: ready, height: 48, action: model.finishOnboarding)
                        .accessibilityIdentifier("onboarding.start")
                        .help(ready ? Text(verbatim: "") : Text("Сначала выполните оба шага выше"))
                    Button("Позже") { model.finishOnboarding() }
                        .accessibilityIdentifier("onboarding.later")
                        .buttonStyle(.hover)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                }
                .padding(.top, 32)
                .appearIn(delay: 0.38)
                // Why «Начать» is dimmed, and that skipping is fine: both can be done later in Settings.
                if !ready {
                    Text("«Начать» станет доступна, когда оба шага выполнены. Можно и «Позже» — разрешения выдаются в Настройках в любой момент.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .transition(.opacity)
                        .accessibilityIdentifier("onboarding.startHint")
                }
            }
            .frame(width: 470, alignment: .leading)
            SectionArt(kind: .washer, size: 330)
                .modifier(IdleFloat())
                .frame(maxWidth: .infinity)
        }
        .padding(.leading, 80)
        .padding(.trailing, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(timer) { _ in
            let granted = Permissions.hasFullDiskAccess
            if granted != fullDiskAccess {
                model.play(.toggle)
                withAnimation(Motion.bouncy) { fullDiskAccess = granted }
            }
            let before = model.helper.status
            model.helper.refresh()
            if before != model.helper.status && model.helper.status == .enabled { model.play(.toggle) }
        }
    }

    private func step<Footer: View>(
        _ number: Int, id: String, done: Bool, title: LocalizedStringKey, text: LocalizedStringKey,
        button: LocalizedStringKey, action: @escaping () -> Void, @ViewBuilder footer: () -> Footer
    ) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(done ? palette.accent : .white.opacity(0.08))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(palette.onAccent)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                footer()
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            // Identifiers for scripts that walk onboarding through Accessibility.
            if done {
                Text("Готово")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentSoft)
                    .transition(.opacity)
                    .accessibilityIdentifier("\(id).done")
            } else {
                SecondaryButton(title: button, height: 32, action: action)
                    .accessibilityIdentifier(id)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(done ? palette.accent.opacity(0.35) : palette.cardStroke))
        .animation(Motion.bouncy, value: done)
    }
}
