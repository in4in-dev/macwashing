/// What the app tells the user after `SMAppService.daemon(...).register()` (Settings ▸ Доступ shows it under the
/// helper row).
public enum HelperRegistration {
    /// The registration error worth showing, or nil.
    ///
    /// On the first registration macOS registers the daemon, puts it in Login Items for approval **and** throws
    /// «Operation not permitted» (checked on macOS 14.8.7): that is the normal first step,
    /// not a failure, so it is not shown while the helper awaits approval. Nothing is shown once the helper runs either
    /// — an old error must not stay under «Установлен».
    public static func errorToShow(thrown: String?, awaitingApproval: Bool, enabled: Bool) -> String? {
        guard let thrown, !awaitingApproval, !enabled else { return nil }
        return thrown
    }
}
