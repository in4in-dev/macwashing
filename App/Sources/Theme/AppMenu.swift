import AppKit
import SwiftUI

// The app's own menus: the look of the gear's menu in the menu bar popup (a dark sheet, hover rows, an icon or a check
// in front of the title) for dropdowns (`AppMenuButton`) and right-click menus (`appContextMenu`), instead of the
// system menu. The same on every macOS: the surface is a solid sheet, not glass. A menu opens in a borderless panel of
// its own (`AppMenuPresenter`), so it is never clipped by a card or a scroll view, and works like a menu: a click
// outside, Esc, another app or window closes it; ↑ ↓ Home End move, Return or Space picks.
//
// Not replaced: the multi-selection menus of the Storage table and list (`contextMenu(forSelectionType:)`) — the system
// decides there which rows the menu is for, shows the item shortcuts (⌘⌫) and the UI tests drive them as menu items —
// and the menu bar menus (`CommandMenu`).

/// One row of an app menu.
struct AppMenuItem {
    var title: Text
    var symbol: String?
    /// Shown with a check in front (the current choice of a dropdown).
    var checked = false
    var destructive = false
    var enabled = true
    var identifier: String?
    var action: () -> Void

    init(_ title: LocalizedStringKey, symbol: String? = nil, checked: Bool = false, destructive: Bool = false,
         enabled: Bool = true, identifier: String? = nil, action: @escaping () -> Void) {
        self.init(text: Text(title), symbol: symbol, checked: checked, destructive: destructive, enabled: enabled,
                  identifier: identifier, action: action)
    }

    /// A title from data (a language's own name, a time): never parsed as a format.
    init(verbatim title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true,
         identifier: String? = nil, action: @escaping () -> Void) {
        self.init(text: Text(verbatim: title), symbol: symbol, checked: checked, enabled: enabled, identifier: identifier,
                  action: action)
    }

    init(text: Text, symbol: String? = nil, checked: Bool = false, destructive: Bool = false, enabled: Bool = true,
         identifier: String? = nil, action: @escaping () -> Void) {
        self.title = text
        self.symbol = symbol
        self.checked = checked
        self.destructive = destructive
        self.enabled = enabled
        self.identifier = identifier
        self.action = action
    }
}

/// The line between groups of rows.
struct AppMenuDivider {}

enum AppMenuEntry {
    case item(AppMenuItem)
    case divider
}

@resultBuilder
enum AppMenuBuilder {
    static func buildExpression(_ item: AppMenuItem) -> [AppMenuEntry] { [.item(item)] }
    static func buildExpression(_ divider: AppMenuDivider) -> [AppMenuEntry] { [.divider] }
    static func buildExpression(_ entries: [AppMenuEntry]) -> [AppMenuEntry] { entries }
    static func buildBlock(_ parts: [AppMenuEntry]...) -> [AppMenuEntry] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [AppMenuEntry]?) -> [AppMenuEntry] { part ?? [] }
    static func buildEither(first: [AppMenuEntry]) -> [AppMenuEntry] { first }
    static func buildEither(second: [AppMenuEntry]) -> [AppMenuEntry] { second }
    static func buildArray(_ parts: [[AppMenuEntry]]) -> [AppMenuEntry] { parts.flatMap { $0 } }

    /// No divider at the start, at the end or twice in a row (a group left empty by a condition).
    static func buildFinalResult(_ entries: [AppMenuEntry]) -> [AppMenuEntry] {
        var result: [AppMenuEntry] = []
        for entry in entries {
            if case .divider = entry, result.isEmpty || result.last.map(isDivider) == true { continue }
            result.append(entry)
        }
        while let last = result.last, isDivider(last) { result.removeLast() }
        return result
    }

    private static func isDivider(_ entry: AppMenuEntry) -> Bool {
        if case .divider = entry { return true }
        return false
    }
}

// MARK: Surface

/// The menu itself: the gear menu's sheet with its rows. `highlighted` is the row under the mouse or picked by the
/// arrow keys; one at a time.
struct AppMenuSurface: View {
    @Environment(\.palette) private var palette
    let entries: [AppMenuEntry]
    @Binding var highlighted: Int?
    var minWidth: CGFloat = AppMenuMetrics.minWidth
    /// Taller than this, the rows scroll (with the checked one in view).
    var maxHeight: CGFloat?
    let pick: (AppMenuItem) -> Void

    var body: some View {
        Group {
            if let maxHeight, AppMenuMetrics.height(of: entries) > maxHeight {
                ScrollViewReader { proxy in
                    ScrollView {
                        rows
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: maxHeight)
                    .onAppear {
                        if let checked = entries.firstIndex(where: { if case .item(let item) = $0 { item.checked } else { false } }) {
                            proxy.scrollTo(checked, anchor: .center)
                        }
                    }
                    .onChange(of: highlighted) { _, index in
                        if let index { proxy.scrollTo(index) }
                    }
                }
            } else {
                rows
            }
        }
        // As wide as the longest title (translations differ), at least `minWidth`.
        .frame(minWidth: minWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.cardStroke))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var rows: some View {
        let checkable = entries.contains { if case .item(let item) = $0 { item.checked } else { false } }
        return VStack(spacing: AppMenuMetrics.spacing) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                switch entry {
                case .divider:
                    Rectangle()
                        .fill(palette.line)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .accessibilityHidden(true)
                case .item(let item):
                    row(item, index: index, checkable: checkable)
                        .id(index)
                }
            }
        }
        .padding(AppMenuMetrics.padding)
    }

    private func row(_ item: AppMenuItem, index: Int, checkable: Bool) -> some View {
        let lit = highlighted == index && item.enabled
        return Button { pick(item) } label: {
            HStack(spacing: 10) {
                if checkable || item.symbol != nil {
                    // The slot stays when empty: the titles of a list of choices line up.
                    ZStack {
                        Color.clear
                        if item.checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(palette.accent)
                        } else if let symbol = item.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(item.destructive ? palette.danger : palette.muted)
                        }
                    }
                    .frame(width: 16)
                }
                item.title
                    .font(.system(size: 13))
                    .foregroundStyle(item.destructive ? Color(hex: 0xFF9EA0) : palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: AppMenuMetrics.rowHeight, maxHeight: AppMenuMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            // The gear menu's hover: a faint light on the row.
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(lit ? Color.white.opacity(0.04) : .clear)
            )
            .animation(.easeOut(duration: 0.18), value: lit)
            .opacity(item.enabled ? 1 : 0.4)
        }
        .buttonStyle(.row)
        .disabled(!item.enabled)
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .accessibilityAddTraits(item.checked ? .isSelected : [])
        .modifier(OptionalIdentifier(identifier: item.identifier))
    }
}

private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

enum AppMenuMetrics {
    static let rowHeight: CGFloat = 30
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 5
    static let dividerHeight: CGFloat = 7
    static let minWidth: CGFloat = 200
    /// Room around the sheet for its shadow inside the panel.
    static let margin = EdgeInsets(top: 12, leading: 20, bottom: 28, trailing: 20)

    static func height(of entries: [AppMenuEntry]) -> CGFloat {
        let rows = entries.reduce(CGFloat(0)) { sum, entry in
            if case .divider = entry { sum + dividerHeight } else { sum + rowHeight }
        }
        return rows + spacing * CGFloat(max(entries.count - 1, 0)) + padding * 2
    }
}

// MARK: Triggers

/// A button that opens an app menu under itself (a dropdown in place of `Menu`). Style it as any button
/// (`.buttonStyle(.plain)`, `.hover`); the menu takes the button's palette.
struct AppMenuButton<Label: View>: View {
    @Environment(\.palette) private var palette
    private let entries: () -> [AppMenuEntry]
    private let label: Label
    private let minWidth: CGFloat
    @State private var anchor = AppMenuAnchor()

    init(minWidth: CGFloat = AppMenuMetrics.minWidth, @AppMenuBuilder entries: @escaping () -> [AppMenuEntry],
         @ViewBuilder label: () -> Label) {
        self.entries = entries
        self.label = label()
        self.minWidth = minWidth
    }

    var body: some View {
        Button {
            AppMenuPresenter.shared.toggle(entries(), below: anchor, palette: palette, minWidth: minWidth)
        } label: {
            label
        }
        .background(AppMenuAnchorView(anchor: anchor))
        .accessibilityAddTraits(.isButton)
    }
}

extension View {
    /// The app's right-click (and Control-click) menu in place of `.contextMenu`; VoiceOver opens it with its «show
    /// menu» action. Only clicks reaching this view open it: whatever lies on top (a floating bar, a sheet) keeps them.
    func appContextMenu(@AppMenuBuilder _ entries: @escaping () -> [AppMenuEntry]) -> some View {
        modifier(AppContextMenu(entries: entries))
    }
}

private struct AppContextMenu: ViewModifier {
    @Environment(\.palette) private var palette
    let entries: () -> [AppMenuEntry]
    @State private var anchor = AppMenuAnchor()

    func body(content: Content) -> some View {
        content
            .overlay(RightClickCatcher(anchor: anchor) { point in
                AppMenuPresenter.shared.show(entries(), at: point, from: anchor, palette: palette)
            })
            .accessibilityAction(.showMenu) {
                AppMenuPresenter.shared.show(entries(), below: anchor, palette: palette, minWidth: AppMenuMetrics.minWidth)
            }
    }
}

/// The AppKit view a menu is placed against.
@MainActor
final class AppMenuAnchor {
    weak var view: NSView?

    /// The view's frame on screen (AppKit coordinates: origin at the bottom left).
    var screenFrame: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct AppMenuAnchorView: NSViewRepresentable {
    let anchor: AppMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// Takes no clicks: only marks where the menu goes.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Lies over the view and takes only right clicks and Control-clicks; every other event (clicks, hover, scrolling)
/// goes through to what is under it.
private struct RightClickCatcher: NSViewRepresentable {
    let anchor: AppMenuAnchor
    let open: (NSPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.open = open
        anchor.view = view
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.open = open
        anchor.view = view
    }

    final class CatcherView: NSView {
        var open: ((NSPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let menuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return menuClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            guard let window else { return }
            open?(window.convertPoint(toScreen: event.locationInWindow))
        }
    }
}

// MARK: Presenting

/// Shows one app menu at a time in a borderless panel over the window.
@MainActor
final class AppMenuPresenter {
    static let shared = AppMenuPresenter()

    @Observable
    @MainActor
    final class State {
        var entries: [AppMenuEntry] = []
        var highlighted: Int?
        var maxHeight: CGFloat?
        var minWidth: CGFloat = AppMenuMetrics.minWidth
    }

    private let state = State()
    private var panel: MenuPanel?
    private weak var parent: NSWindow?
    private weak var openedFrom: NSView?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    var isOpen: Bool { panel?.isVisible == true }

    /// A dropdown: under the view (over it when there is no room below), opened again from the same view — closed.
    func toggle(_ entries: [AppMenuEntry], below anchor: AppMenuAnchor, palette: Palette, minWidth: CGFloat) {
        if isOpen, let view = anchor.view, openedFrom === view {
            close()
            return
        }
        show(entries, below: anchor, palette: palette, minWidth: minWidth)
    }

    func show(_ entries: [AppMenuEntry], below anchor: AppMenuAnchor, palette: Palette, minWidth: CGFloat) {
        guard let frame = anchor.screenFrame else { return }
        present(entries, from: anchor, palette: palette, minWidth: minWidth) { size, screen in
            let x = min(max(frame.minX, screen.minX + 4), screen.maxX - size.width - 4)
            let below = frame.minY - 4 - screen.minY
            let above = screen.maxY - frame.maxY - 4
            if below >= size.height || below >= above {
                return NSPoint(x: x, y: frame.minY - 4 - min(size.height, below))
            }
            return NSPoint(x: x, y: frame.maxY + 4)
        } room: { screen in
            max(frame.minY - screen.minY, screen.maxY - frame.maxY) - 12
        }
    }

    /// A context menu: its top left corner at the click, moved left or up to stay on the screen.
    func show(_ entries: [AppMenuEntry], at point: NSPoint, from anchor: AppMenuAnchor, palette: Palette) {
        present(entries, from: anchor, palette: palette, minWidth: AppMenuMetrics.minWidth) { size, screen in
            let x = point.x + size.width + 2 <= screen.maxX ? point.x + 2 : point.x - size.width - 2
            let y = point.y - size.height - 2 >= screen.minY ? point.y - size.height - 2 : point.y + 2
            return NSPoint(x: max(x, screen.minX + 4), y: min(max(y, screen.minY + 4), screen.maxY - size.height - 4))
        } room: { screen in
            screen.height - 16
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let panel, panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Keys go back to the window the menu was opened from.
        if NSApp.isActive, let parent, parent.isVisible { parent.makeKey() }
        state.highlighted = nil
        openedFrom = nil
    }

    // MARK: Private

    private func present(_ entries: [AppMenuEntry], from anchor: AppMenuAnchor, palette: Palette, minWidth: CGFloat,
                         origin: (NSSize, NSRect) -> NSPoint, room: (NSRect) -> CGFloat) {
        close()
        guard !entries.isEmpty, let view = anchor.view, let window = view.window,
              let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        state.entries = entries
        state.highlighted = nil
        state.minWidth = minWidth
        state.maxHeight = max(room(screen), AppMenuMetrics.rowHeight * 4)

        // The sheet's size: as wide as its longest row, as tall as its rows or the room there is.
        let measure = NSHostingView(rootView: AppMenuSurface(entries: entries, highlighted: .constant(nil), minWidth: minWidth) { _ in }
            .environment(\.palette, palette))
        let natural = measure.fittingSize
        let sheet = NSSize(width: ceil(natural.width), height: ceil(min(AppMenuMetrics.height(of: entries), state.maxHeight ?? .infinity)))
        let margin = AppMenuMetrics.margin
        let bottomLeft = origin(sheet, screen)
        let frame = NSRect(x: bottomLeft.x - margin.leading, y: bottomLeft.y - margin.bottom,
                           width: sheet.width + margin.leading + margin.trailing,
                           height: sheet.height + margin.top + margin.bottom)

        let panel = self.panel ?? makePanel()
        let content = AppMenuPanelContent(state: state) { [weak self] item in self?.pick(item) }
            .environment(\.palette, palette)
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        NSAccessibility.post(element: panel, notification: .created)

        parent = window
        openedFrom = view
        watch(panel: panel, parent: window)
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel
        return panel
    }

    private func watch(panel: NSPanel, parent: NSWindow) {
        // A click anywhere but the menu closes it and goes nowhere else, as with the system's menus.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            let onMenu = event.window === panel
            let point = event.locationInWindow
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                if onMenu, self.sheetContains(point, panel: panel) { return false }
                self.close()
                return true
            }
            return swallow ? nil : event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let key = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                return self.handle(key: key, command: command)
            }
            return handled ? nil : event
        }) { monitors.append(keys) }
        let center = NotificationCenter.default
        let closing: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: closing),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main, using: closing),
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main, using: closing),
            center.addObserver(forName: NSWindow.didMoveNotification, object: parent, queue: .main, using: closing),
            center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main, using: closing),
        ]
    }

    private func sheetContains(_ point: NSPoint, panel: NSPanel) -> Bool {
        let margin = AppMenuMetrics.margin
        let size = panel.frame.size
        return NSRect(x: margin.leading, y: margin.bottom, width: size.width - margin.leading - margin.trailing,
                      height: size.height - margin.top - margin.bottom).contains(point)
    }

    /// The menu's keys; every other key is swallowed while it is open, as with the system's menus.
    private func handle(key: UInt16, command: Bool) -> Bool {
        let enabled = state.entries.indices.filter { if case .item(let item) = state.entries[$0] { item.enabled } else { false } }
        guard !enabled.isEmpty else { close(); return true }
        let current = state.highlighted.flatMap(enabled.firstIndex)
        switch key {
        case 53: // Esc
            close()
        case 126: // ↑
            state.highlighted = enabled[current.map { max($0 - 1, 0) } ?? enabled.count - 1]
        case 125: // ↓
            state.highlighted = enabled[current.map { min($0 + 1, enabled.count - 1) } ?? 0]
        case 115, 116: // Home, Page Up
            state.highlighted = enabled.first
        case 119, 121: // End, Page Down
            state.highlighted = enabled.last
        case 36, 76, 49: // Return, Enter, Space
            if let index = state.highlighted, case .item(let item) = state.entries[index], item.enabled { pick(item) }
        case 48: // Tab
            close()
        default:
            if command {
                close()
                return false
            }
        }
        return true
    }

    private func pick(_ item: AppMenuItem) {
        guard item.enabled else { return }
        close()
        item.action()
    }
}

private struct AppMenuPanelContent: View {
    @Bindable var state: AppMenuPresenter.State
    let pick: (AppMenuItem) -> Void

    var body: some View {
        AppMenuSurface(entries: state.entries, highlighted: $state.highlighted, minWidth: state.minWidth,
                       maxHeight: state.maxHeight, pick: pick)
            .padding(AppMenuMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .preferredColorScheme(.dark)
    }
}

/// Takes the keys while it is open, without making the app active or taking the window's title bar look away.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
