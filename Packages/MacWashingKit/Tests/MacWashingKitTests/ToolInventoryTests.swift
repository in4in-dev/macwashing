import Foundation
import Testing
@testable import MacWashingKit
import MacWashingXPC

/// Programs without an app: Homebrew formulae and vendors' installs found by their launch jobs (the Uninstaller).
@Suite("Tools without an app")
struct ToolInventoryTests {
    /// A formula in `<root>/opt/homebrew/Cellar/<name>/<version>` with its receipt and a program in `bin`.
    func formula(_ mac: FakeMac, _ name: String, version: String = "1.0", onRequest: Bool = true, needs: [String] = [],
                 program: String? = nil) throws {
        let keg = "opt/homebrew/Cellar/\(name)/\(version)"
        let receipt: [String: Any] = [
            "installed_on_request": onRequest,
            "runtime_dependencies": needs.map { ["full_name": $0, "version": "1"] },
        ]
        try mac.file("\(keg)/INSTALL_RECEIPT.json", in: mac.root, contents: try JSONSerialization.data(withJSONObject: receipt))
        try mac.file("\(keg)/bin/\(program ?? name)", in: mac.root)
    }

    func homebrew(_ mac: FakeMac) throws {
        try mac.file("opt/homebrew/bin/brew", in: mac.root)
    }

    @Test func formulaeTheUserInstalled() async throws {
        let mac = try FakeMac()
        try homebrew(mac)
        try formula(mac, "wget", needs: ["openssl@3"])
        try formula(mac, "openssl@3", onRequest: false)
        try formula(mac, "python@3.13", onRequest: true)
        try formula(mac, "yt-dlp", needs: ["python@3.13"])
        try formula(mac, "elasticsearch-full", version: "7.17.4", program: "elasticsearch")
        try mac.folder("opt/homebrew/Cellar/python@3.13/1.0/IDLE 3.app", in: mac.root)
        try mac.folder("opt/homebrew/Cellar/elasticsearch-full/7.17.4/libexec/jdk.app", in: mac.root)

        let tools = await ToolInventory.scan(mac.environment())
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        // A dependency nobody asked for is Homebrew's to remove, not listed.
        #expect(Set(byName.keys) == ["wget", "python@3.13", "yt-dlp", "elasticsearch-full"])
        #expect(byName["python@3.13"]?.dependents == ["yt-dlp"])
        #expect(byName["wget"]?.dependents == [])
        #expect(byName["wget"]?.root.lastPathComponent == "wget")
        #expect(byName["wget"]?.jobLabels == ["homebrew.mxcl.wget"])
        // The icon: an app right in the keg, never one deep inside it (the Java runtime of Elasticsearch).
        #expect(byName["python@3.13"]?.iconFile?.lastPathComponent == "IDLE 3.app")
        #expect(byName["elasticsearch-full"]?.iconFile?.lastPathComponent == "elasticsearch")
        #expect(byName["elasticsearch-full"]?.asApp.vendor == "Homebrew")
        #expect(byName["elasticsearch-full"]?.version == "7.17.4")
    }

    @Test func noHomebrewWithoutBrew() async throws {
        let mac = try FakeMac()
        try formula(mac, "wget")
        #expect(await ToolInventory.scan(mac.environment()).isEmpty)
    }

    @Test func formulaFiles() async throws {
        let mac = try FakeMac()
        try homebrew(mac)
        try formula(mac, "mysql", version: "9.0.1")
        try formula(mac, "mysql@8.0", version: "8.0.41", program: "mysql")
        try formula(mac, "tor")
        try mac.file("opt/homebrew/var/mysql/ibdata1", in: mac.root)
        try mac.file("opt/homebrew/var/log/tor.log", in: mac.root)
        try mac.file("opt/homebrew/etc/tor/torrc", in: mac.root)
        try mac.file("opt/homebrew/var/homebrew/linked/tor", in: mac.root)
        try mac.plist("Library/LaunchAgents/homebrew.mxcl.tor.plist", ["Label": "homebrew.mxcl.tor"])

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let tor = try #require(tools.first { $0.name == "tor" })
        let items = await ToolFilesFinder().find(for: tor, tools: tools, env: env)
        #expect(items.first?.isApplicationBundle == true)
        #expect(items.first?.url.fsPath == tor.root.fsPath)
        let rest = Dictionary(uniqueKeysWithValues: items.dropFirst().map { ($0.url.lastPathComponent, $0) })
        #expect(Set(rest.keys) == ["tor.log", "tor", "homebrew.mxcl.tor.plist"])
        #expect(rest["homebrew.mxcl.tor.plist"]?.action == .unloadLaunchJob(label: "homebrew.mxcl.tor"))
        #expect(rest["homebrew.mxcl.tor.plist"]?.isLikely == false)
        // Data and settings are never checked by themselves.
        #expect(rest["tor.log"]?.isLikely == true)
        #expect(rest["tor"]?.isLikely == true)

        // `var/mysql` is both MySQL formulae's: it goes only with both.
        let mysql = try #require(tools.first { $0.name == "mysql" })
        let other = try #require(tools.first { $0.name == "mysql@8.0" })
        let data = await ToolFilesFinder().find(for: mysql, tools: tools, env: env).first { $0.url.lastPathComponent == "mysql" && !$0.isApplicationBundle }
        #expect(data?.sharedWith == [other.root.fsPath])
    }

    /// PHP keeps one shared settings folder with a subfolder per version: removing one version offers its own subfolder,
    /// the shared folder only with every version.
    @Test func aVersionsOwnFolderInASharedOne() async throws {
        let mac = try FakeMac()
        try homebrew(mac)
        try formula(mac, "php@7.4", version: "7.4.33_8", program: "php")
        try formula(mac, "php@8.2", version: "8.2.29_2", program: "php")
        try formula(mac, "php", version: "8.4.13", program: "php")
        for version in ["7.4", "8.2", "8.4"] { try mac.file("opt/homebrew/etc/php/\(version)/php.ini", in: mac.root) }
        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        for (name, version) in [("php@7.4", "7.4"), ("php", "8.4")] {
            let tool = try #require(tools.first { $0.name == name })
            let items = await ToolFilesFinder().find(for: tool, tools: tools, env: env)
            let own = items.first { $0.url.fsPath.hasSuffix("/etc/php/\(version)") }
            #expect(own?.isLikely == true && own?.sharedWith == [], "\(name)")
            let shared = items.first { $0.url.fsPath.hasSuffix("/etc/php") }
            #expect(shared?.sharedWith.count == 2, "\(name)")
            #expect(!items.contains { $0.url.fsPath.hasSuffix("/etc/php/8.2") }, "\(name)")
        }
    }

    /// What a formula's service file names (its config, data and logs), and what the user added to an interpreter.
    @Test func pathsFromTheServiceFileAndInterpreterPackages() async throws {
        let mac = try FakeMac()
        try homebrew(mac)
        try formula(mac, "shadowsocks-libev", version: "3.3.5_5", program: "ss-local")
        try mac.plist("opt/homebrew/Cellar/shadowsocks-libev/3.3.5_5/homebrew.mxcl.shadowsocks-libev.plist", [
            "Label": "homebrew.mxcl.shadowsocks-libev",
            "ProgramArguments": ["/opt/homebrew/opt/shadowsocks-libev/bin/ss-local", "-c", "/opt/homebrew/etc/shadowsocks-libev.json"],
        ], in: mac.root)
        try mac.file("opt/homebrew/etc/shadowsocks-libev.json", in: mac.root)
        for php in ["php@7.4", "php@8.2"] {
            try formula(mac, php, version: php == "php@7.4" ? "7.4.33" : "8.2.29", program: "php")
            try mac.plist("opt/homebrew/Cellar/\(php)/\(php == "php@7.4" ? "7.4.33" : "8.2.29")/homebrew.mxcl.\(php).plist", [
                "Label": "homebrew.mxcl.\(php)", "ProgramArguments": ["/opt/homebrew/opt/\(php)/sbin/php-fpm", "--nodaemonize"],
                "WorkingDirectory": "/opt/homebrew/var", "StandardErrorPath": "/opt/homebrew/var/log/php-fpm.log",
            ], in: mac.root)
        }
        try mac.file("opt/homebrew/var/log/php-fpm.log", in: mac.root)
        try formula(mac, "python@3.12", version: "3.12.13_4", program: "python3")
        try mac.file("opt/homebrew/lib/python3.12/site-packages/requests/__init__.py", in: mac.root)

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        func items(_ name: String) async throws -> [RelatedItem] {
            await ToolFilesFinder().find(for: try #require(tools.first { $0.name == name }), tools: tools, env: env)
        }
        #expect(try await items("shadowsocks-libev").contains { $0.url.lastPathComponent == "shadowsocks-libev.json" && $0.isLikely })
        // Every PHP's service writes the same log: it goes only with all of them.
        let log = try await items("php@7.4").first { $0.url.lastPathComponent == "php-fpm.log" }
        #expect(log?.sharedWith.count == 1)
        // Not the working folder (`var` itself).
        #expect(try await !items("php@7.4").contains { $0.url.lastPathComponent == "var" })
        #expect(try await items("python@3.12").contains { $0.url.lastPathComponent == "python3.12" && $0.likelyReason == .appData })
    }

    @Test func homebrewDataShapes() throws {
        let mac = try FakeMac()
        let prefix = mac.root.appending(path: "opt/homebrew").fsPath
        try homebrew(mac)
        for path in ["var/mysql/ibdata1", "var/lib/elasticsearch/x", "var/log/tor.log", "etc/tor/torrc", "var/homebrew/linked/x",
                     "var/log/x", "Cellar/tor/1/bin/tor", "etc/paths"] {
            try mac.file("opt/homebrew/" + path, in: mac.root)
        }
        func allowed(_ rest: String) -> Bool { HomebrewData.removalAllowed(prefix + "/" + rest, prefixes: [prefix]) }
        #expect(allowed("var/mysql"))
        #expect(allowed("var/lib/elasticsearch"))
        #expect(allowed("var/log/tor.log"))
        #expect(allowed("etc/tor"))
        // Homebrew's own and shared folders, the formula itself, anything else of the prefix: never.
        #expect(!allowed("var/homebrew"))
        #expect(!allowed("var/homebrew/linked"))
        #expect(!allowed("var/log"))
        #expect(!allowed("var/lib"))
        #expect(!allowed("var"))
        #expect(!allowed("etc/paths"))
        #expect(!allowed("lib/libssl.dylib"))
        #expect(!allowed("lib/pkgconfig"))
        #expect(!allowed("Cellar/tor"))
        #expect(!allowed("bin/brew"))
        #expect(!allowed("var/../Cellar/tor"))
        // Not a Homebrew prefix (no `bin/brew`).
        #expect(!HomebrewData.removalAllowed(mac.root.appending(path: "usr/local/var/mysql").fsPath, prefixes: [mac.root.appending(path: "usr/local").fsPath]))
        // A link on the way to somewhere else.
        try FileManager.default.createSymbolicLink(atPath: prefix + "/var/elsewhere", withDestinationPath: mac.home.fsPath)
        try mac.file("Documents/x")
        #expect(!allowed("var/elsewhere/Documents"))
    }

    @Test func installRoots() {
        #expect(ToolInventory.installRoot(ofProgram: "/Library/PostgreSQL/17/bin/postgres") == "/Library/PostgreSQL/17")
        #expect(ToolInventory.installRoot(ofProgram: "/Library/Vendor/agentd") == "/Library/Vendor")
        #expect(ToolInventory.installRoot(ofProgram: "/Library/Vendor/Tool/sbin/toold") == "/Library/Vendor/Tool")
        #expect(ToolInventory.installRoot(ofProgram: "/usr/local/bin/spoof-dpi") == "/usr/local/bin/spoof-dpi")
        // An app's helpers, macOS, Homebrew, programs inside apps: not a tool of their own.
        #expect(ToolInventory.installRoot(ofProgram: "/Library/Application Support/Acronis/Agent/aakore") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/Library/PrivilegedHelperTools/com.vendor.helper") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/Library/Frameworks/Python.framework/bin/python") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/usr/libexec/sshd-keygen-wrapper") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/opt/homebrew/opt/tor/bin/tor") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/Applications/Vendor.app/Contents/MacOS/agent") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/Library/Vendor.app/Contents/MacOS/agent") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/usr/local/bin/vendor/run.sh") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/usr/local/mysql/bin/mysqld") == nil)
        #expect(ToolInventory.installRoot(ofProgram: "/Library/../etc/x/bin/y") == nil)
        // What such a tool takes goes through the helper as it is.
        for path in ["/Library/PostgreSQL", "/Library/PostgreSQL/17/bin", "/usr/local/bin/spoof-dpi", "/Applications/PostgreSQL 17"] {
            #expect(SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: (path as NSString).deletingLastPathComponent))
        }
    }

    /// PostgreSQL as its installer from postgresql.org leaves it: a version folder in a vendor folder of /Library, a
    /// launch daemon with the data folder in its arguments, launchers in /Applications.
    @Test func vendorInstallFoundByItsService() async throws {
        let mac = try FakeMac()
        try mac.file("Library/PostgreSQL/17/bin/postgres", in: mac.root)
        try mac.file("Library/PostgreSQL/17/data/PG_VERSION", in: mac.root)
        try mac.file("Library/PostgreSQL/17/share/x", in: mac.root)
        try mac.plist("Library/LaunchDaemons/postgresql-17.plist", [
            "Label": "postgresql-17",
            "ProgramArguments": ["/Library/PostgreSQL/17/bin/postgres", "-D", "/Library/PostgreSQL/17/data"],
        ], in: mac.root)
        try mac.file("Applications/PostgreSQL 17/SQL Shell (psql).app/Contents/Info.plist", in: mac.root)
        // pgAdmin lives inside the install; its settings in the home go with it.
        try mac.app("pgAdmin 4", bundleID: "org.pgadmin.pgadmin4", in: mac.root.appending(path: "Library/PostgreSQL/17"))
        try mac.plist("Library/Preferences/org.pgadmin.pgadmin4.plist", ["a": 1])
        // An app's agent in its vendor folder, and a vendor folder named after an installed app.
        try mac.app("Parallels Desktop", bundleID: "com.parallels.desktop.console", in: mac.root.appending(path: "Applications"))
        try mac.file("Library/Parallels/bin/prl_disp", in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.parallels.dispatcher.plist", [
            "Label": "com.parallels.dispatcher", "Program": "/Library/Parallels/bin/prl_disp",
        ], in: mac.root)
        try mac.file("Library/Ghost/bin/ghostd", in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.ghost.d.plist", [
            "Label": "com.ghost.d", "Program": "/Library/Gone/bin/ghostd",
        ], in: mac.root)

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        #expect(tools.map(\.name) == ["PostgreSQL 17"])
        let postgres = try #require(tools.first)
        #expect(postgres.version == "17")
        #expect(postgres.jobLabels == ["postgresql-17"])
        // The vendor folder holds only this version: it goes whole.
        #expect(postgres.root.fsPath == mac.root.appending(path: "Library/PostgreSQL").fsPath)

        let items = await ToolFilesFinder().find(for: postgres, tools: tools, env: env)
        let main = try #require(items.first)
        #expect(main.isApplicationBundle && main.needsPrivileges)
        // The databases stay unless they are checked too.
        let data = mac.root.appending(path: "Library/PostgreSQL/17/data")
        #expect(main.keeping.map(\.fsPath) == [data.fsPath])
        let byName = Dictionary(uniqueKeysWithValues: items.dropFirst().map { ($0.url.lastPathComponent, $0) })
        #expect(Set(byName.keys) == ["data", "postgresql-17.plist", "PostgreSQL 17", "org.pgadmin.pgadmin4.plist"])
        #expect(byName["org.pgadmin.pgadmin4.plist"]?.isLikely == false)
        #expect(byName["data"]?.isLikely == true && byName["data"]?.likelyReason == .appData)
        // Not root's (the tester's): never loaded by launchd, removed as a file; a root-owned one is booted out.
        #expect(byName["postgresql-17.plist"]?.action == .removeItem)
        #expect(byName["PostgreSQL 17"]?.isLikely == false)
    }
}

/// Software installed by packages: found and removed by what their receipts list.
@Suite("Tools from installer packages")
struct PackageToolTests {
    /// Installs `files` (paths relative to `prefix`, `→` makes a link) into the fake root and writes a receipt for them
    /// with a real bom (`mkbom`), as `installer` leaves it.
    func package(_ mac: FakeMac, id: String, prefix: String, files: [String], version: String = "1.0", installed: Date? = nil) throws {
        let staging = mac.base.appending(path: "staging-\(id)")
        for entry in files {
            let parts = entry.components(separatedBy: " → ")
            for folder in [staging, mac.root.appending(path: prefix)] {
                let url = folder.appending(path: parts[0])
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if parts.count == 2 {
                    try? FileManager.default.createSymbolicLink(atPath: url.fsPath, withDestinationPath: parts[1])
                } else if entry.hasSuffix("/") {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else if !FileManager.default.fileExists(atPath: url.fsPath) {
                    try Data(repeating: 7, count: 4096).write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.fsPath)
                }
            }
        }
        let receipts = mac.root.appending(path: "private/var/db/receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mkbom")
        process.arguments = [staging.fsPath, receipts.appending(path: "\(id).bom").fsPath]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        var info: [String: Any] = ["PackageIdentifier": id, "PackageVersion": version, "InstallPrefixPath": prefix]
        if let installed { info["InstallDate"] = installed }
        try mac.plist("\(id).plist", info, in: receipts)
    }

    /// MySQL from Oracle: the server in its own folder in /usr/local with a link to it, a launch daemon and a System
    /// Settings pane, three receipts; the databases are made later, inside the server's folder.
    @Test func aServerInItsOwnFolder() async throws {
        let mac = try FakeMac()
        try package(mac, id: "com.fake.server", prefix: "usr/local",
                    files: ["fake-8.0-arm64/bin/faked", "fake-8.0-arm64/share/errmsg.sys", "fake → fake-8.0-arm64"], version: "8.0")
        try package(mac, id: "com.fake.launchd", prefix: "Library/LaunchDaemons", files: ["com.fake.faked.plist"])
        try mac.plist("Library/LaunchDaemons/com.fake.faked.plist", ["Label": "com.fake.faked", "Program": "/usr/local/fake/bin/faked"], in: mac.root)
        try package(mac, id: "com.fake.prefpane", prefix: "Library/PreferencePanes", files: ["Fake.prefPane/Contents/MacOS/Fake"])
        try mac.plist("Library/PreferencePanes/Fake.prefPane/Contents/Info.plist", ["CFBundleName": "Fake"], in: mac.root)
        try mac.file("usr/local/fake-8.0-arm64/data/ibdata1", in: mac.root)
        // What its script set up after installing: no receipt lists them.
        try mac.file("Library/PrivilegedHelperTools/com.fake.helper", in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.fake.helper.plist", ["Label": "com.fake.helper",
                      "Program": "/Library/PrivilegedHelperTools/com.fake.helper"], in: mac.root)

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        #expect(tools.map(\.name) == ["Fake"])
        let tool = try #require(tools.first)
        #expect(tool.version == "8.0")
        #expect(Set(tool.jobLabels) == ["com.fake.faked", "com.fake.helper"])
        #expect(tool.iconFile?.lastPathComponent == "Fake.prefPane")
        #expect((tool.knownSize ?? 0) > 0)

        let items = await ToolFilesFinder().find(for: tool, tools: tools, env: env)
        let main = try #require(items.first)
        #expect(main.isApplicationBundle && main.url.lastPathComponent == "com.fake.server.plist")
        let byName = Dictionary(uniqueKeysWithValues: items.dropFirst().map { ($0.url.lastPathComponent, $0) })
        #expect(Set(byName.keys) == ["fake-8.0-arm64", "fake", "com.fake.faked.plist", "Fake.prefPane", "data", "com.fake.helper",
                                     "com.fake.helper.plist"])
        #expect(byName["fake-8.0-arm64"]?.keeping.map(\.lastPathComponent) == ["data"])
        #expect(byName["data"]?.isLikely == true && byName["data"]?.likelyReason == .appData)
        // The fake root's plists are the tester's, not root's: launchd never loads such a daemon, it goes as a file.
        #expect(byName["com.fake.faked.plist"]?.action == .removeItem)
        #expect(items.dropFirst().filter { !$0.isLikely }.allSatisfy { $0.needsPrivileges })
        // No second tool for its launch daemon.
        #expect(!tools.contains { $0.id.hasPrefix("service:") })
    }

    /// Node.js from nodejs.org: files in the shared folders of /usr/local; links its script made; what `npm -g` added
    /// next to its own folder is left alone, and so are the standard folders and man pages.
    @Test func filesInSharedFolders() async throws {
        let mac = try FakeMac()
        try package(mac, id: "org.example.tool.pkg", prefix: "/", files: [
            "usr/local/bin/tool", "usr/local/include/tool/tool.h", "usr/local/lib/node_modules/", "usr/local/lib/node_modules/kit/index.js",
            "usr/local/share/man/man1/tool.1",
        ], version: "v20.1")
        try mac.file("usr/local/lib/node_modules/users-own/index.js", in: mac.root)
        try mac.file("usr/local/include/tool/generated.h", in: mac.root)
        try FileManager.default.createSymbolicLink(atPath: mac.root.appending(path: "usr/local/bin/kit").fsPath,
                                                   withDestinationPath: "../lib/node_modules/kit/index.js")
        // Named as a part of the id too (`npm` of Node.js): the program of its own still names the tool.
        try FileManager.default.createSymbolicLink(atPath: mac.root.appending(path: "usr/local/bin/example").fsPath,
                                                   withDestinationPath: "../lib/node_modules/kit/index.js")
        try FileManager.default.createSymbolicLink(atPath: mac.root.appending(path: "usr/local/bin/users-own").fsPath,
                                                   withDestinationPath: "../lib/node_modules/users-own/index.js")

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let tool = try #require(tools.first)
        #expect(tool.name == "tool")
        #expect(tool.version == "v20.1")
        let items = await ToolFilesFinder().find(for: tool, tools: tools, env: env)
        let paths = Set(items.dropFirst().map { RemovalZone.systemPath($0.url, env: env) ?? "" })
        #expect(paths == ["/usr/local/bin/tool", "/usr/local/include/tool", "/usr/local/lib/node_modules/kit", "/usr/local/bin/kit",
                          "/usr/local/bin/example", "/usr/local/include/tool/generated.h"])
    }

    /// Node.js: two receipts (`node`, `npm`); `npm` and `npx` are links its script made into `npm`'s folder, which has a
    /// `bin/npm` of its own. `/usr/local/bin/node` names it.
    @Test func nodeNamesNodeJS() async throws {
        let mac = try FakeMac()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try package(mac, id: "org.nodejs.node.pkg", prefix: "usr/local", files: ["bin/node", "include/node/node.h"], installed: day)
        try package(mac, id: "org.nodejs.npm.pkg", prefix: "usr/local", files: ["lib/node_modules/npm/bin/npm-cli.js",
                    "lib/node_modules/npm/bin/npx-cli.js", "lib/node_modules/npm/bin/npm"], installed: day)
        try link(mac, "usr/local/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        try link(mac, "usr/local/bin/npx", to: "../lib/node_modules/npm/bin/npx-cli.js")
        let tools = await ToolInventory.scan(mac.environment())
        #expect(tools.map(\.name) == ["node"])
    }

    /// One vendor's packages installed on different days are different tools; the receipts of one run are one.
    @Test func oneToolPerInstallerRun() async throws {
        let mac = try FakeMac()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try package(mac, id: "com.bigvendor.credentialmanager", prefix: "usr/local", files: ["share/gcm-core/gcm"], installed: day)
        try package(mac, id: "com.bigvendor.sdk.host", prefix: "usr/local", files: ["share/sdk/host/dotnet"], installed: day + 86_400)
        try package(mac, id: "com.bigvendor.sdk.runtime", prefix: "usr/local", files: ["share/sdk/runtime/x"], installed: day + 86_460)
        let tools = await ToolInventory.scan(mac.environment())
        #expect(tools.count == 2)
        #expect(Set(tools.map(\.id)) == ["package:com.bigvendor.credentialmanager", "package:com.bigvendor.sdk.host"])
    }

    /// Two products of one vendor (Oracle's Java and MySQL): neither takes the other's launch daemon.
    @Test func aVendorsOtherProductKeepsItsJobs() async throws {
        let mac = try FakeMac()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try package(mac, id: "com.big.db.server", prefix: "usr/local", files: ["bigdb-1/bin/bigd"], installed: day)
        try package(mac, id: "com.big.db.launchd", prefix: "Library/LaunchDaemons", files: ["com.big.db.d.plist"], installed: day)
        try mac.plist("Library/LaunchDaemons/com.big.db.d.plist", ["Label": "com.big.db.d", "Program": "/usr/local/bigdb-1/bin/bigd"],
                      in: mac.root)
        try package(mac, id: "com.big.jre", prefix: "Library/Internet Plug-Ins/Big.plugin", files: ["Contents/Home/bin/java"],
                    installed: day + 86_400)
        // The runtime's updater, set up by its script: its program is inside the plug-in.
        try mac.plist("Library/LaunchAgents/com.big.jre.updater.plist", ["Label": "com.big.jre.updater",
                      "Program": "/Library/Internet Plug-Ins/Big.plugin/Contents/Home/bin/java"], in: mac.root)
        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let jre = try #require(tools.first { $0.id == "package:com.big.jre" })
        let db = try #require(tools.first { $0.id == "package:com.big.db.launchd" })
        let jreItems = await ToolFilesFinder().find(for: jre, tools: tools, env: env).map(\.url.lastPathComponent)
        #expect(jreItems.contains("com.big.jre.updater.plist"))
        #expect(!jreItems.contains("com.big.db.d.plist"))
        #expect(db.jobLabels == ["com.big.db.d"])
    }

    func link(_ mac: FakeMac, _ path: String, to target: String) throws {
        let url = mac.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.fsPath, withDestinationPath: target)
    }

    func text(_ mac: FakeMac, _ path: String, _ contents: String) throws {
        let url = mac.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func paths(_ tool: InstalledTool, _ tools: [InstalledTool], _ env: ScanEnvironment) async -> Set<String> {
        Set(await ToolFilesFinder().find(for: tool, tools: tools, env: env).dropFirst().map { RemovalZone.systemPath($0.url, env: env) ?? $0.url.fsPath })
    }

    /// Salt: a folder in /opt, links in /usr/local/sbin, and what its script wrote to /etc (its settings and its PATH
    /// entry). macOS's files there and another tool's PATH entry stay.
    @Test func aToolInOptWithItsSettingsInEtc() async throws {
        let mac = try FakeMac()
        try package(mac, id: "com.saltco.salt", prefix: "/", files: ["opt/salt/salt", "opt/salt/bin/calc-prorate", "opt/salt/lib/x.py"])
        try link(mac, "usr/local/sbin/salt", to: "/opt/salt/salt")
        try mac.file("private/etc/salt/minion", in: mac.root)
        // Its jobs: one runs its program, one only stops the first one (named after it), one is another product's.
        try mac.plist("Library/LaunchDaemons/com.saltco.salt.minion.plist", ["Label": "com.saltco.salt.minion",
                      "ProgramArguments": ["/opt/salt/salt", "minion"]], in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.saltco.salt.minion-stopper.plist", ["Label": "com.saltco.salt.minion-stopper",
                      "ProgramArguments": ["/bin/launchctl", "stop", "com.saltco.salt.minion"]], in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.saltco.cloud.plist", ["Label": "com.saltco.cloud",
                      "ProgramArguments": ["/usr/local/cloud/bin/cloudd"]], in: mac.root)
        try text(mac, "private/etc/paths.d/salt", "/opt/salt/bin\n")
        try text(mac, "private/etc/paths.d/homebrew", "/opt/homebrew/bin\n")
        try mac.file("private/etc/saltine", in: mac.root)
        try mac.file("private/etc/hosts", in: mac.root)
        // A product named as a folder macOS has in /etc: the policy keeps it.
        try package(mac, id: "org.sshco.ssh", prefix: "usr/local", files: ["bin/sshx"])
        try mac.file("private/etc/ssh/sshd_config", in: mac.root)

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let salt = try #require(tools.first { $0.id == "package:com.saltco.salt" })
        #expect(salt.name == "salt")
        #expect(await paths(salt, tools, env) == ["/opt/salt", "/usr/local/sbin/salt", "/private/etc/salt", "/private/etc/paths.d/salt",
                                                 "/Library/LaunchDaemons/com.saltco.salt.minion.plist",
                                                 "/Library/LaunchDaemons/com.saltco.salt.minion-stopper.plist"])
        let ssh = try #require(tools.first { $0.id == "package:org.sshco.ssh" })
        #expect(await paths(ssh, tools, env) == ["/usr/local/bin/sshx"])
    }

    /// BasicTeX: `/Library/TeX`, made by its script, is links into the TeX Live folder that goes (and to the user's home),
    /// with two small files; `/etc/paths.d/TeX` adds its `texbin`. A folder with links there and files of its own stays.
    @Test func aFolderOfLinksToWhatGoes() async throws {
        let mac = try FakeMac()
        // A program in a `bin` named after nothing of the package (`runme`): the id names it.
        try package(mac, id: "org.tug.mactex.basictex2026", prefix: "usr/local",
                    files: ["texlive/2026basic/bin/universal-darwin/tex", "texlive/2026basic/texmf-dist/scripts/bin/runme"])
        try link(mac, "Library/TeX/texbin", to: "Distributions/Programs/texbin")
        try link(mac, "Library/TeX/Distributions/Programs/texbin", to: "../../../../usr/local/texlive/2026basic/bin/universal-darwin")
        try link(mac, "Library/TeX/Distributions/Programs/i386", to: "../../../../usr/local/texlive/2026basic/bin/i386-darwin")
        try link(mac, "Library/TeX/Local/TEXMFHOME", to: "/Users/someone/Library/texmf")
        try FileManager.default.createDirectory(at: mac.root.appending(path: "Library/TeX/Distributions/TeX.texdist/Contents"), withIntermediateDirectories: true)
        try link(mac, "Library/TeX/Distributions/.DefaultTeX/Contents", to: "../TeX.texdist/Contents")
        try mac.file("Library/TeX/Distributions/TeXDist-description.rtf", in: mac.root)
        try text(mac, "private/etc/paths.d/TeX", "/Library/TeX/texbin\n")
        try text(mac, "private/etc/manpaths.d/TeX", "/Library/TeX/Distributions/Programs/texbin/man\n")
        try link(mac, "Library/Editor/tex", to: "/usr/local/texlive/2026basic/bin/universal-darwin/tex")
        for index in 0..<21 { try mac.file("Library/Editor/doc\(index).txt", in: mac.root) }

        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let tex = try #require(tools.first)
        #expect(tex.name == "basictex 2026")
        #expect(await paths(tex, tools, env) == ["/usr/local/texlive", "/Library/TeX", "/private/etc/paths.d/TeX", "/private/etc/manpaths.d/TeX"])
    }

    /// MySQL Shell: its folder in /usr/local, a link to it there, and its command linked through that link; it is named
    /// after that command, not the first program in its `bin`.
    @Test func linksThroughALink() async throws {
        let mac = try FakeMac()
        try package(mac, id: "com.dbco.shell", prefix: "usr/local", files: ["dbshell-26.7-arm64/bin/db-secret-store", "dbshell-26.7-arm64/bin/dbsh"])
        try link(mac, "usr/local/dbshell", to: "dbshell-26.7-arm64")
        try link(mac, "usr/local/bin/dbsh", to: "/usr/local/dbshell/bin/dbsh")
        try link(mac, "usr/local/bin/ds", to: "/usr/local/dbshell/bin/dbsh")
        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let tool = try #require(tools.first)
        #expect(tool.name == "dbsh")
        #expect(await paths(tool, tools, env) == ["/usr/local/dbshell-26.7-arm64", "/usr/local/dbshell", "/usr/local/bin/dbsh", "/usr/local/bin/ds"])
    }

    /// The .NET SDK: named after its command; its script's `/etc/dotnet` and PATH entries, one of them pointing into the
    /// user's home (named after the product, it adds nothing that stays).
    @Test func pathEntriesNamedAfterTheProduct() async throws {
        let mac = try FakeMac()
        try package(mac, id: "com.netco.dotnet.dev.10.0.401.component.osx.arm64", prefix: "usr/local", files: ["share/dotnet/dotnet"])
        try link(mac, "usr/local/bin/dotnet", to: "/usr/local/share/dotnet/dotnet")
        try mac.file("private/etc/dotnet/install_location", in: mac.root)
        try text(mac, "private/etc/paths.d/dotnet", "/usr/local/share/dotnet\n")
        try text(mac, "private/etc/paths.d/dotnet-cli-tools", "~/.dotnet/tools\n")
        try text(mac, "private/etc/paths.d/dotnet-old", "/usr/local/share/dotnet\n/usr/local/other\n")
        try mac.file("usr/local/other/x", in: mac.root)
        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let tool = try #require(tools.first)
        #expect(tool.name == "dotnet")
        #expect(await paths(tool, tools, env) == ["/usr/local/share/dotnet", "/usr/local/bin/dotnet", "/private/etc/dotnet",
                                                 "/private/etc/paths.d/dotnet", "/private/etc/paths.d/dotnet-cli-tools"])
    }

    /// Mono: named as its framework, which has no name in its Info.plist; the vendor's cache in the user's Library goes
    /// with it, its settings there do not. The .NET runtime: named as its program right in its folder.
    @Test func namesFromAFrameworkAndAProgramInItsFolder() async throws {
        let mac = try FakeMac()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try package(mac, id: "com.monoco.mono-MDK.pkg", prefix: "Library/Frameworks", files: ["Mono.framework/Versions/6.12/Commands/mono",
                    "Mono.framework/Versions/6.12/bin/ClassInitGenerator"], installed: day)
        try mac.file("Library/Caches/com.monoco.fontconfig/cache", in: mac.home)
        try mac.file("Library/Preferences/com.monoco.ide.plist", in: mac.home)
        try package(mac, id: "com.netco.dotnet.sharedframework.NETCore.App.10.0.12.component.osx.arm64", prefix: "usr/local",
                    files: ["share/dotnet/dotnet", "share/dotnet/shared/x.dll"], installed: day)
        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let mono = try #require(tools.first { $0.id.hasPrefix("package:com.monoco") })
        #expect(mono.name == "Mono")
        let monoPaths = await paths(mono, tools, env)
        #expect(monoPaths.contains("/Library/Frameworks/Mono.framework"))
        #expect(monoPaths.contains { $0.hasSuffix("/Library/Caches/com.monoco.fontconfig") })
        #expect(!monoPaths.contains { $0.hasSuffix("com.monoco.ide.plist") })
        #expect(tools.first { $0.id.hasPrefix("package:com.netco") }?.name == "dotnet")
    }

    /// Quarto: a folder of its own in /Applications with no app in it is the tool's, not an app's installer.
    @Test func aToolsFolderInApplications() async throws {
        let mac = try FakeMac()
        try package(mac, id: "org.rco.quarto", prefix: "Applications", files: ["quarto/bin/quarto", "quarto/share/x.lua"])
        try link(mac, "usr/local/bin/quarto", to: "/Applications/quarto/bin/quarto")
        let env = mac.environment()
        let tools = await ToolInventory.scan(env)
        let tool = try #require(tools.first)
        #expect(tool.name == "quarto")
        #expect(await paths(tool, tools, env) == ["/Applications/quarto", "/usr/local/bin/quarto"])
    }

    /// A folder whose every entry goes, but for its script's log, goes whole (swiftDialog's
    /// `/Library/Application Support/Dialog`); a standard
    /// folder, or one with something else in it, does not.
    @Test func aWrapperFolderGoesWhole() throws {
        let mac = try FakeMac()
        try mac.file("Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog", in: mac.root)
        try mac.file("Library/Application Support/Dialog/postinstall.log", in: mac.root)
        try mac.file("Library/Application Support/Kept/Tool.app/Contents/MacOS/Tool", in: mac.root)
        try mac.file("Library/Application Support/Kept/settings.plist", in: mac.root)
        try mac.file("Library/Frameworks/Only.framework/Only", in: mac.root)
        let env = mac.environment()
        let items = ["Library/Application Support/Dialog/Dialog.app", "Library/Application Support/Kept/Tool.app", "Library/Frameworks/Only.framework"]
            .map { PackageItem(url: mac.root.appending(path: $0), extras: []) }
        let whole = ToolInventory.wholeFolders(items, otherPackages: [], env: env).compactMap { RemovalZone.systemPath($0.url, env: env) }
        #expect(Set(whole) == ["/Library/Application Support/Dialog", "/Library/Application Support/Kept/Tool.app", "/Library/Frameworks/Only.framework"])
    }

    /// The packages of an app's vendor are the app's (Microsoft's licensing helper is Office's), and an installer that
    /// put an app in /Applications is that app's.
    @Test func packagesOfAnAppStayWithIt() async throws {
        let mac = try FakeMac()
        try mac.app("Vendor App", bundleID: "com.vendor.app", in: mac.root.appending(path: "Applications"))
        try package(mac, id: "com.vendor.licensing", prefix: "Library/PrivilegedHelperTools", files: ["com.vendor.licensing.helper"])
        try package(mac, id: "com.other.suite", prefix: "Applications", files: ["Other.app/Contents/MacOS/Other", "Other Tools/x"])
        // Only gone files left: the receipt of something removed already.
        try package(mac, id: "com.gone.tool", prefix: "usr/local", files: ["bin/gone"])
        try FileManager.default.removeItem(at: mac.root.appending(path: "usr/local/bin/gone"))
        #expect(await ToolInventory.scan(mac.environment()).isEmpty)
    }
}

/// Real Homebrew in a throwaway macOS guest: `brew install pv wget` first, then
/// `MW_BREW_E2E=1 swift test --filter HomebrewEndToEnd`. Removes `pv` and its data for real; never run on a Mac in use.
@Suite("Homebrew end to end", .enabled(if: ProcessInfo.processInfo.environment["MW_BREW_E2E"] == "1"))
struct HomebrewEndToEndTests {
    @Test func removesAFormulaWithBrewAndItsDataWithTheCleaner() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ScanEnvironment(home: home, database: Fixtures.database, inventory: AppInventory.scan(home: home))
        let prefix = try #require(ToolInventory.homebrewPrefixes(env).first)
        try FileManager.default.createDirectory(at: prefix.appending(path: "var/pv"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: prefix.appending(path: "var/pv/state"))

        let tools = await ToolInventory.scan(env)
        let pv = try #require(tools.first { $0.name == "pv" })
        let wget = try #require(tools.first { $0.name == "wget" })
        #expect(wget.dependents.isEmpty)
        let items = await ToolFilesFinder().find(for: pv, tools: tools, env: env)
        let data = try #require(items.first { $0.url.lastPathComponent == "pv" && !$0.isApplicationBundle })
        #expect(data.isLikely)

        guard case .homebrew(let formula, let brew) = pv.source else { Issue.record("not a formula"); return }
        #expect(await ToolRemover.uninstallFormula(formula, brew: brew, rack: pv.root, dryRun: false) == nil)
        #expect(Cleaner.isGone(pv.root.fsPath))
        #expect(!FileManager.default.fileExists(atPath: prefix.appending(path: "bin/pv").fsPath))

        let cleaner = Cleaner(mode: .delete, home: home, privileged: nil)
        let report = await cleaner.clean([CleanTarget(url: data.url, size: data.size, needsPrivileges: false)])
        #expect(report.failures.isEmpty)
        #expect(Cleaner.isGone(data.url.fsPath))
        // Homebrew's own folder next to it stays out of reach.
        let own = await cleaner.clean([CleanTarget(url: prefix.appending(path: "var/homebrew"), size: 0, needsPrivileges: false)])
        #expect(own.failures.count == 1)

        // A formula others need: `brew` refuses, and says why.
        let openssl = prefix.appending(path: "Cellar/openssl@3")
        #expect(await ToolRemover.uninstallFormula("openssl@3", brew: brew, rack: openssl, dryRun: false)
                == L10n.string("Нужна другим утилитам Homebrew"))
        #expect(!Cleaner.isGone(openssl.fsPath))
    }
}
