import Foundation
import Testing
@testable import MacWashingKit

/// The Uninstaller's checks: an app is clickable before its files are found, «Выбрать всё» takes everything the user may
/// tick, shared items follow the apps using them.
@Suite("Uninstall selection")
struct UninstallSelectionTests {
    private static func item(_ path: String, bundle: Bool = false, likely: Bool = false, sharedWith: [String] = []) -> RelatedItem {
        RelatedItem(
            url: URL(filePath: path), location: "", size: 10, isDirectory: true, needsPrivileges: false, action: .removeItem,
            isApplicationBundle: bundle, isLikely: likely, sharedWith: sharedWith
        )
    }

    private static let alphaID = "/Applications/Alpha.app"
    private static let betaID = "/Applications/Beta.app"
    private static let alpha = [
        item(alphaID, bundle: true),
        item("/Users/me/Library/Caches/com.example.alpha"),
        item("/Users/me/Library/Application Support/Alpha", likely: true),
        item("/Users/me/Library/Group Containers/group.example", sharedWith: [betaID]),
    ]
    private static let beta = [
        item(betaID, bundle: true),
        item("/Users/me/Library/Group Containers/group.example", sharedWith: [alphaID]),
    ]

    @Test func appTickedBeforeItsFilesAreFoundIsAppliedWhenTheyArrive() {
        var selection = UninstallSelection()
        var related: [String: [RelatedItem]] = [:]
        selection.select(Self.alphaID, items: nil, scope: .recommended, related: related)
        // Shown as checked at once; nothing to remove yet, and removal waits.
        #expect(selection.state(of: Self.alphaID, items: nil) == .on)
        #expect(selection.checked.isEmpty)
        #expect(selection.isWaiting)

        related[Self.alphaID] = Self.alpha
        selection.loaded(Self.alphaID, related: related)
        #expect(!selection.isWaiting)
        // The same as ticking it after loading: the sure items, no «likely», no shared.
        #expect(selection.checked == [Self.alphaID, "/Users/me/Library/Caches/com.example.alpha"])
        #expect(selection.state(of: Self.alphaID, items: Self.alpha) == .on)
    }

    @Test func untickingBeforeTheFilesArriveLeavesNothing() {
        var selection = UninstallSelection()
        selection.select(Self.alphaID, items: nil, scope: .recommended, related: [:])
        selection.deselect(Self.alphaID, items: nil, related: [:])
        #expect(!selection.isWaiting)
        selection.loaded(Self.alphaID, related: [Self.alphaID: Self.alpha])
        #expect(selection.checked.isEmpty)
        #expect(selection.state(of: Self.alphaID, items: Self.alpha) == .off)
    }

    @Test func aTickThatCanNeverBeAppliedStopsHoldingRemoval() {
        var selection = UninstallSelection()
        selection.select(Self.alphaID, items: nil, scope: .recommended, related: [:])
        selection.forget(Self.alphaID)
        #expect(!selection.isWaiting)
    }

    @Test func everythingTakesLikelyItemsButNotSharedOnes() {
        var selection = UninstallSelection()
        let related = [Self.alphaID: Self.alpha, Self.betaID: Self.beta]
        selection.select(Self.alphaID, items: Self.alpha, scope: .recommended, related: related)
        #expect(!selection.hasEverything(Self.alpha))

        selection.select(Self.alphaID, items: Self.alpha, scope: .everything, related: related)
        #expect(selection.hasEverything(Self.alpha))
        #expect(selection.checked.contains("/Users/me/Library/Application Support/Alpha"))
        // Beta stays installed, so the folder they share stays.
        #expect(!selection.checked.contains("/Users/me/Library/Group Containers/group.example"))
        #expect(selection.state(of: Self.alphaID, items: Self.alpha) == .on)

        // Once Beta goes too, the shared folder follows; unticking Beta takes it back.
        selection.select(Self.betaID, items: Self.beta, scope: .recommended, related: related)
        #expect(selection.checked.contains("/Users/me/Library/Group Containers/group.example"))
        selection.deselect(Self.betaID, items: Self.beta, related: related)
        #expect(!selection.checked.contains("/Users/me/Library/Group Containers/group.example"))

        selection.deselect(Self.alphaID, items: Self.alpha, related: related)
        #expect(selection.checked.isEmpty)
    }

    @Test func checkStateCountsOnlyWhatSelectingTheAppTakes() {
        var selection = UninstallSelection()
        let related = [Self.alphaID: Self.alpha]
        selection.toggle(Self.alpha[1], related: related)
        #expect(selection.state(of: Self.alphaID, items: Self.alpha) == .mixed)
        selection.toggle(Self.alpha[0], related: related)
        #expect(selection.state(of: Self.alphaID, items: Self.alpha) == .on)
        selection.toggle(Self.alpha[1], related: related)
        #expect(selection.state(of: Self.alphaID, items: Self.alpha) == .mixed)
    }
}
