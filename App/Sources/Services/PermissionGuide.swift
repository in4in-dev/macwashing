import AppKit
import os
import Security
import SwiftUI

/// The tip next to System Settings while the user gives a permission there: a small
/// floating card beside the Settings window with the steps, the app's icon to drag into a list, and «Готово» once the
/// permission is there — then MacWashing comes back to the front. It follows the Settings window, shows only while
/// System Settings is in front and goes away when Settings quits, on «×», or after 15 minutes.
///
/// Where the Settings window is comes from `CGWindowListCopyWindowInfo`: bounds and owner need no permission (only
/// window titles need Screen Recording, and they are not read).
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "guide")

    enum Kind: Equatable {
        /// System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background.
        case helper
        /// System Settings ▸ Privacy & Security ▸ Full Disk Access.
        case fullDiskAccess
    }

    /// Which edge of the card has the arrow: the Settings window is on that side.
    enum Arrow { case left, right, none }

    @MainActor
    @Observable
    final class State {
        var kind: Kind = .helper
        var granted = false
        var arrow: Arrow = .none
    }

    private static let settingsBundleID = "com.apple.systempreferences"
    /// The card's width; its height follows the text (`hosting.fittingSize`).
    private static let width: CGFloat = 280
    private static let lifetime: TimeInterval = 15 * 60

    private let state = State()
    private var panel: NSPanel?
    private var hosting: NSHostingView<PermissionGuideCard>?
    private var task: Task<Void, Never>?
    private var isGranted: () -> Bool = { false }

    /// Shows the tip for `kind` (replacing one already shown); `granted` tells when the permission is there.
    func show(_ kind: Kind, granted: @escaping () -> Bool) {
        #if DEBUG
        // The UI-test sandbox opens no System Settings: nothing to stand next to.
        if ProcessInfo.processInfo.environment["MW_FAKE_HOME"] != nil { return }
        #endif
        guard !granted() else {
            Self.log.notice("tip not shown: already granted")
            return
        }
        Self.log.notice("tip shown: \(String(describing: kind), privacy: .public)")
        state.kind = kind
        state.granted = false
        isGranted = granted
        let panel = panel ?? makePanel()
        self.panel = panel
        task?.cancel()
        task = Task { [weak self] in await self?.follow() }
    }

    func close() {
        task?.cancel()
        task = nil
        panel?.orderOut(nil)
    }

    // MARK: Following System Settings

    /// The Settings window found by the last full look: its id, for the cheap per-frame query.
    private var windowID: CGWindowID?
    /// The card's height for the current content (`hosting.fittingSize` costs a layout: not every frame).
    private var height: CGFloat?
    private var lastFrame: CGRect?

    /// Every frame (~60 a second) only the known Settings window is asked where it is, so the card keeps up with a
    /// drag; twice a second the full look: is Settings still there and in front, which window, is the permission given.
    private func follow() async {
        let started = Date()
        var seenSettings = false
        var inFront = false
        var pids: Set<pid_t> = []
        var frame = 0
        windowID = nil
        height = nil
        lastFrame = nil
        while !Task.isCancelled {
            if frame % 30 == 0 {
                let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID)
                if settings.isEmpty {
                    // Settings quit (or never opened within a few seconds): nothing left to point at.
                    if seenSettings || Date().timeIntervalSince(started) > 10 { break }
                } else {
                    seenSettings = true
                }
                if Date().timeIntervalSince(started) > Self.lifetime { break }
                pids = Set(settings.map(\.processIdentifier))
                if isGranted() {
                    state.granted = true
                    height = nil
                    place(Self.frontWindow(pids: pids))
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    panel?.orderOut(nil)
                    task = nil
                    AppWindow.show()
                    return
                }
                inFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID
                if inFront {
                    let found = Self.frontWindow(pids: pids)
                    windowID = found?.id
                    place(found)
                } else {
                    panel?.orderOut(nil)
                    lastFrame = nil
                }
            } else if inFront, let windowID {
                // Gone (closed, or another Settings window took its place): the next full look finds the new one.
                if let bounds = Self.bounds(of: windowID) { place((windowID, bounds)) } else { self.windowID = nil }
            }
            frame += 1
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard !Task.isCancelled else { return }
        panel?.orderOut(nil)
        task = nil
    }

    private func place(_ window: (id: CGWindowID, frame: CGRect)?) {
        guard let panel else { return }
        let target = window?.frame
        let screen = target.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let height = self.height ?? max(hosting?.fittingSize.height ?? 200, 120)
        self.height = height
        let size = CGSize(width: Self.width, height: height)
        let spot = Self.placement(size: size, target: target, screen: visible)
        if state.arrow != spot.arrow {
            state.arrow = spot.arrow
        }
        let next = CGRect(origin: spot.origin, size: size)
        if next != lastFrame {
            panel.setFrame(next, display: true)
            lastFrame = next
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Window coordinates count from the top left of the primary screen; AppKit's from its bottom left.
    private static func appKitRect(_ bounds: NSDictionary) -> CGRect? {
        guard let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The frontmost normal window of System Settings.
    private static func frontWindow(pids: Set<pid_t>) -> (id: CGWindowID, frame: CGRect)? {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = appKitRect(bounds), frame.width > 300, frame.height > 200
            else { continue }
            return (id, frame)
        }
        return nil
    }

    /// Where one known window is now; nil once it is gone.
    private static func bounds(of id: CGWindowID) -> CGRect? {
        // The array holds the window numbers themselves, not CFNumbers.
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = CFArrayCreate(kCFAllocatorDefault, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) ?? true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return appKitRect(bounds)
    }

    /// Beside the window when there is room (right first, then left), its top a little below the window's title;
    /// otherwise inside the window's top right corner; with no window yet, the screen's top right corner.
    nonisolated static func placement(size: CGSize, target: CGRect?, screen: CGRect, gap: CGFloat = 14) -> (origin: CGPoint, arrow: Arrow) {
        func clampedY(_ y: CGFloat) -> CGFloat { min(max(y, screen.minY + 8), screen.maxY - size.height - 8) }
        guard let target else {
            return (CGPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20), .none)
        }
        let y = clampedY(target.maxY - 64 - size.height)
        if target.maxX + gap + size.width <= screen.maxX {
            return (CGPoint(x: target.maxX + gap, y: y), .left)
        }
        if target.minX - gap - size.width >= screen.minX {
            return (CGPoint(x: target.minX - gap - size.width, y: y), .right)
        }
        return (CGPoint(x: min(target.maxX, screen.maxX) - size.width - 16, y: y), .none)
    }

    private func makePanel() -> NSPanel {
        let panel = GuidePanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: PermissionGuideCard(state: state, developer: Self.developerName,
                                                                  close: { [weak self] in self?.close() }))
        self.hosting = hosting
        panel.contentView = hosting
        return panel
    }
}

extension PermissionGuide {
    /// The name in this build's signing certificate («Developer ID Application: Jane Doe (TEAMID)» →
    /// «Jane Doe»): macOS 26 lists background items under it, not under the app's name.
    static let developerName: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else { return nil }
        return developerName(fromCertificate: summary)
    }()

    /// «Developer ID Application: Jane Doe (TEAMID)» → «Jane Doe»; nil for anything else.
    nonisolated static func developerName(fromCertificate summary: String) -> String? {
        guard let colon = summary.range(of: ": ") else { return nil }
        var name = summary[colon.upperBound...]
        if let team = name.range(of: " (", options: .backwards) { name = name[..<team.lowerBound] }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Takes clicks («×», dragging the icon) without making MacWashing the active app.
private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The card itself: what to switch on, the icon to drag into the list (Full Disk Access) and the waiting line.
struct PermissionGuideCard: View {
    let state: PermissionGuide.State
    let developer: String?
    let close: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            arrow(.left)
            card
            arrow(.right)
        }
        .padding(.vertical, 6)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text(state.kind == .helper ? "Разрешите помощника" : "Полный доступ к диску")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(palette.faint)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Скрыть подсказку"))
            }
            if !state.granted {
                SettingsRowPreview(section: sectionTitle, name: rowName)
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(palette.field))
                            .overlay(Circle().strokeBorder(palette.cardStroke))
                        step
                            .font(.system(size: 12))
                            .foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 10)
            if state.kind == .fullDiskAccess && !state.granted {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                    Text("Перетащите значок в список, если MacWashing там нет")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .padding(.top, 10)
            }
            HStack(spacing: 7) {
                if state.granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                    Text("Готово").foregroundStyle(palette.text).fontWeight(.semibold)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Жду разрешения…").foregroundStyle(palette.faint)
                }
            }
            .font(.system(size: 12))
            .padding(.top, 12)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.sheet))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .animation(Motion.spring, value: state.granted)
    }

    /// A small triangle toward the Settings window, level with its title area.
    @ViewBuilder
    private func arrow(_ side: PermissionGuide.Arrow) -> some View {
        if state.arrow == side {
            // Over the card's edge by a point, with the card's stroke on its two outer sides only, so it reads as one
            // shape on a dark window behind it too.
            ArrowShape(pointsLeft: side == .left)
                .fill(palette.sheet)
                .overlay(ArrowShape(pointsLeft: side == .left, closed: false).stroke(.white.opacity(0.12)))
                .frame(width: 9, height: 18)
                .offset(x: side == .left ? 1 : -1)
                .zIndex(1)
                .padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The list's heading as System Settings shows it.
    private var sectionTitle: Text {
        switch state.kind {
        case .helper:
            if #available(macOS 26, *) { Text("Фоновая активность приложений") } else { Text("Разрешить в фоне") }
        case .fullDiskAccess:
            Text("Полный доступ к диску")
        }
    }

    /// The row's name: macOS 26 lists background items under the developer.
    private var rowName: String {
        if state.kind == .helper, #available(macOS 26, *), let developer { return developer }
        return "MacWashing"
    }

    private var steps: [Text] {
        switch state.kind {
        case .helper:
            // macOS 26 groups background items by developer, under «Фоновая активность приложений».
            if #available(macOS 26, *), let developer {
                [Text("Найдите список «Фоновая активность приложений»."),
                 Text("Включите переключатель у «\(developer)» — так macOS называет MacWashing."),
                 Text("Подтвердите паролем или Touch ID.")]
            } else {
                [Text("Найдите список «Разрешить в фоне»."),
                 Text("Включите переключатель у MacWashing."),
                 Text("Подтвердите паролем или Touch ID.")]
            }
        case .fullDiskAccess:
            [Text("Включите переключатель у MacWashing."),
             Text("Подтвердите паролем или Touch ID."),
             Text("На вопрос «Выйти и открыть снова» можно ответить «Позже»: MacWashing увидит доступ и так.")]
        }
    }
}

/// The row the user looks for, drawn as System Settings draws it (light or dark, as the system is now): the list's
/// heading, the app's icon and name, and a switch that keeps flipping on, ringed in the app's accent.
private struct SettingsRowPreview: View {
    let section: Text
    let name: String
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// System Settings follows the system, not MacWashing's own dark look.
    private let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            section
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
            TimelineView(.periodic(from: .now, by: 1.3)) { context in
                let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 1.3) % 2 == 1
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                    Text(verbatim: name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(dark ? Color.white : Color.black)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    ZStack(alignment: on ? .trailing : .leading) {
                        Capsule().fill(on ? Color(nsColor: .controlAccentColor) : (dark ? Color(white: 0.32) : Color(white: 0.86)))
                        Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
                    }
                    .frame(width: 32, height: 19)
                    .padding(3)
                    .overlay(Capsule().strokeBorder(palette.accent, lineWidth: 2))
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(dark ? Color(white: 0.17) : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dark ? Color(white: 0.11) : Color(white: 0.93)))
        .accessibilityElement(children: .combine)
    }
}

private struct ArrowShape: Shape {
    let pointsLeft: Bool
    /// Open: only the two sides away from the card (for the stroke).
    var closed = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if closed { path.closeSubpath() }
        return path
    }
}
