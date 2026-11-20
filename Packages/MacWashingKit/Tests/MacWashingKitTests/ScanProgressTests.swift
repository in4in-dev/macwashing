import Foundation
import Testing
@testable import MacWashingKit

/// How the scan bar is split between the scanners.
struct ScanProgressTests {
    /// «Кэш программ» takes half the bar, the other scanners split the other half equally.
    @Test func appCachesTakeHalfTheBar() async throws {
        let categories = JunkScanEngine.defaultScanners.map(\.category)
        let shares = JunkScanEngine.shares(for: categories)
        #expect(categories.first == .userCaches && shares.first == 0.5)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        #expect(Set(shares.dropFirst()).count == 1)
        #expect(JunkScanEngine.shares(for: [.installers, .xcode]) == [0.5, 0.5])

        struct Quick: JunkScanner {
            let category: JunkCategoryID
            func scan(_ environment: ScanEnvironment) async -> JunkCategory { JunkCategory(id: category, entries: []) }
        }
        actor Starts { var all: [JunkCategoryID: (Double, Double)] = [:]; var last = 0.0
            func add(_ p: JunkScanEngine.Progress) {
                last = p.fraction
                if let r = p.running, all[r] == nil { all[r] = (p.fraction, p.stepFraction) }
            } }
        let starts = Starts()
        let mac = try FakeMac()
        _ = await JunkScanEngine(scanners: [Quick(category: .userCaches), Quick(category: .appCaches), Quick(category: .installers)])
            .scan(mac.environment()) { await starts.add($0) }
        let seen = await starts.all
        #expect(seen[.userCaches]! == (0, 0.5))
        #expect(seen[.appCaches]! == (0.5, 0.25))
        #expect(seen[.installers]! == (0.75, 0.25))
        #expect(await starts.last == 1)
    }
}
