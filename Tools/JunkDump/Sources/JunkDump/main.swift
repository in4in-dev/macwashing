import Foundation
import MacWashingKit

// junk-dump <database.sqlite> [--skip-consent]: the System Junk scan of this user's home, as the app runs it (all
// default scanners, duplicates removed), one line per item: {"category", "path", "size", "gray"}. `--skip-consent`
// leaves out the places macOS asks about (like «Пропустить» in the app) — no prompts on a Mac in use.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: junk-dump <database.sqlite> [--skip-consent]\n".utf8))
    exit(2)
}
let database = try Database(url: URL(filePath: path))
let home = FileManager.default.homeDirectoryForCurrentUser
let inventory = AppInventory.scan(home: home)
var env = ScanEnvironment(home: home, database: database, inventory: inventory)
env.skipsConsentPlaces = arguments.contains("--skip-consent")
let categories = await JunkScanEngine().scan(env)
for category in categories {
    for leaf in category.leaves {
        let line: [String: Any] = ["category": category.id.rawValue, "path": leaf.url.path(percentEncoded: false),
                                   "size": leaf.size, "gray": leaf.isGray]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
