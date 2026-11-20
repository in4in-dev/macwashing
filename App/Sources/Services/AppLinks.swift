import Foundation

/// Where MacWashing lives on GitHub. `MWRepository` (`owner/name`) is set once in `project.yml` (`MW_REPOSITORY`) and
/// lands in Info.plist; every address below is derived from it.
enum AppLinks {
    /// `owner/name` of the public repository.
    static let repositoryName: String = {
        let value = Bundle.main.infoDictionary?["MWRepository"] as? String ?? ""
        return value.isEmpty ? "in4in-dev/macwashing" : value
    }()

    /// The repository's page: the code, the releases, the issues.
    static let repository = URL(string: "https://github.com/" + repositoryName)!

    /// The folder of update files in the repository's `main` branch, served as they are:
    ///
    ///     appcast.xml                      Sparkle's feed of app releases (the DMGs are release assets)
    ///     rules/index.json, rules/<level>/ newer rules databases (`RulesUpdater`)
    ///
    /// Debug builds may point elsewhere with `MW_UPDATES_URL` (a folder served locally, say).
    static let updates: URL = {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["MW_UPDATES_URL"], !text.isEmpty, let url = URL(string: text) {
            return url
        }
        #endif
        return URL(string: "https://raw.githubusercontent.com/\(repositoryName)/main/updates/")!
    }()

    static var appcast: URL { updates.appending(path: "appcast.xml") }
    static var rules: URL { updates.appending(path: "rules/") }
}
