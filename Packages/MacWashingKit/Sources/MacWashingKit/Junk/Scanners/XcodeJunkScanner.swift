import Foundation

/// Xcode leftovers. The base has almost no rules here, so paths are defined in code.
public struct XcodeJunkScanner: JunkScanner {
    public let category = JunkCategoryID.xcode
    /// Lists unavailable simulators; injectable for tests.
    let unavailableSimulators: @Sendable () async -> [Simulator]
    /// Lists the simulator runtimes macOS keeps for Xcode; injectable for tests.
    let simulatorRuntimes: @Sendable () async -> [Runtime]
    /// The build of the running macOS (`25G83`): the launch caches of runtimes are kept per build.
    let systemBuild: String

    public struct Simulator: Sendable, Hashable {
        public let udid: String
        public let name: String
        public let dataPath: URL
    }

    /// A simulator runtime (`iOS 18.5`) as `simctl runtime list` shows it.
    public struct Runtime: Sendable, Hashable {
        /// The disk image's id, for `simctl runtime delete`.
        public let identifier: String
        /// `com.apple.CoreSimulator.SimRuntime.iOS-18-5`, for its launch cache.
        public let runtimeIdentifier: String
        public let build: String
        /// `iOS 18.5`.
        public let name: String
        /// The disk image (in `/Library/Developer/CoreSimulator` or among macOS's downloaded assets in `/System`).
        public let imagePath: URL
        /// Where it is mounted: `/Library/Developer/CoreSimulator/Volumes/iOS_22F77`.
        public let mountPath: URL
        public let size: Int64
    }

    public init() {
        unavailableSimulators = { await SimulatorList.unavailable() }
        simulatorRuntimes = { await SimulatorList.runtimes() }
        systemBuild = SimulatorList.systemBuild()
    }

    init(unavailableSimulators: @escaping @Sendable () async -> [Simulator],
         simulatorRuntimes: @escaping @Sendable () async -> [Runtime] = { [] }, systemBuild: String = "25A1") {
        self.unavailableSimulators = unavailableSimulators
        self.simulatorRuntimes = simulatorRuntimes
        self.systemBuild = systemBuild
    }

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let developer = env.userLibrary.appending(path: "Developer")
        let xcode = developer.appending(path: "Xcode")
        var entries: [JunkEntry] = []

        if let derived = await group(xcode.appending(path: "DerivedData"), title: "DerivedData", env: env) {
            entries.append(derived)
        }
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let folder = xcode.appending(path: "\(platform) DeviceSupport")
            if let support = await group(folder, title: "\(platform) DeviceSupport", env: env) { entries.append(support) }
        }
        if let archives = await group(xcode.appending(path: "Archives"), title: "Archives", env: env, gray: true) {
            entries.append(archives)
        }
        for (path, title) in [
            (xcode.appending(path: "UserData/Previews"), L10n.string("Кэши Previews")),
            (developer.appending(path: "CoreSimulator/Caches"), L10n.string("Кэши симуляторов")),
            (env.userLibrary.appending(path: "Caches/com.apple.dt.Xcode"), L10n.string("Кэш Xcode")),
        ] where FileSystem.exists(path) && !env.isExcluded(path) {
            let size = await FileSystem.size(of: path)
            if size > 0 { entries.append(JunkEntry(url: path, title: title, size: size, kind: .folder)) }
        }

        // Only devices of the scanned home: a test sandbox must never see (or delete) the real user's simulators.
        // No devices folder means no simulators at all: `xcrun` is not even started (most Macs have no Xcode; without
        // the command-line tools the shim could ask to install them).
        let devicesFolder = env.userLibrary.appending(path: "Developer/CoreSimulator/Devices")
        let devices = devicesFolder.fsPath + "/"
        let simulators = FileSystem.isDirectory(devicesFolder) && !Task.isCancelled
            ? await unavailableSimulators().filter { $0.dataPath.fsPath.hasPrefix(devices) }
            : []
        let deviceSizes = await FileSystem.sizes(of: simulators.map { $0.dataPath.deletingLastPathComponent() })
        let simEntries = simulators.compactMap { sim -> JunkEntry? in
            let device = sim.dataPath.deletingLastPathComponent()
            let size = deviceSizes[device] ?? 0
            return JunkEntry(url: device, title: sim.name, size: size, kind: .folder, action: .deleteSimulator(udid: sim.udid))
        }
        if !simEntries.isEmpty {
            let parent = developer.appending(path: "CoreSimulator/Devices")
            entries.append(JunkEntry(
                url: parent, title: L10n.string("Недоступные симуляторы"), size: simEntries.reduce(0) { $0 + $1.size },
                kind: .folder, children: simEntries.sorted { $0.size > $1.size }
            ))
        }
        entries += await systemSimulatorEntries(env)
        return JunkCategory(id: category, entries: entries)
    }

    /// Runtimes and their launch caches lie outside the home (`/Library/Developer/CoreSimulator`, root's) and go only
    /// through Apple's `simctl`, as the user. All gray: a cache is built again (minutes) when its simulator next starts,
    /// a runtime is downloaded again (gigabytes) from Xcode. Only runtimes mounted under the scanned root: a test sandbox
    /// never sees the real ones. No CoreSimulator folder there means no runtimes: `xcrun` is not started.
    private func systemSimulatorEntries(_ env: ScanEnvironment) async -> [JunkEntry] {
        let coreSimulator = env.systemLibrary.appending(path: "Developer/CoreSimulator")
        guard FileSystem.isDirectory(coreSimulator), !env.isExcluded(coreSimulator), !Task.isCancelled else { return [] }
        let volumes = coreSimulator.appending(path: "Volumes").fsPath + "/"
        let runtimes = await simulatorRuntimes().filter { $0.mountPath.fsPath.hasPrefix(volumes) && !env.isExcluded($0.imagePath) }
        var entries: [JunkEntry] = []

        // `Caches/dyld/<macOS build>/<runtime id>.<runtime build>`. `simctl` removes only the current build's: a folder
        // of an older macOS build or of a runtime no longer here is left (CoreSimulator drops those itself).
        let dyld = coreSimulator.appending(path: "Caches/dyld")
        let builtFor = dyld.appending(path: systemBuild)
        let caches = runtimes.map { ($0, builtFor.appending(path: "\($0.runtimeIdentifier).\($0.build)")) }
            .filter { FileSystem.isDirectory($0.1) && !env.isExcluded($0.1) }
        let cacheSizes = await FileSystem.sizes(of: caches.map(\.1))
        let cacheEntries = caches.compactMap { runtime, folder -> JunkEntry? in
            guard let size = cacheSizes[folder], size > 0 else { return nil }
            return JunkEntry(url: folder, title: runtime.name, size: size, kind: .folder, isGray: true,
                             action: .removeSimulatorCache(runtime: runtime.runtimeIdentifier))
        }.sorted { $0.size > $1.size }
        if !cacheEntries.isEmpty {
            entries.append(JunkEntry(
                url: dyld, title: L10n.string("Системный кэш симуляторов"), size: cacheEntries.reduce(0) { $0 + $1.size },
                kind: .folder, isGray: true, children: cacheEntries
            ))
        }

        let runtimeEntries = runtimes.filter { $0.size > 0 }.map { runtime in
            JunkEntry(url: runtime.imagePath, title: runtime.name, size: runtime.size, kind: .folder, isGray: true,
                      action: .deleteSimulatorRuntime(identifier: runtime.identifier))
        }.sorted { $0.size > $1.size }
        if !runtimeEntries.isEmpty {
            entries.append(JunkEntry(
                url: coreSimulator.appending(path: "Images"), title: L10n.string("Системы симуляторов"),
                size: runtimeEntries.reduce(0) { $0 + $1.size }, kind: .folder, isGray: true, children: runtimeEntries
            ))
        }
        return entries
    }

    private func group(_ folder: URL, title: String, env: ScanEnvironment, gray: Bool = false) async -> JunkEntry? {
        guard FileSystem.exists(folder), !env.isExcluded(folder) else { return nil }
        let childURLs = FileSystem.children(of: folder).filter { !env.isExcluded($0) }
        let sizes = await FileSystem.sizes(of: childURLs)
        let children = childURLs.compactMap { child -> JunkEntry? in
            guard let size = sizes[child], size > 0 else { return nil }
            return JunkEntry(url: child, title: child.lastPathComponent, size: size, kind: .folder, isGray: gray)
        }.sorted { $0.size > $1.size }
        guard !children.isEmpty else { return nil }
        return JunkEntry(url: folder, title: title, size: children.reduce(0) { $0 + $1.size }, kind: .folder, isGray: gray, children: children)
    }
}

enum SimulatorList {
    /// Deletable runtimes only (one bundled inside Xcode is not).
    static func runtimes() async -> [XcodeJunkScanner.Runtime] {
        guard let data = await Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]) else { return [] }
        return runtimes(from: data)
    }

    static func runtimes(from data: Data) -> [XcodeJunkScanner.Runtime] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.values.compactMap { image in
            guard image["deletable"] as? Bool == true,
                  let identifier = image["identifier"] as? String,
                  let runtimeIdentifier = image["runtimeIdentifier"] as? String,
                  let build = image["build"] as? String,
                  let path = image["path"] as? String,
                  let mountPath = image["mountPath"] as? String
            else { return nil }
            // `com.apple.CoreSimulator.SimRuntime.iOS-18-5` → `iOS`.
            let platform = runtimeIdentifier.split(separator: ".").last?.split(separator: "-").first.map(String.init) ?? ""
            let version = image["version"] as? String ?? build
            return XcodeJunkScanner.Runtime(
                identifier: identifier, runtimeIdentifier: runtimeIdentifier, build: build,
                name: platform.isEmpty ? version : "\(platform) \(version)", imagePath: URL(filePath: path),
                mountPath: URL(filePath: mountPath), size: (image["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    /// `kern.osversion`: `25G83`.
    static func systemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    static func unavailable() async -> [XcodeJunkScanner.Simulator] {
        guard let data = await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return devices.values.flatMap { $0 }.compactMap { device in
            guard let udid = device["udid"] as? String,
                  let name = device["name"] as? String,
                  let dataPath = device["dataPath"] as? String
            else { return nil }
            return XcodeJunkScanner.Simulator(udid: udid, name: name, dataPath: URL(filePath: dataPath))
        }
    }
}

/// Runs a tool and returns stdout, or nil on failure (also when it timed out or the task was cancelled).
/// No thread waits for the tool (`ProcessRunner`). `terminateOnCancel: false` for tools that change something.
public enum Shell {
    public static func run(
        _ tool: String, _ arguments: [String], timeout: TimeInterval = 20, terminateOnCancel: Bool = true
    ) async -> Data? {
        guard let result = await ProcessRunner.run(tool, arguments, timeout: timeout, terminateOnCancel: terminateOnCancel),
              result.status == 0 else { return nil }
        return result.output
    }
}
