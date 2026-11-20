import Foundation

/// What `tccutil reset` may be asked to do. Shared by the app and the helper; the helper re-checks every request.
///
/// Only one shape is ever allowed: `tccutil reset <Service> <bundle id>`, for a service on the list below and a
/// third-party reverse-DNS bundle id. Never `All`, never a service without a bundle id (that would reset every app),
/// never Apple's own clients and never MacWashing itself.
public enum TCCResetPolicy {
    public static let toolPath = "/usr/bin/tccutil"

    /// Services (the TCC id without the `kTCCService` prefix) whose decisions may be reset.
    public static let services: Set<String> = [
        "Accessibility", "AddressBook", "AppleEvents", "AudioCapture", "BluetoothAlways", "Calendar", "Camera",
        "DeveloperTool", "EndpointSecurityClient", "FileProviderDomain", "FocusStatus", "ListenEvent", "MediaLibrary",
        "Microphone", "Photos", "PhotosAdd", "PostEvent", "Reminders", "RemoteDesktop", "ScreenCapture",
        "SpeechRecognition", "SystemPolicyAllFiles", "SystemPolicyAppBundles", "SystemPolicyAppData",
        "SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder",
        "SystemPolicyNetworkVolumes", "SystemPolicyRemovableVolumes", "SystemPolicySysAdminFiles", "UserTracking",
        "WebBrowserPublicKeyCredential", "Willow",
    ]

    /// Clients that are never reset: resetting MacWashing's own access would cut it off from the TCC databases.
    static let protectedClients: Set<String> = [
        HelperConstants.appBundleID.lowercased(), HelperConstants.machServiceName.lowercased(),
    ]

    public enum Rejection: Error, Equatable, Sendable {
        case unknownService
        case invalidBundleID
        case appleClient
        case protectedClient
    }

    /// A reverse-DNS bundle id: two or more dot-separated parts of letters, digits, `-` and `_`, starting with a
    /// letter or digit (so it can never be read as an option), at most 255 characters.
    public static func isReverseDNS(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255 else { return false }
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            guard let first = part.unicodeScalars.first, isASCIIAlphanumeric(first) else { return false }
            guard part.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "-" || $0 == "_" }) else { return false }
        }
        return true
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    public static func isAppleClient(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return lower == "com.apple" || lower.hasPrefix("com.apple.")
    }

    public static func validate(service: String, bundleID: String) -> Rejection? {
        guard services.contains(service) else { return .unknownService }
        guard isReverseDNS(bundleID) else { return .invalidBundleID }
        guard !isAppleClient(bundleID) else { return .appleClient }
        guard !protectedClients.contains(bundleID.lowercased()) else { return .protectedClient }
        return nil
    }

    /// Arguments for `tccutil`, or nil when the request is not allowed.
    public static func arguments(service: String, bundleID: String) -> [String]? {
        validate(service: service, bundleID: bundleID) == nil ? ["reset", service, bundleID] : nil
    }
}
