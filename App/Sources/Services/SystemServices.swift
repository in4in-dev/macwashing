import AppKit
import Foundation

enum ByteFormat {
    /// Formatting is thread-safe once configured; the formatter is never mutated after creation.
    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : formatter.string(fromByteCount: bytes)
    }

    /// For a counter that changes while you watch (scan and cleaning progress): trailing zeros kept («12,70 ГБ»), so a
    /// centred number keeps its width instead of jumping when one would be dropped.
    nonisolated(unsafe) private static let liveFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.zeroPadsFractionDigits = true
        return formatter
    }()

    static func live(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : liveFormatter.string(fromByteCount: bytes)
    }
}

enum RelativeDate {
    /// «Не открывалась 8 мес.» style wording for app and file ages.
    /// `approximate` prefixes «≈» (the date is a guess from the executable's last read).
    static func lastUsed(_ date: Date?, approximate: Bool = false, now: Date = .now) -> (text: String, days: Int?) {
        let result = exactLastUsed(date, now: now)
        return approximate && date != nil ? ("≈ " + result.text, result.days) : result
    }

    private static func exactLastUsed(_ date: Date?, now: Date) -> (text: String, days: Int?) {
        guard let date else { return (String(localized: "Не открывалась никогда"), nil) }
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        if days <= 0 { return (String(localized: "Открывалась сегодня"), 0) }
        if days < 30 { return (String(localized: "Открывалась \(days) дн. назад"), days) }
        let months = days / 30
        if days < 180 { return (String(localized: "Открывалась \(months) мес. назад"), days) }
        if days < 365 { return (String(localized: "Не открывалась \(months) мес."), days) }
        let years = days / 365
        return (String(localized: "Не открывалась \(years) г."), days)
    }

    static func opened(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        if days <= 0 { return String(localized: "Открывался сегодня") }
        if days < 30 { return String(localized: "Открывался \(days) дн. назад") }
        if days < 365 { return String(localized: "Открывался \(days / 30) мес. назад") }
        return String(localized: "Открывался \(days / 365) г. назад")
    }
}

/// Icons of apps and files, cached. Bounded: a results list of thousands of large files would otherwise keep every
/// icon it ever showed; `NSCache` drops the oldest ones (and everything under memory pressure).
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path(percentEncoded: false) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: key as String)
        cache.setObject(image, forKey: key)
        return image
    }
}
