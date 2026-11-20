import AppKit
import MacWashingKit
import SwiftUI

/// The menu bar item's icon: a solid water drop with two bubbles beside it, as a template image, so the menu bar
/// tints it for light and dark. `badged` adds a dot at the lower right, cut free of the drop: an update is available.
enum MenuBarIcon {
    static let image = make(badged: false)
    static let badged = make(badged: true)

    private static func make(badged: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // The drop: the tip at the top, the round bottom on the left of the canvas.
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: 6.86, y: 1.73))
            drop.curve(to: NSPoint(x: 12.12, y: 11.32),
                       controlPoint1: NSPoint(x: 8.36, y: 4.27), controlPoint2: NSPoint(x: 12.12, y: 7.56))
            drop.curve(to: NSPoint(x: 6.86, y: 16.58),
                       controlPoint1: NSPoint(x: 12.12, y: 14.23), controlPoint2: NSPoint(x: 9.77, y: 16.58))
            drop.curve(to: NSPoint(x: 1.6, y: 11.32),
                       controlPoint1: NSPoint(x: 3.95, y: 16.58), controlPoint2: NSPoint(x: 1.6, y: 14.23))
            drop.curve(to: NSPoint(x: 6.86, y: 1.73),
                       controlPoint1: NSPoint(x: 1.6, y: 7.56), controlPoint2: NSPoint(x: 5.36, y: 4.27))
            drop.close()
            drop.fill()
            // The glint on the drop's lower left, cut out of it.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            let glint = NSBezierPath()
            glint.appendArc(withCenter: NSPoint(x: 6.9, y: 11.3), radius: 3.1, startAngle: 105, endAngle: 165)
            glint.lineWidth = 1.4
            glint.lineCapStyle = .round
            glint.stroke()
            if badged {
                // Room for the dot: a clear ring around it.
                NSBezierPath(ovalIn: NSRect(x: 10.2, y: 10.2, width: 8.6, height: 8.6)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            // The bubbles on the upper right.
            NSBezierPath(ovalIn: NSRect(x: 13.4, y: 2.6, width: 3.2, height: 3.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: 7.2, width: 2, height: 2)).fill()
            if badged {
                NSBezierPath(ovalIn: NSRect(x: 11.9, y: 11.9, width: 5.2, height: 5.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacWashing"
        return image
    }
}

/// The popup of the menu bar item: the disks, the last cleaning or auto-clean, an available update, the way back to
/// the window; a gear with «Настройки» and «Закрыть программу» in the app's own dropdown (`GearMenu`, not a system
/// menu). Glass on macOS 26 (the system's own window), the shaded material before it (`menuBarSurface`).
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @State private var volumes: [Volume] = []
    @State private var gearOpen: Bool

    init(gearOpen: Bool = false) {
        _gearOpen = State(initialValue: gearOpen)
    }
    private let palette = Palette(section: .junk)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(volumes) { volume in
                diskRow(volume)
            }
            cleaningCard
            if let version = model.updates.availableVersion {
                updateRow(version)
            }
            openButton
        }
        .padding(14)
        .frame(width: 320)
        .overlay(alignment: .topTrailing) { gearDropdown }
        .menuBarSurface()
        .environment(\.palette, palette)
        .foregroundStyle(palette.text)
        .preferredColorScheme(.dark)
        .onAppear { volumes = Volume.mounted() }
        .onDisappear { gearOpen = false }
    }

    /// The gear's dropdown over the panel; a click anywhere else closes it.
    @ViewBuilder
    private var gearDropdown: some View {
        if gearOpen {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .onTapGesture { setGear(false) }
                GearMenu(update: model.updates.availableVersion.map { _ in {
                    setGear(false)
                    model.updates.installNow()
                } }, settings: {
                    setGear(false)
                    open(.settings)
                }, quit: { NSApp.terminate(nil) })
                .padding(.top, 14 + 28 + 4)
                .padding(.trailing, 10)
                .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private func setGear(_ open: Bool) {
        withAnimation(Motion.bouncy) { gearOpen = open }
    }

    private var header: some View {
        HStack(spacing: 9) {
            WasherIcon()
                .frame(width: 22, height: 22)
            Text(verbatim: "MacWashing")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Button { setGear(!gearOpen) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(gearOpen ? palette.text : palette.muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(gearOpen ? palette.selection : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.hover)
            .accessibilityLabel(Text("Настройки"))
            .accessibilityIdentifier("menubar.gear")
        }
    }

    private func diskRow(_ volume: Volume) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(verbatim: volume.name)
            } icon: {
                Image(systemName: volume.isStartup ? "internaldrive" : volume.isNetwork ? "network" : "externaldrive")
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(palette.disk)
                        .frame(width: proxy.size.width * Double(volume.usedBytes) / Double(max(volume.totalBytes, 1)))
                }
            }
            .frame(height: 4)
            Text("Свободно \(ByteFormat.string(volume.availableBytes)) из \(ByteFormat.string(volume.totalBytes))")
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .monospacedDigit()
        }
        .padding(12)
        .card(palette, radius: 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.disk")
    }

    private var cleaningCard: some View {
        let autoClean = model.autoClean
        return VStack(alignment: .leading, spacing: 4) {
            if autoClean.running {
                // One indicator for the whole run: its scan and its removal are not told apart.
                HStack(spacing: 12) {
                    RunningRing()
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Автоочистка")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.faint)
                            .textCase(.uppercase)
                        Text("Выполняется…")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .accessibilityIdentifier("menubar.autoCleanRunning")
            } else if let last = autoClean.lastCleaning {
                Text(last.automatic ? "Автоочистка" : "Последняя очистка")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.faint)
                    .textCase(.uppercase)
                Text("Освобождено \(ByteFormat.string(last.freed))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Text(last.date, format: .dateTime.day().month().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
            } else {
                Text("Очисток ещё не было")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
            }
            if autoClean.isActive, !autoClean.running, let next = autoClean.nextRun {
                Text("Следующая автоочистка: \(next, format: .dateTime.day().month().hour().minute())")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card(palette, radius: 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.lastCleaning")
    }

    private func updateRow(_ version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(palette.accent)
            Text("Доступна версия \(version)")
                .font(.system(size: 12))
            Spacer()
            SecondaryButton(title: "Обновить", height: 28, action: model.updates.installNow)
                .accessibilityIdentifier("menubar.update")
        }
    }

    private var openButton: some View {
        Button { open(nil) } label: {
            Text("Открыть MacWashing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(HoverFill(color: palette.accent, shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle.rounded(10))
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("menubar.open")
    }

    private func open(_ section: AppSection?) {
        AppWindow.show()
        if let section { model.go(to: section) }
    }
}

/// The gear's dropdown: the app's dark sheet surface with hover rows instead of the system menu (`AppMenuSurface`, the
/// look of every menu of the app). «Установить обновление» leads while an update is available (the same as «Обновить»
/// in the popup). It lies in the popup itself, not in a panel of its own: the popup is a menu already.
private struct GearMenu: View {
    let update: (() -> Void)?
    let settings: () -> Void
    let quit: () -> Void
    @State private var highlighted: Int?

    var body: some View {
        AppMenuSurface(entries: entries, highlighted: $highlighted) { $0.action() }
    }

    @AppMenuBuilder private var entries: [AppMenuEntry] {
        if let update {
            AppMenuItem("Установить обновление", symbol: "arrow.down.circle", identifier: "menubar.menu.update", action: update)
        }
        AppMenuItem("Настройки", symbol: "gearshape", identifier: "menubar.menu.settings", action: settings)
        AppMenuDivider()
        AppMenuItem("Закрыть программу", symbol: "power", identifier: "menubar.menu.quit", action: quit)
    }
}

/// A running auto-clean: the progress screen's glowing accent arc on its track, turning round the auto-clean icon.
private struct RunningRing: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(palette.track, lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: palette.accent.opacity(0.6), radius: 4)
                .rotationEffect(.degrees(turning ? 270 : -90))
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
        .padding(1.5)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}
