import MacWashingKit
import SwiftUI

struct Feature: Identifiable {
    let id = UUID()
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
}

/// Start screen of a module: text on the left, animated art on the right, the primary action below.
struct IntroScreen<Extra: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let features: [Feature]
    let art: SectionArt.Kind
    let buttonTitle: LocalizedStringKey
    var canStart = true
    let start: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .kerning(-0.7)
                    Text(text)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(palette.muted)
                        .padding(.top, 14)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: feature.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(palette.accentSoft)
                                    .frame(width: 40, height: 40)
                                    .card(palette, radius: 12)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.title).font(.system(size: 15, weight: .semibold))
                                    Text(feature.text)
                                        .font(.system(size: 13))
                                        .lineSpacing(2)
                                        .foregroundStyle(palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .appearIn(delay: 0.12 + Double(index) * 0.08)
                        }
                    }
                    .padding(.top, 32)
                    extra()
                        .appearIn(delay: 0.24)
                    PrimaryButton(title: buttonTitle, systemImage: "chevron.right", enabled: canStart, action: start)
                        .accessibilityIdentifier("intro.start")
                        .padding(.top, 36)
                        .appearIn(delay: 0.3)
                }
                .frame(width: 404, alignment: .leading)
                SectionArt(kind: art, size: 300)
                    .modifier(IdleFloat())
                    .frame(maxWidth: .infinity)
            }
            .padding(.leading, 44)
            .padding(.trailing, 36)
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity)
        }
    }
}

/// Gentle idle float for illustrations.
struct IdleFloat: ViewModifier {
    @Environment(\.animationsLive) private var live

    func body(content: Content) -> some View {
        Group {
            if live {
                content.phaseAnimator([false, true]) { view, up in
                    view.offset(y: up ? -9 : 0)
                } animation: { _ in .easeInOut(duration: 3) }
            } else {
                content
            }
        }
    }
}

/// Scanning / cleaning screen: progress ring around the art, counter, current path, step list.
struct ProgressScreen: View {
    @Environment(\.palette) private var palette
    struct Step: Identifiable {
        let id: String
        let title: Text
        let status: Status
        let size: Int64
        enum Status { case waiting, running, done }

        init(id: String, title: LocalizedStringKey, status: Status, size: Int64) {
            self.init(id: id, text: Text(title), status: status, size: size)
        }

        /// A name from the disk (a volume, a folder): shown as is, never looked up or parsed as a format.
        init(id: String, verbatim: String, status: Status, size: Int64) {
            self.init(id: id, text: Text(verbatim: verbatim), status: status, size: size)
        }

        private init(id: String, text: Text, status: Status, size: Int64) {
            self.id = id
            self.title = text
            self.status = status
            self.size = size
        }
    }

    let art: SectionArt.Kind
    let verb: LocalizedStringKey
    let progress: Double
    let amount: String
    let path: String
    let steps: [Step]
    let stop: () -> Void

    /// Start the ring right away so the press feels answered. A sliver is enough since the scan bar moves with the clock
    /// from the first moment (`JunkModel.stepSeconds`); it was 7 % while the bar waited for the first measured paths.
    static let minimumProgress = 0.01
    @State private var started = false
    /// Highest value shown so far: the ring only ever moves forward.
    @State private var peak = 0.0

    private var shown: Double {
        max(peak, started ? max(progress, Self.minimumProgress) : progress)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(palette.track, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(shown, 0.005))
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: palette.accent.opacity(0.6), radius: 6)
                Circle()
                    .stroke(palette.track, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .padding(20)
                    .modifier(SlowSpin())
                SectionArt(kind: art, spinning: true, size: 170)
            }
            .frame(width: 240, height: 240)
            .padding(.top, 12)

            Text("\(Text(verb)) · \(Int((shown * 100).rounded()))%")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.muted)
                .monospacedDigit()
                .contentTransition(.numericText())
                .padding(.top, 22)
                .accessibilityIdentifier("progress.title")
            Text(amount)
                .font(.system(size: 44, weight: .bold))
                .kerning(-0.9)
                .monospacedDigit()
                .contentTransition(.numericText())
                .padding(.top, 2)
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
                .padding(.top, 4)
                .id(path)
                .transition(.opacity)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 40), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 10) {
                        ZStack {
                            switch step.status {
                            case .done:
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(palette.accentSoft)
                                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                            case .running:
                                ProgressView().controlSize(.mini).tint(palette.accent)
                            case .waiting:
                                Circle().fill(palette.faint).frame(width: 5, height: 5)
                            }
                        }
                        .frame(width: 16, height: 16)
                        step.title.lineLimit(1)
                        Spacer()
                        if step.status == .done {
                            Text(ByteFormat.string(step.size))
                                .foregroundStyle(palette.muted)
                                .monospacedDigit()
                                .transition(.opacity)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(step.status == .waiting ? palette.faint : palette.text)
                    .frame(height: 24)
                    .animation(Motion.bouncy, value: step.status)
                    .appearIn(delay: 0.15 + Double(index) * 0.04)
                }
            }
            .frame(width: 560)
            .padding(.top, 28)

            SecondaryButton(title: "Остановить", action: stop)
                .accessibilityIdentifier("progress.stop")
                .padding(.top, 28)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.3), value: path)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) { started = true }
        }
        .onChange(of: progress) { _, value in
            peak = max(peak, started ? max(value, Self.minimumProgress) : value)
        }
    }
}

struct SlowSpin: ViewModifier {
    @State private var angle = 0.0
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

/// Bottom action: a floating glass bar with the total.
struct ActionBar<Accessory: View>: View {
    @Environment(\.palette) private var palette
    let caption: String
    let total: String
    let buttonTitle: LocalizedStringKey
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                Text(total)
                    .font(.system(size: 19, weight: .bold))
                    .kerning(-0.2)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("action.total")
            }
            .frame(minWidth: 120, alignment: .leading)
            accessory()
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 26)
                    .frame(height: 48)
                    .foregroundStyle(enabled ? palette.onAccent : palette.faint)
                    .background(HoverFill(color: enabled ? palette.accent : .white.opacity(0.1), shape: Capsule()))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle.bubbly)
            .disabled(!enabled)
            .accessibilityIdentifier("action.primary")
            // Outside the label, so the Liquid Glass switch on hover does not reset it.
            .shadow(color: enabled ? palette.accent.opacity(0.35) : .clear, radius: 12, y: 6)
        }
        .padding(.leading, 24)
        .padding(.trailing, 8)
        .frame(height: 64)
        .glassSurface(.capsule)
        .shadow(color: .black.opacity(0.45), radius: 25, y: 18)
        .padding(.bottom, 26)
        .animation(Motion.spring, value: total)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Final screen after cleaning.
struct DoneScreen: View {
    @Environment(\.palette) private var palette
    let freed: String
    let stats: [(value: String, label: String)]
    let note: String?
    /// What could not be removed and why: a «skipped» count alone does not tell the user what to do.
    var failures: [CleanReport.Failure] = []
    /// A second button left of «Готово» (System Junk: «Настроить автоочистку»).
    var secondary: Secondary?
    let finish: () -> Void
    @State private var showsFailures = false

    struct Secondary {
        let title: LocalizedStringKey
        let identifier: String
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionArt(kind: .done, size: 200)
            Text("Готово")
                .font(.system(size: 34, weight: .bold))
                .kerning(-0.7)
                .padding(.top, 24)
                .appearIn(delay: 0.45)
            Text("Освобождено \(Text(freed).foregroundStyle(palette.text).fontWeight(.semibold)) на диске")
                .font(.system(size: 16))
                .foregroundStyle(palette.muted)
                .padding(.top, 10)
                .accessibilityIdentifier("done.freed")
                .appearIn(delay: 0.55)
            HStack(spacing: 12) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.value).font(.system(size: 20, weight: .bold)).monospacedDigit()
                            .accessibilityIdentifier("done.stat.\(index)")
                        Text(stat.label).font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .card(palette)
                    .appearIn(delay: 0.65 + Double(index) * 0.09)
                }
            }
            .frame(width: 564)
            .padding(.top, 32)
            if let note {
                // A long list of apps wraps inside the stats' width instead of running to the screen's edges.
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 564)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .appearIn(delay: 0.95)
            }
            if !failures.isEmpty {
                failureList
                    .frame(width: 564)
                    .padding(.top, 16)
                    .appearIn(delay: 0.95)
            }
            HStack(spacing: 12) {
                if let secondary {
                    SecondaryButton(title: secondary.title, height: 44, action: secondary.action)
                        .accessibilityIdentifier(secondary.identifier)
                }
                PrimaryButton(title: "Готово", height: 44, action: finish)
                    .accessibilityIdentifier("done.finish")
            }
            .padding(.top, 32)
            .appearIn(delay: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 56)
    }

    /// «Почему пропущено»: the first reasons, one line per item.
    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.spring) { showsFailures.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showsFailures ? 90 : 0))
                    Text("Почему пропущено")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(palette.accentSoft)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .accessibilityIdentifier("done.failures")
            if showsFailures {
                FailureLines(failures: failures)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// The first few failures of a removal: where, and what macOS or the helper said.
struct FailureLines: View {
    @Environment(\.palette) private var palette
    let failures: [CleanReport.Failure]
    var limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(failures.prefix(limit).enumerated()), id: \.offset) { _, failure in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: (failure.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: failure.path))
                    Text(verbatim: failure.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
            }
            if failures.count > limit {
                Text(String(localized: " и ещё \(failures.count - limit)").trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// A short warning above results or in a confirmation: what the user should know and, optionally, what to do.
struct NoticeBanner: View {
    @Environment(\.palette) private var palette
    let text: String
    var symbol = "exclamationmark.triangle"
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.warning)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                SecondaryButton(title: actionTitle, height: 28, action: action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.warning.opacity(0.1)))
    }
}

/// Destructive confirmation with a stack of app icons or a trash icon.
struct ConfirmOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let uninstaller = model.uninstaller
        let large = model.largeFiles
        let junk = model.junk
        let disk = model.disk
        let privacy = model.privacy
        let startup = model.startup
        let autoClean = model.autoClean
        let showing = uninstaller.confirming || large.confirming || junk.confirming || disk.confirming || privacy.confirming
            || startup.confirming || junk.askingConsent || autoClean.showingSetup || disk.resolvingClash
        ZStack {
            if showing {
                Color.black.opacity(0.52)
                    .background(.ultraThinMaterial.opacity(0.4))
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { dismiss() }
                Group {
                    if autoClean.showingSetup { AutoCleanSetupSheet() }
                    else if junk.askingConsent { JunkConsentPrompt() }
                    else if junk.confirming { JunkConfirm() }
                    else if uninstaller.confirming { UninstallConfirm() }
                    else if disk.resolvingClash { PutBackClashPrompt() }
                    else if disk.confirming { DiskConfirm() }
                    else if privacy.confirming { PrivacyConfirm() }
                    else if startup.confirming { StartupConfirm() }
                    else { LargeFilesConfirm() }
                }
                .frame(width: 390)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 22)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(palette.sheet))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
                .transition(.scale(scale: 0.94).combined(with: .opacity).combined(with: .offset(y: 14)))
            }
        }
        .animation(Motion.spring, value: showing)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func dismiss() {
        if model.autoClean.showingSetup { model.autoClean.cancelSetup() }
        if model.junk.askingConsent { model.junk.cancelConsent() }
        if model.junk.confirming { model.junk.cancelConfirm() }
        if model.uninstaller.confirming { model.uninstaller.cancelConfirm() }
        if model.disk.confirming { model.disk.cancelConfirm() }
        if model.disk.resolvingClash { model.disk.cancelClashes() }
        if model.privacy.confirming { model.privacy.cancelConfirm() }
        if model.startup.confirming { model.startup.cancelConfirm() }
        if model.largeFiles.confirming { model.largeFiles.cancelConfirm() }
    }
}

struct ConfirmButtons: View {
    @Environment(\.palette) private var palette
    let confirmTitle: LocalizedStringKey
    var cancelTitle: LocalizedStringKey = "Отмена"
    /// Red for a removal; the accent for a harmless choice (the dialog before a junk scan).
    var destructive = true
    var cancelID = "confirm.cancel"
    var confirmID = "confirm.ok"
    /// Esc presses the left button. Off when that button is a choice of its own, not «Отмена»: Esc then calls `escape`
    /// (`ConfirmOverlay`'s own `onKeyPress` never gets the key: nothing in the sheet holds keyboard focus).
    var cancelOnEscape = true
    var escape: (() -> Void)?
    /// The right button does not close the sheet (it sends the user to System Settings): pressing it locks nothing.
    var confirmKeepsOpen = false
    let cancel: () -> Void
    let confirm: () -> Void
    /// Pressed once: both buttons stay disabled while the sheet fades out, so a double click or a second Return
    /// cannot start the action twice (the models guard against it too).
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard !pressed else { return }
                pressed = true
                cancel()
            } label: {
                Text(cancelTitle)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle.rounded(12))
            .keyboardShortcut(cancelOnEscape ? .cancelAction : nil)
            .accessibilityIdentifier(cancelID)
            Button {
                guard !pressed else { return }
                if !confirmKeepsOpen { pressed = true }
                confirm()
            } label: {
                Text(confirmTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(destructive ? Color.white : palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(HoverFill(color: destructive ? palette.danger : palette.accent,
                                          shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle.rounded(12))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(confirmID)
        }
        .background {
            if !cancelOnEscape, let escape {
                Button(action: escape) { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .disabled(pressed)
        .padding(.top, 24)
    }
}
