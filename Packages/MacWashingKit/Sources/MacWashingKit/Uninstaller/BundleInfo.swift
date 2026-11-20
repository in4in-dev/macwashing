import Foundation
import Security

/// What an app bundle says about itself beyond its bundle id: the ids of the helpers and extensions it carries, its
/// executable name and the app groups it is entitled to (the names of its Group Containers).
struct BundleInfo: Sendable {
    let executable: String?
    /// Lower-cased ids of embedded login items, XPC services, extensions and privileged helpers (Apple's left out).
    let embeddedIDs: [String]
    /// Lower-cased `com.apple.security.application-groups` entitlements.
    let appGroups: [String]

    static let embeddedFolders = [
        "Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/XPCServices", "Contents/PlugIns",
        "Contents/Library/SystemExtensions", "Contents/Helpers", "Contents/Library/Helpers",
    ]

    init(_ bundle: URL) {
        executable = Self.plist(bundle.appending(path: "Contents/Info.plist"))?["CFBundleExecutable"] as? String
        var ids: [String] = []
        for folder in Self.embeddedFolders {
            for child in FileSystem.children(of: bundle.appending(path: folder)) {
                let plist = Self.plist(child.appending(path: "Contents/Info.plist")) ?? Self.plist(child.appending(path: "Info.plist"))
                // Tools in LaunchServices are bare executables named after their launchd label.
                let id = (plist?["CFBundleIdentifier"] as? String)
                    ?? (BundleID.looksLikeBundleID(child.lastPathComponent) ? child.lastPathComponent : nil)
                if let id, !BundleID.isApple(id) { ids.append(id.lowercased()) }
            }
        }
        embeddedIDs = Array(Set(ids)).sorted()
        appGroups = Self.entitlements(of: bundle)["com.apple.security.application-groups"].flatMap { $0 as? [String] }?.map { $0.lowercased() } ?? []
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Entitlements from the code signature, without validating it (an unsigned bundle has none).
    static func entitlements(of bundle: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return [:] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return [:] }
        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }
}
