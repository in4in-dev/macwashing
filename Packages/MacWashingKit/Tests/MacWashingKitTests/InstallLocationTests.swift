import Testing
@testable import MacWashingKit

@Suite("Install location")
struct InstallLocationTests {
    let home = "/Users/a"

    @Test func applicationsFoldersNeedNothing() {
        for path in ["/Applications/MacWashing.app", "/applications/Utilities/MacWashing.app", "/Users/a/Applications/MacWashing.app"] {
            #expect(InstallLocation.verdict(bundlePath: path, originalPath: path, home: home) == .installed, "\(path)")
        }
    }

    @Test func diskImageAndLooseCopiesMove() {
        let translocated = "/private/var/folders/x/T/AppTranslocation/1234/d/MacWashing.app"
        #expect(InstallLocation.verdict(bundlePath: translocated, originalPath: "/Volumes/MacWashing/MacWashing.app", home: home)
            == .move(fromDiskImage: true))
        #expect(InstallLocation.verdict(bundlePath: translocated, originalPath: "/Users/a/Downloads/MacWashing.app", home: home)
            == .move(fromDiskImage: false))
        #expect(InstallLocation.verdict(bundlePath: "/Users/a/Desktop/MacWashing.app", originalPath: "/Users/a/Desktop/MacWashing.app", home: home)
            == .move(fromDiskImage: false))
        // Opened from Applications but still translocated (a quarantined copy put there by hand): a fresh copy fixes it.
        #expect(InstallLocation.verdict(bundlePath: translocated, originalPath: "/Applications/MacWashing.app", home: home)
            == .move(fromDiskImage: false))
        // Someone else's Applications is not this user's.
        #expect(InstallLocation.verdict(bundlePath: "/Users/b/Applications/MacWashing.app", originalPath: "/Users/b/Applications/MacWashing.app", home: home)
            == .move(fromDiskImage: false))
    }

    @Test func destinationFallsBackToTheUsersApplications() {
        #expect(InstallLocation.destination(bundleName: "MacWashing.app", home: home, systemApplicationsWritable: true) == "/Applications/MacWashing.app")
        #expect(InstallLocation.destination(bundleName: "MacWashing.app", home: "/Users/a/", systemApplicationsWritable: false)
            == "/Users/a/Applications/MacWashing.app")
    }
}
