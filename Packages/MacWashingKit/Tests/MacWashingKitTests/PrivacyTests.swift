import Foundation
import MacWashingXPC
import SQLite3
import Testing
@testable import MacWashingKit

/// A TCC.db built in a temp folder with the schema macOS 26 uses. Nothing here reads or writes the real databases.
struct FakeTCC {
    struct Row {
        var service: String
        var client: String
        var clientType: Int64 = 0
        var auth: Int64 = 2
        var reason: Int64 = 2
        var modified: Int64 = 1_760_000_000
        var indirect = "UNUSED"
    }

    /// `access` exactly as macOS 26 creates it (plus the tables it references).
    static let schema = """
        CREATE TABLE admin (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL);
        CREATE TABLE policies (id INTEGER NOT NULL PRIMARY KEY, bundle_id TEXT NOT NULL, uuid TEXT NOT NULL,
            display TEXT NOT NULL, UNIQUE (bundle_id, uuid));
        CREATE TABLE access (    service        TEXT        NOT NULL,     client         TEXT        NOT NULL,
            client_type    INTEGER     NOT NULL,     auth_value     INTEGER     NOT NULL,     auth_reason    INTEGER     NOT NULL,
            auth_version   INTEGER     NOT NULL,     csreq          BLOB,     policy_id      INTEGER,
            indirect_object_identifier_type    INTEGER,     indirect_object_identifier         TEXT NOT NULL DEFAULT 'UNUSED',
            indirect_object_code_identity      BLOB,     flags          INTEGER,
            last_modified  INTEGER     NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), pid INTEGER,
            pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (service, client, client_type, indirect_object_identifier),
            FOREIGN KEY (policy_id) REFERENCES policies(id) ON DELETE CASCADE ON UPDATE CASCADE);
        INSERT INTO admin VALUES ('version', 33);
        """

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    static func insert(_ row: Row) -> String {
        """
        INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type,
            indirect_object_identifier, flags, last_modified)
        VALUES (\(quote(row.service)), \(quote(row.client)), \(row.clientType), \(row.auth), \(row.reason), 1,
            \(row.indirect == "UNUSED" ? "NULL" : "0"), \(quote(row.indirect)), 0, \(row.modified));
        """
    }

    @discardableResult
    static func write(_ rows: [Row], to url: URL, schema: String = FakeTCC.schema) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.fsPath, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(handle) }
        let sql = schema + rows.map(insert).joined(separator: "\n")
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSDebugDescriptionErrorKey: String(cString: sqlite3_errmsg(handle))])
        }
        return url
    }
}

/// Bundle id → app URL, without LaunchServices.
struct FakeLocator: AppLocating {
    let apps: [String: URL]
    func applicationURL(forBundleID bundleID: String) -> URL? { apps[bundleID] }
}

/// Records every reset it is asked for.
final class RecordingRunner: TCCResetRunning {
    let calls = Locked<[String]>([])
    let outcome: TCCResetOutcome

    init(outcome: TCCResetOutcome = .reset) {
        self.outcome = outcome
    }

    var recorded: [String] { calls.withLock { $0 } }

    func reset(service: String, bundleID: String) async -> TCCResetOutcome {
        calls.withLock { $0.append("\(service) \(bundleID)") }
        return outcome
    }
}

/// Stands in for `Process`: records the command line, never starts anything.
final class FakeLauncher: ProcessLaunching {
    let calls = Locked<[[String]]>([])
    let result: (status: Int32, output: String)?

    init(result: (status: Int32, output: String)? = (0, "Successfully reset Camera approval status for com.example.zoom")) {
        self.result = result
    }

    var recorded: [[String]] { calls.withLock { $0 } }

    func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, output: String)? {
        calls.withLock { $0.append([tool] + arguments) }
        return result
    }
}

/// A catalog string as the test process shows it (the runner's language may be English).
private func localized(_ key: String) -> String {
    L10n.string(String.LocalizationValue(key))
}

@Suite("Privacy")
struct PrivacyTests {
    // MARK: Reading

    @Test func readsTheAccessTableOfTheRealSchema() throws {
        let mac = try FakeMac()
        let url = try FakeTCC.write([
            .init(service: "kTCCServiceCamera", client: "com.example.zoom", modified: 1_700_000_000),
            .init(service: "kTCCServiceMicrophone", client: "com.example.zoom", auth: 0, reason: 3),
            .init(service: "kTCCServicePhotos", client: "com.example.editor", auth: 3),
            .init(service: "kTCCServiceAppleEvents", client: "com.example.script", indirect: "com.example.target"),
            .init(service: "kTCCServiceSystemPolicyAllFiles", client: "/usr/local/bin/tool", clientType: 1),
        ], to: TCCDatabase.userDatabase(home: mac.home))

        let entries = try TCCDatabase.read(url, store: .user).sorted { $0.service < $1.service }
        #expect(entries.count == 5)
        let camera = try #require(entries.first { $0.service == "kTCCServiceCamera" })
        #expect(camera.client == "com.example.zoom")
        #expect(camera.clientType == .bundleID)
        #expect(camera.authorization == .allowed)
        #expect(camera.authReason == 2)
        #expect(camera.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(camera.indirectObject == nil)
        #expect(camera.store == .user)
        #expect(entries.first { $0.service == "kTCCServiceMicrophone" }?.authorization == .denied)
        #expect(entries.first { $0.service == "kTCCServicePhotos" }?.authorization == .limited)
        #expect(entries.first { $0.service == "kTCCServiceAppleEvents" }?.indirectObject == "com.example.target")
        let tool = try #require(entries.first { $0.client == "/usr/local/bin/tool" })
        #expect(tool.clientType == .path)
    }

    @Test func aMissingDatabaseIsEmpty() throws {
        let mac = try FakeMac()
        #expect(try TCCDatabase.read(TCCDatabase.systemDatabase(root: mac.root), store: .system).isEmpty)
        #expect(TCCDatabase.isReadable(TCCDatabase.systemDatabase(root: mac.root)))
    }

    @Test func anUnreadableDatabaseAsksForFullDiskAccess() throws {
        let mac = try FakeMac()
        let url = try FakeTCC.write([.init(service: "kTCCServiceCamera", client: "com.example.zoom")], to: TCCDatabase.userDatabase(home: mac.home))
        chmod(url.fsPath, 0)
        defer { chmod(url.fsPath, 0o644) }
        #expect(throws: TCCDatabase.Failure.notPermitted) { try TCCDatabase.read(url, store: .user) }
        #expect(!TCCDatabase.isReadable(url))
    }

    /// Before Big Sur the table had a boolean `allowed` and no client type, reason, date or target.
    @Test func readsAnOlderSchema() throws {
        let mac = try FakeMac()
        let url = mac.base.appending(path: "old/TCC.db")
        let schema = """
            CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, allowed INTEGER NOT NULL, prompt_count INTEGER);
            INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.zoom', 1, 1);
            INSERT INTO access VALUES ('kTCCServiceMicrophone', '/Applications/Tool.app/Contents/MacOS/tool', 0, 1);
            """
        try FakeTCC.write([], to: url, schema: schema)
        let entries = try TCCDatabase.read(url, store: .user).sorted { $0.service < $1.service }
        #expect(entries.map(\.authorization) == [.allowed, .denied])
        #expect(entries.map(\.clientType) == [.bundleID, .path])
        #expect(entries.allSatisfy { $0.lastModified == nil && $0.authReason == nil && $0.indirectObject == nil })
    }

    @Test func readingNeverTouchesTheDatabaseItself() throws {
        let mac = try FakeMac()
        let url = try FakeTCC.write([.init(service: "kTCCServiceCamera", client: "com.example.zoom")], to: TCCDatabase.userDatabase(home: mac.home))
        chmod(url.fsPath, 0o444)
        defer { chmod(url.fsPath, 0o644) }
        let before = try Data(contentsOf: url)
        let folder = url.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.fsPath)
        #expect(try TCCDatabase.read(url, store: .user).count == 1)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.fsPath) == siblings, "No journal or lock appears next to it")
    }

    /// Recent changes of a database in WAL mode sit in `-wal` until a checkpoint; they are read too.
    @Test func readsChangesStillInTheWriteAheadLog() throws {
        let mac = try FakeMac()
        let url = try FakeTCC.write([], to: TCCDatabase.userDatabase(home: mac.home))
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.fsPath, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;"
            + FakeTCC.insert(.init(service: "kTCCServiceCamera", client: "com.example.zoom"))
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        #expect(FileManager.default.fileExists(atPath: url.fsPath + "-wal"))
        #expect(try TCCDatabase.read(url, store: .user).map(\.client) == ["com.example.zoom"])
    }

    // MARK: Catalog

    @Test func mapsServicesToSystemSettingsTypes() {
        let expected: [(String, String, String?)] = [
            ("kTCCServiceCamera", "Камера", nil),
            ("kTCCServiceMicrophone", "Микрофон", nil),
            ("kTCCServiceScreenCapture", "Запись экрана и системного аудио", nil),
            ("kTCCServiceSystemPolicyAllFiles", "Полный доступ к диску", nil),
            ("kTCCServiceAccessibility", "Универсальный доступ", nil),
            ("kTCCServiceListenEvent", "Мониторинг ввода", nil),
            ("kTCCServiceAppleEvents", "Автоматизация", nil),
            ("kTCCServiceAddressBook", "Контакты", nil),
            ("kTCCServiceSystemPolicyDownloadsFolder", "Файлы и папки", "Папка «Загрузки»"),
            ("kTCCServiceSystemPolicyRemovableVolumes", "Файлы и папки", "Съёмные носители"),
            ("kTCCServiceSystemPolicyAppBundles", "Управление приложениями", nil),
            ("kTCCServiceDeveloperTool", "Инструменты разработчика", nil),
        ]
        for (id, title, detail) in expected {
            let service = PrivacyCatalog.service(id)
            #expect(service.isKnown, "\(id)")
            #expect(service.category.title == localized(title), "\(id)")
            #expect(service.detail == detail.map(localized), "\(id)")
        }
        #expect(PrivacyCatalog.service("kTCCServiceCamera").category.settingsAnchor == "Privacy_Camera")
        #expect(PrivacyCatalog.service("kTCCServiceSystemPolicyAllFiles").category.settingsURLs.first?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @Test func unknownServicesGoToOtherWithTheirRawID() {
        let service = PrivacyCatalog.service("kTCCServiceSomethingNew")
        #expect(!service.isKnown)
        #expect(service.category == PrivacyCatalog.other)
        #expect(service.category.title == localized("Другое"))
        #expect(service.detail == "kTCCServiceSomethingNew")
        #expect(service.shortName == "SomethingNew")
        #expect(PrivacyCatalog.service("weird").shortName == "weird")
        #expect(PrivacyCatalog.isHidden("kTCCServiceLiverpool"))
        #expect(!PrivacyCatalog.isHidden("kTCCServiceCamera"))
    }

    @Test func everyKnownServiceCanBeResetAndCategoriesAreUnique() {
        let ids = PrivacyCatalog.categories.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PrivacyCatalog.categories.map(\.order) == PrivacyCatalog.categories.map(\.order).sorted())
        for short in TCCResetPolicy.services {
            #expect(PrivacyCatalog.service("kTCCService" + short).isKnown, "\(short) is resettable but not in the catalog")
        }
        #expect(PrivacyCatalog.categories.allSatisfy { $0.settingsAnchor.hasPrefix("Privacy") })
    }

    @Test func catalogFollowsTheRunningSystem() {
        // System Settings of Sonoma 14.8 already says «Screen & System Audio Recording».
        #expect(PrivacyCatalog.categories.first { $0.id == "screenRecording" }?.title
            == localized("Запись экрана и системного аудио"))

        // Sonoma's tccd knows every service of the catalog, «Данные других программ» too.
        #expect(PrivacyCatalog.exists("kTCCServiceSystemPolicyAppData", onMacOS: 14))
        #expect(PrivacyCatalog.exists("kTCCServiceAudioCapture", onMacOS: 14))
        // A service a later system adds is left out before it; unknown services are taken as existing.
        let newer = ["SomethingNew": 27]
        #expect(!PrivacyCatalog.exists("kTCCServiceSomethingNew", onMacOS: 26, introduced: newer))
        #expect(PrivacyCatalog.exists("kTCCServiceSomethingNew", onMacOS: 27, introduced: newer))
        #expect(PrivacyCatalog.exists("kTCCServiceCamera", onMacOS: 14, introduced: newer))
        #expect(PrivacyCatalog.exists("kTCCServiceSomethingElse", onMacOS: 14))
        #expect(PrivacyCatalog.introduced.keys.allSatisfy { PrivacyCatalog.service("kTCCService" + $0).isKnown })
    }

    // MARK: Reset policy

    @Test func resetPolicyAllowsOnlyOneServiceForOneThirdPartyApp() {
        #expect(TCCResetPolicy.arguments(service: "Camera", bundleID: "com.example.zoom") == ["reset", "Camera", "com.example.zoom"])
        #expect(TCCResetPolicy.arguments(service: "ScreenCapture", bundleID: "us.zoom.xos") != nil)
        #expect(TCCResetPolicy.arguments(service: "SystemPolicyAllFiles", bundleID: "com.example.my_app-2") != nil)

        #expect(TCCResetPolicy.validate(service: "All", bundleID: "com.example.zoom") == .unknownService)
        #expect(TCCResetPolicy.validate(service: "camera", bundleID: "com.example.zoom") == .unknownService)
        #expect(TCCResetPolicy.validate(service: "kTCCServiceCamera", bundleID: "com.example.zoom") == .unknownService)
        #expect(TCCResetPolicy.validate(service: "", bundleID: "com.example.zoom") == .unknownService)
        #expect(TCCResetPolicy.validate(service: "Camera", bundleID: "com.apple.Terminal") == .appleClient)
        #expect(TCCResetPolicy.validate(service: "Camera", bundleID: "COM.APPLE.Safari") == .appleClient)
        #expect(TCCResetPolicy.validate(service: "Camera", bundleID: "com.ovvi.MacWashing") == .protectedClient)
        for bad in ["", "zoom", "-rf", "com.example.", ".com.example", "com..example", "com.example zoom", "com.example;rm",
                    "com.example/../x", "/Applications/Zoom.app", "com.exаmple.zoom", "--help.me", "com.-x", "com.example\nAll",
                    String(repeating: "a.", count: 200) + "a"] {
            #expect(TCCResetPolicy.validate(service: "Camera", bundleID: bad) == .invalidBundleID, "\(bad)")
        }
    }

    // MARK: Clients

    @Test func resolvesClientsToAppsAndFiles() throws {
        let mac = try FakeMac()
        try mac.app("Zoom", bundleID: "com.example.zoom")
        let zoom = mac.home.appending(path: "Applications/Zoom.app")
        let tool = try mac.file("Applications/Tool.app/Contents/MacOS/tool")
        let resolver = PrivacyClientResolver(locator: FakeLocator(apps: ["com.example.zoom": zoom]))

        let app = resolver.resolve("com.example.zoom", type: .bundleID)
        #expect(app.name == "Zoom")
        #expect(app.kind == .app && app.isInstalled && app.iconURL == zoom)
        #expect(app.bundleID == "com.example.zoom")

        let gone = resolver.resolve("com.example.gone", type: .bundleID)
        #expect(!gone.isInstalled && gone.name == "com.example.gone" && gone.iconURL == nil)
        #expect(!gone.isNameKnown)
        #expect(app.isNameKnown)

        let executable = resolver.resolve(tool.fsPath, type: .path)
        #expect(executable.kind == .path && executable.isInstalled && executable.name == "tool")
        #expect(executable.iconURL?.fsPath == mac.home.appending(path: "Applications/Tool.app").fsPath)
        #expect(executable.bundleID == nil)

        let missing = resolver.resolve(mac.base.appending(path: "nowhere/tool").fsPath, type: .path)
        #expect(!missing.isInstalled && missing.iconURL == nil)

        #expect(resolver.resolve("com.apple.Terminal", type: .bundleID).isApple)
    }

    @Test func deletedAppsTakeTheirNameFromTheProvider() {
        let names = ["com.example.gone": "Gone Pro", "com.example.blank": "  "]
        let resolver = PrivacyClientResolver(locator: FakeLocator(apps: [:]), knownName: { names[$0] })
        let gone = resolver.resolve("com.example.gone", type: .bundleID)
        #expect(gone.name == "Gone Pro" && !gone.isInstalled && gone.isNameKnown && gone.id == "com.example.gone")
        let blank = resolver.resolve("com.example.blank", type: .bundleID)
        #expect(blank.name == "com.example.blank" && !blank.isNameKnown)
        #expect(resolver.resolve("com.example.other", type: .bundleID).name == "com.example.other")
        // Paths never ask the provider.
        #expect(resolver.resolve("/nowhere/com.example.gone", type: .path).name == "com.example.gone")

        let item = PrivacyReport.build(entries: [entry("Camera", "com.example.gone")], resolver: resolver).first?.items.first
        #expect(item?.client.name == "Gone Pro")
        #expect(item?.matches("gone pro") == true)
        #expect(item?.matches("example.gone") == true)
    }

    @Test func inventoryLocatorMatchesBundleIDsIgnoringCase() throws {
        let mac = try FakeMac()
        try mac.app("Zoom", bundleID: "com.Example.Zoom")
        let inventory = AppInventory.scan(home: mac.home, systemRoot: mac.root, useLaunchServices: false)
        let locator = InventoryAppLocator(apps: inventory.apps)
        #expect(locator.applicationURL(forBundleID: "com.example.zoom")?.lastPathComponent == "Zoom.app")
        #expect(locator.applicationURL(forBundleID: "com.example.other") == nil)
    }

    // MARK: Report

    private func report(_ entries: [TCCEntry], apps: [String: URL] = [:]) -> [PrivacyGroup] {
        PrivacyReport.build(entries: entries, resolver: PrivacyClientResolver(locator: FakeLocator(apps: apps)))
    }

    private func entry(_ service: String, _ client: String, _ auth: TCCAuthorization = .allowed, type: TCCClientType = .bundleID,
                       target: String? = nil, store: TCCStore = .user) -> TCCEntry {
        TCCEntry(service: "kTCCService" + service, client: client, clientType: type, authorization: auth,
                 lastModified: Date(timeIntervalSince1970: 1_760_000_000), indirectObject: target, store: store)
    }

    @Test func groupsAppsThatHaveAccessLikeSystemSettings() throws {
        let mac = try FakeMac()
        try mac.app("Zoom", bundleID: "com.example.zoom")
        try mac.app("Alpha", bundleID: "com.example.alpha")
        try mac.app("Target", bundleID: "com.example.target")
        let apps = ["com.example.zoom": mac.home.appending(path: "Applications/Zoom.app"),
                    "com.example.alpha": mac.home.appending(path: "Applications/Alpha.app"),
                    "com.example.target": mac.home.appending(path: "Applications/Target.app")]
        let groups = report([
            entry("Camera", "com.example.zoom", .denied),
            entry("Camera", "com.example.alpha"),
            entry("Camera", "com.example.gone"),
            entry("Microphone", "com.example.zoom", .unknown),
            entry("Reminders", "com.example.zoom", .denied),
            entry("Photos", "com.example.alpha", .limited),
            entry("Calendar", "com.example.alpha", .other(4)),
            entry("Liverpool", "com.example.zoom"),
            entry("SomethingNew", "com.example.zoom"),
            entry("ScreenCapture", "com.example.zoom", store: .system),
            entry("AppleEvents", "com.example.alpha", target: "com.example.target"),
            entry("AppleEvents", "com.example.alpha", .denied, target: "com.example.zoom"),
            entry("SystemPolicyDownloadsFolder", "com.example.zoom"),
            entry("SystemPolicyDesktopFolder", "com.example.zoom"),
        ], apps: apps)

        // Reminders has only a denied decision: the type drops out.
        #expect(groups.map(\.category.id) == ["calendars", "photos", "camera", "filesAndFolders", "screenRecording", "automation", "other"])
        let camera = try #require(groups.first { $0.id == "camera" })
        // Only apps with access, by name (an uninstalled app shows its bundle id); denied Zoom is left out.
        #expect(camera.items.map(\.client.name) == ["Alpha", "com.example.gone"])
        #expect(camera.appCount == 2)
        #expect(groups.allSatisfy { $0.items.allSatisfy(\.isAllowed) })
        #expect(groups.first { $0.id == "photos" }?.items.first?.isLimited == true)
        #expect(groups.first { $0.id == "calendars" }?.items.count == 1)

        let files = try #require(groups.first { $0.id == "filesAndFolders" })
        #expect(files.appCount == 1)
        #expect(files.items.count == 2)
        #expect(Set(files.items.compactMap(\.service.detail)) == [localized("Папка «Загрузки»"), localized("Папка «Рабочий стол»")])

        let automation = try #require(groups.first { $0.id == "automation" })
        #expect(automation.items.map { "\($0.client.name) → \($0.target?.name ?? "")" } == ["Alpha → Target"])
        #expect(automation.appCount == 1)

        #expect(groups.first { $0.id == "screenRecording" }?.items.first?.entry.store == .system)
        #expect(groups.first { $0.id == "other" }?.items.first?.service.detail == "kTCCServiceSomethingNew")
        #expect(!groups.contains { $0.items.contains { $0.entry.service == "kTCCServiceLiverpool" } })
        #expect(!groups.contains { $0.items.contains { $0.entry.service == "kTCCServiceMicrophone" } }, "Undecided entries are left out")

        #expect(camera.filtered("alp").items.map(\.client.name) == ["Alpha"])
        #expect(camera.filtered("zo").items.isEmpty)
        #expect(camera.filtered("GONE").items.count == 1)
        #expect(camera.filtered("  ").items.count == 2)
        #expect(automation.filtered("target").items.count == 1)
    }

    @Test func appDataIsShownOnEverySupportedSystem() {
        // Sonoma already asks before an app reads other apps' data: its rows are real decisions on 14 too.
        let entries = [entry("SystemPolicyAppData", "com.example.zoom"), entry("Camera", "com.example.zoom")]
        let resolver = PrivacyClientResolver(locator: FakeLocator(apps: [:]))
        #expect(PrivacyReport.build(entries: entries, resolver: resolver, macOS: 14).map(\.id) == ["camera", "appData"])
        #expect(PrivacyReport.build(entries: entries, resolver: resolver, macOS: 15).map(\.id) == ["camera", "appData"])
    }

    @Test func onlyThirdPartyBundleIDsCanBeReset() {
        let items = report([
            entry("Camera", "com.example.zoom"),
            entry("Camera", "/usr/local/bin/tool", type: .path),
            entry("Camera", "com.apple.Terminal"),
            entry("Camera", "com.ovvi.MacWashing"),
            entry("Camera", "not a bundle id"),
            entry("SomethingNew", "com.example.zoom"),
        ]).flatMap(\.items)
        func block(_ client: String, _ service: String = "kTCCServiceCamera") -> PrivacyResetBlock?? {
            items.first { $0.entry.client == client && $0.entry.service == service }.map(\.resetBlock)
        }
        #expect(block("com.example.zoom") == .some(nil))
        #expect(block("/usr/local/bin/tool") == .pathClient)
        #expect(block("com.apple.Terminal") == .appleClient)
        #expect(block("com.ovvi.MacWashing") == .ownApp)
        #expect(block("not a bundle id") == .pathClient)
        #expect(block("com.example.zoom", "kTCCServiceSomethingNew") == .unsupportedService)
    }

    // MARK: Resetting

    @Test func resetsGoToTheRunnerOfTheirDatabase() async {
        let items = report([
            entry("Camera", "com.example.zoom"),
            entry("ScreenCapture", "com.example.zoom", store: .system),
            entry("Camera", "/usr/local/bin/tool", type: .path),
            entry("Camera", "com.apple.Terminal"),
        ]).flatMap(\.items)
        func item(_ service: String, _ client: String) -> PrivacyItem {
            items.first { $0.entry.service == "kTCCService" + service && $0.entry.client == client }!
        }
        let user = RecordingRunner(), system = RecordingRunner()
        let resetter = PrivacyResetter(user: user, system: system)
        #expect(await resetter.reset(item("Camera", "com.example.zoom")) == .reset)
        #expect(await resetter.reset(item("ScreenCapture", "com.example.zoom")) == .reset)
        if case .reset = await resetter.reset(item("Camera", "/usr/local/bin/tool")) { Issue.record("Path clients are never reset") }
        if case .reset = await resetter.reset(item("Camera", "com.apple.Terminal")) { Issue.record("Apple clients are never reset") }
        #expect(user.recorded == ["Camera com.example.zoom"])
        #expect(system.recorded == ["ScreenCapture com.example.zoom"])

        // Without the helper, a system decision is tried with the user's tccutil.
        let alone = RecordingRunner()
        #expect(await PrivacyResetter(user: alone, system: nil).reset(item("ScreenCapture", "com.example.zoom")) == .reset)
        #expect(alone.recorded == ["ScreenCapture com.example.zoom"])
    }

    @Test func tccutilRunnerBuildsExactlyOneResetCommand() async {
        let launcher = FakeLauncher()
        let runner = TCCUtilRunner(launcher: launcher)
        #expect(await runner.reset(service: "Camera", bundleID: "com.example.zoom") == .reset)
        #expect(launcher.recorded == [["/usr/bin/tccutil", "reset", "Camera", "com.example.zoom"]])

        for (service, bundleID) in [("All", "com.example.zoom"), ("Camera", "com.apple.Terminal"), ("Camera", "-rf"),
                                    ("Camera", ""), ("Camera", "com.example.zoom All")] {
            if case .reset = await runner.reset(service: service, bundleID: bundleID) { Issue.record("\(service) \(bundleID) passed") }
        }
        #expect(launcher.recorded.count == 1, "Refused requests never start tccutil")

        let failing = TCCUtilRunner(launcher: FakeLauncher(result: (1, "No such bundle identifier \"com.example.gone\"")))
        #expect(await failing.reset(service: "Camera", bundleID: "com.example.gone") == .failed(L10n.string("Не удалось отозвать доступ. Измените его в Системных настройках")))
        if case .reset = await TCCUtilRunner(launcher: FakeLauncher(result: nil)).reset(service: "Camera", bundleID: "com.example.zoom") {
            Issue.record("A tccutil that did not start is not a success")
        }
    }

    @Test func dryRunPretendsButValidates() async {
        #expect(await DryRunTCCRunner().reset(service: "Camera", bundleID: "com.example.zoom") == .reset)
        if case .reset = await DryRunTCCRunner().reset(service: "All", bundleID: "com.example.zoom") { Issue.record("All passed") }
    }

    // MARK: Scanner

    @Test func scansBothDatabasesAndReportsTheOneItCannotRead() throws {
        let mac = try FakeMac()
        try mac.app("Zoom", bundleID: "com.example.zoom")
        let apps = ["com.example.zoom": mac.home.appending(path: "Applications/Zoom.app")]
        try FakeTCC.write([.init(service: "kTCCServiceCamera", client: "com.example.zoom")], to: TCCDatabase.userDatabase(home: mac.home))
        let system = try FakeTCC.write([.init(service: "kTCCServiceScreenCapture", client: "com.example.zoom")],
                                       to: TCCDatabase.systemDatabase(root: mac.root))
        let scanner = PrivacyScanner(home: mac.home, systemRoot: mac.root, locator: FakeLocator(apps: apps))

        let report = scanner.scan()
        #expect(report.failures.isEmpty)
        #expect(report.groups.map(\.id) == ["camera", "screenRecording"])
        let screen = try #require(report.group("screenRecording")?.items.first)
        #expect(screen.entry.store == .system && screen.client.name == "Zoom")
        #expect(scanner.stillHolds(screen) == true)
        // A denied row left behind does not count as access.
        try FakeTCC.write([.init(service: "kTCCServiceScreenCapture", client: "com.example.zoom", auth: 0)],
                          to: mac.base.appending(path: "denied/TCC.db"))
        let deniedScanner = PrivacyScanner(userDatabase: mac.base.appending(path: "none/TCC.db"),
                                           systemDatabase: mac.base.appending(path: "denied/TCC.db"), locator: FakeLocator(apps: apps))
        #expect(deniedScanner.stillHolds(screen) == false)
        #expect(deniedScanner.scan().groups.isEmpty)

        chmod(system.fsPath, 0)
        defer { chmod(system.fsPath, 0o644) }
        let partial = scanner.scan()
        #expect(partial.failures == [.system: .notPermitted])
        #expect(partial.needsFullDiskAccess)
        #expect(partial.groups.map(\.id) == ["camera"])
        #expect(scanner.stillHolds(screen) == nil)
    }
}
