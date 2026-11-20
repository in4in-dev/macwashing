import Foundation
import MacWashingXPC

/// Why a decision cannot be reset from MacWashing (System Settings still can).
public enum PrivacyResetBlock: Sendable, Hashable {
    /// The client is an executable path: `tccutil` resets by bundle id only.
    case pathClient
    /// Apple's own apps and services are left to System Settings.
    case appleClient
    /// MacWashing itself: resetting it would cut the app off from these databases.
    case ownApp
    /// A service `tccutil` is not allowed to reset from here.
    case unsupportedService
}

/// One app's decision for one service, ready to show.
public struct PrivacyItem: Sendable, Hashable, Identifiable {
    public let entry: TCCEntry
    public let service: PrivacyService
    public let client: PrivacyClient
    /// The controlled app of an Automation decision.
    public let target: PrivacyClient?

    public var id: String { entry.id }
    public var isAllowed: Bool { entry.authorization.isAllowed }
    public var isLimited: Bool { entry.authorization == .limited }

    public init(entry: TCCEntry, service: PrivacyService, client: PrivacyClient, target: PrivacyClient?) {
        self.entry = entry
        self.service = service
        self.client = client
        self.target = target
    }

    /// Nil when `tccutil reset <service> <bundle id>` may be run for it.
    public var resetBlock: PrivacyResetBlock? {
        guard entry.clientType == .bundleID else { return .pathClient }
        switch TCCResetPolicy.validate(service: service.shortName, bundleID: entry.client) {
        case nil: return nil
        case .appleClient: return .appleClient
        case .protectedClient: return .ownApp
        // A bundle id that is not reverse-DNS cannot be passed to tccutil safely; treat it like a path.
        case .invalidBundleID: return .pathClient
        case .unknownService: return .unsupportedService
        }
    }

    /// Case-insensitive match against the app name, its bundle id or path, and the target app.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let fields = [client.name, client.id, target?.name, target?.id, service.detail].compactMap { $0 }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The decisions of one permission type.
public struct PrivacyGroup: Sendable, Hashable, Identifiable {
    public let category: PrivacyCategory
    /// Allowed first, then denied; by name inside each.
    public let items: [PrivacyItem]

    public var id: String { category.id }
    /// Different apps in the group (an app with several folders or Automation targets counts once).
    public var appCount: Int { Set(items.map(\.client.id)).count }

    public init(category: PrivacyCategory, items: [PrivacyItem]) {
        self.category = category
        self.items = items.sorted(by: Self.order)
    }

    static func order(_ a: PrivacyItem, _ b: PrivacyItem) -> Bool {
        if a.isAllowed != b.isAllowed { return a.isAllowed }
        let byName = a.client.name.localizedStandardCompare(b.client.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        let aDetail = a.target?.name ?? a.service.detail ?? ""
        let bDetail = b.target?.name ?? b.service.detail ?? ""
        if aDetail != bDetail { return aDetail.localizedStandardCompare(bDetail) == .orderedAscending }
        return a.id < b.id
    }

    public func filtered(_ query: String) -> PrivacyGroup {
        PrivacyGroup(category: category, items: items.filter { $0.matches(query) })
    }
}

/// Everything both TCC databases hold, grouped the way System Settings shows it.
public struct PrivacyReport: Sendable {
    public let groups: [PrivacyGroup]
    /// Databases that could not be read (the other one's decisions are still listed).
    public let failures: [TCCStore: TCCDatabase.Failure]

    public init(groups: [PrivacyGroup], failures: [TCCStore: TCCDatabase.Failure] = [:]) {
        self.groups = groups
        self.failures = failures
    }

    public var isEmpty: Bool { groups.isEmpty }
    public var needsFullDiskAccess: Bool { failures.values.contains(.notPermitted) }

    public func group(_ id: String) -> PrivacyGroup? {
        groups.first { $0.id == id }
    }

    /// Groups the apps that have access now (allowed, limited or a newer allowed value). Denied and undecided entries,
    /// hidden internal services and services macOS `major` does not have are left out, and so is a type no app has
    /// access to.
    public static func build(entries: [TCCEntry], resolver: PrivacyClientResolver,
                             macOS major: Int = PrivacyCatalog.systemMajor) -> [PrivacyGroup] {
        var clients: [String: PrivacyClient] = [:]
        func client(_ id: String, _ type: TCCClientType) -> PrivacyClient {
            let key = "\(type.rawValue)|\(id)"
            if let hit = clients[key] { return hit }
            let resolved = resolver.resolve(id, type: type)
            clients[key] = resolved
            return resolved
        }
        var byCategory: [String: (PrivacyCategory, [PrivacyItem])] = [:]
        for entry in entries where entry.authorization.isAllowed && !PrivacyCatalog.isHidden(entry.service)
            && PrivacyCatalog.exists(entry.service, onMacOS: major) {
            let service = PrivacyCatalog.service(entry.service)
            let target: PrivacyClient? = if service.shortName == "AppleEvents", let object = entry.indirectObject {
                client(object, object.hasPrefix("/") ? .path : .bundleID)
            } else {
                nil
            }
            let item = PrivacyItem(entry: entry, service: service, client: client(entry.client, entry.clientType), target: target)
            byCategory[service.category.id, default: (service.category, [])].1.append(item)
        }
        return byCategory.values
            .map { PrivacyGroup(category: $0.0, items: $0.1) }
            .sorted { $0.category.order < $1.category.order }
    }
}

/// Reads both databases and builds the report.
public struct PrivacyScanner: Sendable {
    public let userDatabase: URL
    public let systemDatabase: URL
    public let resolver: PrivacyClientResolver

    public init(userDatabase: URL, systemDatabase: URL, locator: any AppLocating, knownName: AppNameProvider? = nil) {
        self.userDatabase = userDatabase
        self.systemDatabase = systemDatabase
        self.resolver = PrivacyClientResolver(locator: locator, knownName: knownName)
    }

    public init(home: URL, systemRoot: URL, locator: any AppLocating, knownName: AppNameProvider? = nil) {
        self.init(userDatabase: TCCDatabase.userDatabase(home: home),
                  systemDatabase: TCCDatabase.systemDatabase(root: systemRoot), locator: locator, knownName: knownName)
    }

    public func database(of store: TCCStore) -> URL {
        store == .user ? userDatabase : systemDatabase
    }

    public func entries() -> (entries: [TCCEntry], failures: [TCCStore: TCCDatabase.Failure]) {
        var entries: [TCCEntry] = []
        var failures: [TCCStore: TCCDatabase.Failure] = [:]
        for store in TCCStore.allCases {
            do throws(TCCDatabase.Failure) {
                entries += try TCCDatabase.read(database(of: store), store: store)
            } catch {
                failures[store] = error
            }
        }
        return (entries, failures)
    }

    public func scan() -> PrivacyReport {
        let (entries, failures) = entries()
        return PrivacyReport(groups: PrivacyReport.build(entries: entries, resolver: resolver), failures: failures)
    }

    /// Whether `item`'s app still has access to its service (any target); nil when the database is unreadable.
    public func stillHolds(_ item: PrivacyItem) -> Bool? {
        guard let entries = try? TCCDatabase.read(database(of: item.entry.store), store: item.entry.store) else { return nil }
        return entries.contains { $0.service == item.entry.service && $0.client == item.entry.client && $0.authorization.isAllowed }
    }
}
