import SwiftUI

@main
struct MacWashingApp: App {
    /// Nil only when the bundled rules database could not be opened (`databaseFailure` says why): without its keep
    /// rules no scan is safe, so the app shows what happened instead of starting.
    @State private var model: AppModel?
    private let databaseFailure: String?
    /// Launch, reopen and the menu bar life (Services/AppDelegate.swift).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        AppIconManager.renderAssetsIfAsked()
        #endif
        switch AppModel.openDatabase() {
        case .success(let database):
            let model = AppModel(database: database)
            _model = State(initialValue: model)
            AppWindow.model = model
            databaseFailure = nil
        case .failure(let failure):
            _model = State(initialValue: nil)
            databaseFailure = failure.description
        }
    }

    var body: some Scene {
        // The window drags by its title bar everywhere. On macOS 15+ it also has `windowBackgroundDragBehavior(.enabled)`
        // as before; macOS 14 has no such modifier and gets nothing instead: `isMovableByWindowBackground`, its AppKit
        // counterpart, would also drag the window by the sidebar and the empty parts of every screen, which macOS 26
        // does not do (App/UITests/WindowDragTests.swift). A scene modifier cannot be applied conditionally
        // (SceneBuilder has `if #available` but no `else`), so the window is declared once per system and exactly one
        // of the two exists at run time.
        if #available(macOS 15, *) {
            mainWindow()
                .windowBackgroundDragBehavior(.enabled)
        }
        sonomaWindow
        // The menu bar item: there while the app runs, also with the window open; with auto-clean on it can be turned off
        // in Settings. Read here, in the body, so that a change applies at once.
        let showsIcon = model?.menuBarIconShown == true
        MenuBarExtra(isInserted: Binding(get: { showsIcon }, set: { model?.showsMenuBarIcon = $0 })) {
            if let model {
                MenuBarPanel()
                    .environment(model)
                    .modifier(OpenWindowCatcher())
            }
        } label: {
            // A dot while an update is available (AppUpdates.availableVersion).
            Image(nsImage: model?.updates.availableVersion == nil ? MenuBarIcon.image : MenuBarIcon.badged)
                .modifier(OpenWindowCatcher())
                .accessibilityLabel(Text(verbatim: "MacWashing"))
        }
        .menuBarExtraStyle(.window)
    }

    /// The window on macOS 14 only: what `if #unavailable(macOS 15)` would build, spelled out with the same
    /// SceneBuilder functions, because the builder accepts no condition other than `#available`.
    private var sonomaWindow: some Scene {
        SceneBuilder.buildOptional(Self.isSonoma ? SceneBuilder.buildLimitedAvailability(mainWindow()) : nil)
    }

    private static var isSonoma: Bool {
        if #available(macOS 15, *) { return false }
        return true
    }

    private func mainWindow() -> some Scene {
        // `id`: the menu bar item opens it again after the close button closed it (AppWindow.show()).
        WindowGroup(id: "main") {
            Group {
                if let model {
                    RootView()
                        .environment(model)
                } else {
                    DatabaseFailureView(reason: databaseFailure ?? "")
                }
            }
            .frame(minWidth: 1040, minHeight: 680)
            .background(MainWindowReader())
            .modifier(OpenWindowCatcher())
            .onAppear { AppIconManager.apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // ⌘Q as the close button: to the menu bar while auto-clean is on (AppWindow.quitFromMenu()).
            CommandGroup(replacing: .appTermination) {
                Button("Закрыть программу") { AppWindow.quitFromMenu() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // The standard About panel adds the build number in brackets: an empty `.version` leaves it out.
            CommandGroup(replacing: .appInfo) {
                Button("О программе MacWashing") { NSApp.orderFrontStandardAboutPanel(options: [.version: ""]) }
            }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { model?.updates.checkNow() }
                    .disabled(model?.updates.isAvailable != true)
            }
            CommandGroup(after: .appSettings) {
                Button("Настройки…") { model?.go(to: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(model == nil)
            }
            CommandMenu("Раздел") {
                Group {
                    Button("Сборка мусора") { model?.go(to: .junk) }.keyboardShortcut("1", modifiers: .command)
                    Button("Большие файлы") { model?.go(to: .largeFiles) }.keyboardShortcut("2", modifiers: .command)
                    Button("Деинсталлятор") { model?.go(to: .uninstaller) }.keyboardShortcut("3", modifiers: .command)
                    Button("Хранилище") { model?.go(to: .disk) }.keyboardShortcut("4", modifiers: .command)
                    Button("Приватность") { model?.go(to: .privacy) }.keyboardShortcut("5", modifiers: .command)
                }
                .disabled(model == nil)
            }
        }
    }
}

/// The bundled rules database did not open: a broken or tampered install, never a state to work around.
struct DatabaseFailureView: View {
    let reason: String
    private let palette = Palette(section: .junk)

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 44))
                .foregroundStyle(palette.warning)
            Text("Не удалось открыть базу правил")
                .font(.system(size: 24, weight: .bold))
            Text("Без неё MacWashing не может отличить мусор от нужных файлов, поэтому ничего не сканирует. Установите программу заново, скачав её с GitHub.")
                .font(.system(size: 14))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text(verbatim: reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.faint)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Закрыть") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.text)
        .background(Color.black.opacity(0.85))
        .accessibilityIdentifier("databaseFailure")
    }
}
