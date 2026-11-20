import Foundation
import MacWashingKit
import MacWashingXPC
import Observation
import os
import ServiceManagement

/// Registers the privileged helper with `SMAppService` and talks to it over XPC.
@MainActor
@Observable
final class HelperClient {
    enum Status: Equatable {
        case notInstalled
        case needsApproval
        case enabled
        /// Running, but an older build than this app's (after an app update): reinstalling starts the new one.
        case outdated(running: String)
        /// Registered and allowed, but it does not answer: launchd can no longer start it (the registered app was
        /// replaced or rebuilt, its background item switched off and on). Reinstalling registers it again.
        case notResponding
        case unavailable
    }

    private(set) var status: Status = .notInstalled
    /// What the last `register()` threw (kept as is for the log).
    private var registerError: String?
    /// The registration error to show under the helper row: not the «Operation not permitted» macOS throws while the
    /// helper waits for approval, and nothing once it runs (`HelperRegistration.errorToShow`).
    var lastError: String? {
        HelperRegistration.errorToShow(thrown: registerError, awaitingApproval: status == .needsApproval, enabled: status == .enabled)
    }
    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    /// `log show --predicate 'subsystem == "com.ovvi.MacWashing"'`: what registration and the version check found.
    private static let log = Logger(subsystem: HelperConstants.appBundleID, category: "helper")

    init() {
        refresh()
    }

    func refresh() {
        let current: Status = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notRegistered: .notInstalled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
        // What launchd says cannot tell an old or silent helper from a working one: keep what the version check found.
        if current == .enabled, case .outdated = status { return }
        if current == .enabled, status == .notResponding { return }
        status = current
    }

    /// Asks the running helper its version; an older one is reported as outdated.
    func checkVersion() async {
        refresh()
        guard status == .enabled || status == .notResponding || { if case .outdated = status { true } else { false } }() else { return }
        var answer = await XPCExecutor().version()
        if answer == nil {
            // After an app update the old helper ends itself on the first connection (Helper/main.swift
            // `OwnExecutable`); launchd starts the new one for the next.
            try? await Task.sleep(for: .seconds(2))
            answer = await XPCExecutor().version()
        }
        guard let running = answer else {
            Self.log.error("helper version check: no answer over XPC")
            status = .notResponding
            return
        }
        Self.log.notice("helper version check: running \(running, privacy: .public), expected \(HelperConstants.version, privacy: .public)")
        status = running == HelperConstants.version ? .enabled : .outdated(running: running)
    }

    /// The helper is registered only from Applications: registered from a disk image or a download
    /// folder, its background-item record keeps pointing at that copy once it is gone, and launchd never starts it
    /// again (`copy_bundle_path`, exit 78) until `sfltool resetbtm` — «Переустановить» reuses the same record. Elsewhere
    /// the app offers to move itself first (and relaunches from there); declined, it says why there is no helper.
    private func placedForHelper() -> Bool {
        if AppLocation.isInApplications { return true }
        AppLocation.offerMoveIfNeeded()
        registerError = String(localized: "Помощника можно установить, только когда MacWashing лежит в папке «Программы». Переместите её туда и откройте оттуда.")
        Self.log.error("helper not registered: the app does not run from Applications")
        refresh()
        return false
    }

    /// Registers the daemon. macOS then asks the user to allow it in Login Items.
    func install() {
        guard placedForHelper() else { return }
        do {
            try service.register()
            registerError = nil
        } catch {
            registerError = error.localizedDescription
            Self.log.error("helper register failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        Self.log.notice("helper registered, status \(String(describing: self.status), privacy: .public)")
        if status == .needsApproval {
            SMAppService.openSystemSettingsLoginItems()
            // The tip beside Settings: which switch, and back to MacWashing once it is on.
            PermissionGuide.shared.show(.helper) { [weak self] in
                guard let self else { return true }
                refresh()
                return status == .enabled
            }
        }
    }

    func reinstall() {
        guard placedForHelper() else { return }
        try? service.unregister()
        status = .notInstalled
        install()
        Task { await checkVersion() }
    }

    /// The helper can remove system items. Removal is in every helper version, so an outdated one counts; everything
    /// added later (privacy resets, switching launch jobs) needs the current one (`isCurrent`).
    var canRemove: Bool {
        switch status {
        case .enabled, .outdated: true
        default: false
        }
    }

    /// The running helper is this app's version: every request is understood.
    var isCurrent: Bool { status == .enabled }

    /// An executor when the helper can remove (`canRemove`), otherwise nil (system items then fail with a clear reason).
    var executor: (any PrivilegedExecutor)? {
        canRemove ? XPCExecutor() : nil
    }
}

/// Sends requests to the helper. A new connection per request keeps it simple and Sendable.
struct XPCExecutor: PrivilegedExecutor, LaunchJobSwitching {
    /// How long a request may take before the helper is treated as stuck. Removing big folders (DerivedData, a VM
    /// bundle) really takes minutes; anything else answers at once.
    static let removalTimeout: TimeInterval = 600
    static let shortTimeout: TimeInterval = 30

    /// A reply as the app shows it: the helper's codes in the app's words (`HelperReply.adminRequired` — a standard
    /// user asked; since 1.9 the helper serves administrators only), anything else as it came.
    static func shown(_ reply: String) -> String {
        reply == HelperReply.adminRequired ? String(localized: "Для этого нужна учётная запись администратора") : reply
    }

    /// When the helper last failed to answer a ping: for a minute removal requests fail at once.
    private static let silentSince = Locked<Date?>(nil)

    /// Whether the helper answers at all, asked before a removal (10 s at most). A job launchd can no longer start (its
    /// background item switched off, the registered app rebuilt) takes requests and never answers: without this every
    /// batch would wait the whole removal timeout (cleaning would sit at one percent for minutes).
    private func helperAnswers() async -> Bool {
        if let since = Self.silentSince.load(), Date().timeIntervalSince(since) < 60 { return false }
        let answers = await version() != nil
        Self.silentSince.store(answers ? nil : Date())
        return answers
    }

    func remove(paths: [String], toTrash: Bool) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let fallback = Dictionary(paths.map { ($0, String(localized: "Помощник не отвечает")) }) { first, _ in first }
        guard await helperAnswers() else { return fallback }
        return await call(fallback: fallback, timeout: Self.removalTimeout) { proxy, finish in
            proxy.removeItems(atPaths: paths, toTrash: toTrash) { finish($0.mapValues(Self.shown)) }
        }
    }

    func removeChosen(paths: [String], toTrash: Bool) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let fallback = Dictionary(paths.map { ($0, String(localized: "Помощник не отвечает")) }) { first, _ in first }
        guard await helperAnswers() else { return fallback }
        return await call(fallback: fallback, timeout: Self.removalTimeout) { proxy, finish in
            proxy.removeChosenItems(atPaths: paths, toTrash: toTrash) { finish($0.mapValues(Self.shown)) }
        }
    }

    func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? {
        await call(fallback: String(localized: "Помощник не отвечает")) { proxy, finish in
            proxy.unloadLaunchDaemon(label: label, plistPath: plistPath, toTrash: toTrash) { finish($0.map(Self.shown)) }
        }
    }

    /// The running helper's version; nil when it does not answer.
    func version() async -> String? {
        await call(fallback: nil, timeout: 10) { proxy, finish in
            proxy.version { finish($0) }
        }
    }

    /// `tccutil reset` as root for a decision in the system TCC database. Nil on success.
    func resetPrivacyPermission(service: String, bundleID: String) async -> String? {
        await call(fallback: String(localized: "Помощник не отвечает")) { proxy, finish in
            proxy.resetPrivacyPermission(service: service, bundleID: bundleID) { finish($0.map(Self.shown)) }
        }
    }

    /// Startup section: turns a third-party job in /Library on or off (`launchctl` as root). Nil on success.
    func setLaunchJob(label: String, plistPath: String, enabled: Bool) async -> String? {
        await call(fallback: String(localized: "Помощник не отвечает")) { proxy, finish in
            proxy.setLaunchJob(label: label, plistPath: plistPath, enabled: enabled) { finish($0.map(Self.shown)) }
        }
    }

    /// The helper's Trash journal for this user: what it moved to the Trash and can put back. Empty when the helper
    /// does not answer or is older than 1.7 (it never kept one).
    func trashedItems() async -> [TrashJournalEntry] {
        let data: Data? = await call(fallback: nil) { proxy, finish in
            proxy.trashedItems { finish($0) }
        }
        return data.flatMap { try? JSONDecoder().decode([TrashJournalEntry].self, from: $0) } ?? []
    }

    /// Puts a journal entry's item back as root (`TrashRestore`). Nil on success, otherwise the helper's reason
    /// (`PutBackFailure(helperReply:)`). Cloning a big folder takes a while: the removal timeout.
    func putBack(itemID: String, conflict: PutBackConflict) async -> String? {
        let value = switch conflict {
        case .skip: TrashRestoreConflict.skip.rawValue
        case .replace: TrashRestoreConflict.replace.rawValue
        case .keepBoth: TrashRestoreConflict.keepBoth.rawValue
        }
        // Missing folders are made again, as on the user's route (Finder does the same).
        return await call(fallback: String(localized: "Помощник не отвечает"), timeout: Self.removalTimeout) { proxy, finish in
            proxy.putBack(itemID: itemID, conflict: value, createFolders: true) { finish($0.map(Self.shown)) }
        }
    }

    /// One request on a fresh connection. Whatever comes first wins: the reply, an XPC error, the connection going
    /// away, `timeout` (a stuck helper must not hold the caller — the Cleaner — forever), or the calling task being
    /// cancelled («Остановить» must not wait for a helper that may never answer).
    private func call<T: Sendable>(
        fallback: T,
        timeout: TimeInterval = XPCExecutor.shortTimeout,
        _ body: @escaping @Sendable (MacWashingHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async -> T {
        let cancel = Locked<(@Sendable () -> Void)?>(nil)
        return await withTaskCancellationHandler {
            await request(fallback: fallback, timeout: timeout, cancel: cancel, body)
        } onCancel: {
            cancel.load()?()
        }
    }

    private func request<T: Sendable>(
        fallback: T,
        timeout: TimeInterval,
        cancel: Locked<(@Sendable () -> Void)?>,
        _ body: @escaping @Sendable (MacWashingHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MacWashingHelperProtocol.self)
            connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
            let box = ConnectionBox(connection)
            let once = Once()
            let finish: @Sendable (T) -> Void = { value in
                guard once.claim() else { return }
                continuation.resume(returning: value)
                box.connection.invalidate()
            }
            connection.invalidationHandler = { finish(fallback) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(fallback) }
            cancel.store { finish(fallback) }
            // Cancelled before the handler above was in place.
            if Task.isCancelled {
                finish(fallback)
                return
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(fallback) }) as? MacWashingHelperProtocol else {
                finish(fallback)
                return
            }
            body(proxy, finish)
        }
    }
}

/// NSXPCConnection is thread-safe for `invalidate()`; the box only carries it into a Sendable closure.
private final class ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

/// Lets exactly one caller through.
final class Once: Sendable {
    private let state = Locked(false)
    func claim() -> Bool {
        state.withLock { used in
            defer { used = true }
            return !used
        }
    }
}

