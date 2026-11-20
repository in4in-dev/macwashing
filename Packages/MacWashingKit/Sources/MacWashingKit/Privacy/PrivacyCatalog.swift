import Foundation

/// A permission type as System Settings ▸ Privacy & Security lists it (Camera, Files and Folders, Automation…).
/// Several TCC services can share one type: Files and Folders holds Desktop, Documents, Downloads and volumes.
public struct PrivacyCategory: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// SF Symbol close to the icon System Settings shows.
    public let symbol: String
    /// `Privacy_<Pane>` anchor of `x-apple.systempreferences:com.apple.preference.security`.
    public let settingsAnchor: String
    /// Sort position: the order of System Settings, «Другое» last.
    public let order: Int

    public var settingsURLs: [URL] {
        [
            "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsAnchor)",
        ].compactMap(URL.init(string:))
    }
}

/// One TCC service (`kTCCServiceCamera`) and where it is shown.
public struct PrivacyService: Sendable, Hashable {
    /// The id stored in TCC.db.
    public let id: String
    public let category: PrivacyCategory
    /// What exactly is granted, when the category holds several services («Папка «Загрузки»»).
    public let detail: String?
    /// False for a service the catalog does not know (shown under «Другое» with its raw id).
    public let isKnown: Bool

    /// The name `tccutil` takes: the id without the `kTCCService` prefix.
    public var shortName: String { PrivacyCatalog.shortName(of: id) }
}

public enum PrivacyCatalog {
    static let prefix = "kTCCService"

    public static func shortName(of service: String) -> String {
        service.hasPrefix(prefix) && service.count > prefix.count ? String(service.dropFirst(prefix.count)) : service
    }

    // MARK: Categories

    private static func category(_ id: String, _ title: String, _ symbol: String, _ anchor: String, _ order: Int) -> PrivacyCategory {
        PrivacyCategory(id: id, title: title, symbol: symbol, settingsAnchor: anchor, order: order)
    }

    /// Location Services are not kept in TCC.db (locationd has its own store): shown only as a link to Settings.
    public static let location =
        category("location", L10n.string("Службы геолокации"), "location.fill", "Privacy_LocationServices", 0)

    public static let other = category("other", L10n.string("Другое"), "questionmark.app.dashed", "Privacy", 1000)

    /// The major macOS version the app runs on: the catalog leaves out services it does not have (`introduced`).
    public static let systemMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    /// Every category, in the order of System Settings. The names are the same on 14, 15 and 26: Sonoma 14.8 also
    /// says «Запись экрана и системного аудио» (System Settings of 14.8.7; early 14.x releases may
    /// have said «Запись экрана» — not checked, not told apart).
    public static let categories: [PrivacyCategory] = [
        category("contacts", L10n.string("Контакты"), "person.crop.circle.fill", "Privacy_Contacts", 10),
        category("calendars", L10n.string("Календари"), "calendar", "Privacy_Calendars", 20),
        category("reminders", L10n.string("Напоминания"), "checklist", "Privacy_Reminders", 30),
        category("photos", L10n.string("Фото"), "photo.on.rectangle", "Privacy_Photos", 40),
        category("bluetooth", "Bluetooth", "dot.radiowaves.left.and.right", "Privacy_Bluetooth", 50),
        category("microphone", L10n.string("Микрофон"), "mic.fill", "Privacy_Microphone", 60),
        category("speech", L10n.string("Распознавание речи"), "waveform", "Privacy_SpeechRecognition", 70),
        category("camera", L10n.string("Камера"), "camera.fill", "Privacy_Camera", 80),
        category("home", L10n.string("Дом"), "house.fill", "Privacy_HomeKit", 90),
        category("media", L10n.string("Медиа и Apple Music"), "music.note", "Privacy_Media", 100),
        category("filesAndFolders", L10n.string("Файлы и папки"), "folder.fill", "Privacy_FilesAndFolders", 110),
        category("fullDiskAccess", L10n.string("Полный доступ к диску"), "internaldrive.fill", "Privacy_AllFiles", 120),
        category("focus", L10n.string("Фокусирование"), "moon.fill", "Privacy_Focus", 130),
        category("accessibility", L10n.string("Универсальный доступ"), "accessibility", "Privacy_Accessibility", 140),
        category("inputMonitoring", L10n.string("Мониторинг ввода"), "keyboard", "Privacy_ListenEvent", 150),
        category("screenRecording", L10n.string("Запись экрана и системного аудио"), "record.circle", "Privacy_ScreenCapture", 160),
        category("passkeys", L10n.string("Доступ к ключам входа для браузеров"), "person.badge.key.fill", "Privacy_PasskeyAccess", 170),
        category("automation", L10n.string("Автоматизация"), "gearshape.2.fill", "Privacy_Automation", 180),
        category("appManagement", L10n.string("Управление приложениями"), "app.badge.checkmark", "Privacy_AppBundles", 190),
        category("developerTools", L10n.string("Инструменты разработчика"), "hammer.fill", "Privacy_DevTools", 200),
        category("remoteDesktop", L10n.string("Удалённый рабочий стол"), "display", "Privacy_RemoteDesktop", 210),
        category("appData", L10n.string("Данные других программ"), "square.stack.3d.up.fill", "Privacy_AppData", 220),
        category("sysAdmin", L10n.string("Администрирование системы"), "lock.shield.fill", "Privacy", 230),
        category("tracking", L10n.string("Отслеживание"), "hand.raised.fill", "Privacy_Advertising", 240),
        other,
    ]

    private static let categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

    // MARK: Services

    /// Service suffix → category id and the detail shown on its rows.
    private static let known: [String: (category: String, detail: String?)] = {
        [
            "AddressBook": ("contacts", nil),
            "Calendar": ("calendars", nil),
            "Reminders": ("reminders", nil),
            "Photos": ("photos", nil),
            "PhotosAdd": ("photos", L10n.string("Только добавление")),
            "BluetoothAlways": ("bluetooth", nil),
            "Microphone": ("microphone", nil),
            "SpeechRecognition": ("speech", nil),
            "Camera": ("camera", nil),
            "Willow": ("home", nil),
            "MediaLibrary": ("media", nil),
            "SystemPolicyDesktopFolder": ("filesAndFolders", L10n.string("Папка «Рабочий стол»")),
            "SystemPolicyDocumentsFolder": ("filesAndFolders", L10n.string("Папка «Документы»")),
            "SystemPolicyDownloadsFolder": ("filesAndFolders", L10n.string("Папка «Загрузки»")),
            "SystemPolicyRemovableVolumes": ("filesAndFolders", L10n.string("Съёмные носители")),
            "SystemPolicyNetworkVolumes": ("filesAndFolders", L10n.string("Сетевые тома")),
            "FileProviderDomain": ("filesAndFolders", L10n.string("Файлы в облачных хранилищах")),
            "SystemPolicyAllFiles": ("fullDiskAccess", nil),
            "EndpointSecurityClient": ("fullDiskAccess", L10n.string("Клиент Endpoint Security")),
            "FocusStatus": ("focus", nil),
            "Accessibility": ("accessibility", nil),
            "PostEvent": ("accessibility", L10n.string("Управление клавиатурой и мышью")),
            "ListenEvent": ("inputMonitoring", nil),
            "ScreenCapture": ("screenRecording", nil),
            "AudioCapture": ("screenRecording", L10n.string("Только системное аудио")),
            "WebBrowserPublicKeyCredential": ("passkeys", nil),
            "AppleEvents": ("automation", nil),
            "SystemPolicyAppBundles": ("appManagement", nil),
            "DeveloperTool": ("developerTools", nil),
            "RemoteDesktop": ("remoteDesktop", nil),
            "SystemPolicyAppData": ("appData", nil),
            "SystemPolicySysAdminFiles": ("sysAdmin", nil),
            "UserTracking": ("tracking", nil),
        ]
    }()

    /// Services newer than macOS 14 (the oldest supported system): suffix → the first major version that has them.
    /// On an older system such a row cannot be a real decision, so it is not shown. None for now: tccd of Sonoma
    /// 14.8.7 knows every service of the catalog, `SystemPolicyAppData` and `AudioCapture` too.
    static let introduced: [String: Int] = [:]

    /// Whether macOS `major` has the TCC service `id` (unknown services are taken as existing).
    public static func exists(_ id: String, onMacOS major: Int = systemMajor) -> Bool {
        exists(id, onMacOS: major, introduced: introduced)
    }

    static func exists(_ id: String, onMacOS major: Int, introduced: [String: Int]) -> Bool {
        guard let first = introduced[shortName(of: id)] else { return true }
        return major >= first
    }

    /// Internal iCloud and sharing services: kept in TCC.db, never shown in System Settings.
    static let hidden: Set<String> = ["Liverpool", "Ubiquity", "ShareKit"]

    public static func isHidden(_ service: String) -> Bool {
        hidden.contains(shortName(of: service))
    }

    /// The catalog entry of a TCC service id. Unknown ids land in «Другое» with the raw id as detail.
    public static func service(_ id: String) -> PrivacyService {
        if id.hasPrefix(prefix), let entry = known[shortName(of: id)], let category = categoriesByID[entry.category] {
            return PrivacyService(id: id, category: category, detail: entry.detail, isKnown: true)
        }
        return PrivacyService(id: id, category: other, detail: id, isKnown: false)
    }
}
