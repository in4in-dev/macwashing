import CryptoKit
import Foundation

/// A rule pattern (or a piece of a path) reduced to a lookup key: the first 128 bits of its SHA-256.
public struct RuleKey: Hashable, Sendable {
    let high: UInt64
    let low: UInt64

    init(_ digest: SHA256.Digest) {
        (high, low) = digest.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self), raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
    }
}

/// The hashes behind the rules index (`RuleSet`).
///
/// A file is turned into the few strings a rule could equal (its name, the tails and ancestors of its path); those are
/// hashed and looked up, so a scan never compares a file with every rule. Text is compared without regard to letter
/// case, as the startup disk compares it, and by canonical equivalence (the NFC pass): see `fold`.
enum RuleHash {
    enum Domain: UInt8 {
        case name = 1
        case pathTail = 2
        case fullPath = 3
    }

    /// Text as rules compare it: precomposed (NFC) and lower-cased. ASCII, almost every file name, skips Foundation.
    static func fold(_ text: String) -> String {
        var hasUpper = false
        for byte in text.utf8 {
            if byte >= 0x80 { return text.precomposedStringWithCanonicalMapping.lowercased() }
            if byte >= 0x41 && byte <= 0x5a { hasUpper = true }
        }
        guard hasUpper else { return text }
        return String(decoding: text.utf8.map { $0 >= 0x41 && $0 <= 0x5a ? $0 | 0x20 : $0 }, as: UTF8.self)
    }

    static func key(_ domain: Domain, _ text: String) -> RuleKey {
        var hasher = SHA256()
        hasher.update(data: [0x4d, 0x57, domain.rawValue])
        hasher.update(data: Data(fold(text).utf8))
        return RuleKey(hasher.finalize())
    }

    // MARK: Probes

    /// A fragment rule's piece is looked for at every position of a path, which is too many places for SHA-256: a
    /// polynomial hash rolls along the path instead (`RuleSet.hits`).
    static let probeKeys: (base: UInt64, mix: UInt64) = (base: 0x100000001b3, mix: 0x9e3779b97f4a7c15)

    /// The rolling hash of `bytes` before mixing; `RuleSet.hits` updates it one byte at a time.
    static func rawProbe(_ bytes: some Sequence<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 &* probeKeys.base &+ UInt64($1) &+ 1 }
    }

    /// What is stored and looked up: the raw hash, mixed (SplitMix64's finaliser) so nearby values spread out.
    static func mixProbe(_ raw: UInt64) -> UInt64 {
        var z = raw ^ probeKeys.mix
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// The probe of a piece of text (folded first).
    static func probe(_ piece: String) -> UInt64 {
        mixProbe(rawProbe(fold(piece).utf8))
    }
}
