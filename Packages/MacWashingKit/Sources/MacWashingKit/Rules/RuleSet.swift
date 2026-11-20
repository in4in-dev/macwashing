import Foundation

/// What the rules say about a file.
public enum RuleVerdict: Sendable, Equatable {
    case keep
    case system
    case contentsOnly
    case expand
    case quitFirst
    case junk
    /// Belongs to one or more apps the database knows.
    case appFile([KnownApp])
    case unknown
}

/// How a rule recognises a file. Plain patterns are looked up by their keys (see `RuleHash`), other regexes tried as text.
///
/// `rules.is_regex` alone tells a regex from a literal (a literal may hold `+`, `(` or `\`). A literal's kind follows its
/// shape:
/// - starts with `/` or `~` → compared with the full path (or its ancestors);
/// - contains `/` → compared with the tail of the path;
/// - otherwise → compared with the file name (with or without `.plist`).
///
/// A regex is searched (no implied anchors) in the name, the path relative to the scanned root, the full path and the
/// path from home. A regex for a home path starts with `~/` itself (`~/Library/Application Support/Vendor/[^/]+/Cache$`):
/// the fingerprint resolves it from there. A regex that says no more than "equals", "starts with", "ends with",
/// "contains" or "the last part of the path starts with" a piece of plain text (`^com\.vendor\.app$`, `\.vmdk$`,
/// `Chrome`, `~/Library/Caches/JetBrains/IdeaIC[^/]*$`) is a `fragment`, found by the hash of the piece and its place.
/// Any other regex stays `regex`, tried one by one.
///
/// Everything compares without regard to letter case, the way the startup disk does.
enum Matcher: Sendable, Hashable {
    case name(RuleKey)
    case pathTail(RuleKey)
    /// `prefixAllowed`: the rule also covers everything inside the folder (see `Matcher.make`).
    case fullPath(RuleKey, prefixAllowed: Bool)
    case regex(RuleSet.Regex)
    case fragment(Fragment)

    /// A regex that is a piece of plain text and its place: the probe of the piece (`RuleHash.probe`), its length in
    /// UTF-8 bytes, and where the piece must be in one of the compared texts.
    struct Fragment: Sendable, Hashable {
        enum Place: UInt8 {
            case anywhere = 0, start = 1, end = 2, whole = 3
            /// No `/` after the piece (`piece[^/]*$`).
            case lastPart = 4
        }

        let probe: UInt64
        let length: Int
        let place: Place
        /// The regex starts with `/` or `~` (see `isPath`).
        let isPath: Bool
        /// The whole regex: a probe that fits is confirmed against it, so a name made to collide with the hash of a
        /// piece is never taken for the rule.
        let regex: RuleSet.Regex
    }

    /// The matcher for an authored rule. Nil for a regex that does not compile.
    static func make(for rule: RulesSource.Rule) -> Matcher? {
        let value = rule.pattern
        if rule.isRegex {
            guard let regex = RuleSet.Regex(pattern: value) else { return nil }
            if let (piece, place) = RuleSet.Regex.simple(value) {
                let fragment = Fragment(probe: RuleHash.probe(piece), length: piece.utf8.count, place: place,
                                        isPath: value.hasPrefix("/") || value.hasPrefix("~"), regex: regex)
                return .fragment(fragment)
            }
            return .regex(regex)
        }
        if value.hasPrefix("/") || value.hasPrefix("~") {
            let target = value.hasSuffix("/") ? String(value.dropLast()) : value
            // System, "contents" and "expand" rules name one folder (`/Library`, `~`); junk, keep and app rules cover
            // everything inside the folder too.
            let prefixAllowed = ![.system, .contents, .expand].contains(rule.action) && target != "~" && target != ""
            return .fullPath(RuleHash.key(.fullPath, target), prefixAllowed: prefixAllowed)
        }
        if value.contains("/") { return .pathTail(RuleHash.key(.pathTail, value)) }
        return .name(RuleHash.key(.name, value))
    }

    /// A rule written as an absolute or home path.
    var isPath: Bool {
        switch self {
        case .fullPath: true
        case .regex(let regex): regex.pattern.hasPrefix("/") || regex.pattern.hasPrefix("~")
        case .fragment(let fragment): fragment.isPath
        case .name, .pathTail: false
        }
    }
}

/// Indexed rules for one scanner.
///
/// Each file is turned into the few strings a plain rule could equal (its name, the tails and ancestors of its path);
/// those are hashed and looked up. Fragment rules are found by rolling their probes along the paths; only the regexes
/// kept as text are tried one by one.
public struct RuleSet: Sendable {
    struct Regex: @unchecked Sendable, Hashable {
        let expression: NSRegularExpression

        /// Compiled to ignore case, as file names on the startup disk compare.
        init?(pattern: String) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            self.expression = expression
        }

        var pattern: String { expression.pattern }

        func matches(_ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        static func == (lhs: Regex, rhs: Regex) -> Bool { lhs.pattern == rhs.pattern }
        func hash(into hasher: inout Hasher) { hasher.combine(pattern) }

        /// Marks where the piece was cut out of a regex: a private-use character, never in a pattern.
        static let placeholder = "\u{E000}"

        /// The longest run of plain characters that every match of `pattern` contains, folded (`RuleHash.fold`), and
        /// the pattern with that run replaced by `placeholder`; nil when the run is shorter than three bytes or the
        /// pattern has a `|` outside a group. Conservative: an atom that is optional, repeated, a class, a group, an
        /// anchor or an escape such as `\d` ends the run.
        static func split(_ pattern: String) -> (piece: String, template: String)? {
            enum Repeat { case once, optional, atLeastOnce }
            let chars = Array(pattern)
            guard !pattern.contains(placeholder) else { return nil }
            var atoms: [(character: Character?, repeats: Repeat, start: Int, end: Int)] = []
            var i = 0
            func skipClass() {
                i += 1
                if i < chars.count, chars[i] == "^" { i += 1 }
                if i < chars.count, chars[i] == "]" { i += 1 }
                while i < chars.count, chars[i] != "]" { i += chars[i] == "\\" ? 2 : 1 }
                i += 1
            }
            while i < chars.count {
                var character: Character?
                let start = i
                switch chars[i] {
                case "\\":
                    guard i + 1 < chars.count, chars[i + 1] != "Q" else { return nil }
                    character = chars[i + 1].isLetter || chars[i + 1].isNumber ? nil : chars[i + 1]
                    i += 2
                case "[":
                    skipClass()
                case "(":
                    var depth = 0
                    while i < chars.count {
                        if chars[i] == "\\" { i += 2; continue }
                        if chars[i] == "[" { skipClass(); continue }
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                        i += 1
                        if depth == 0 { break }
                    }
                case "|", "*", "+", "?", "{":
                    return nil
                case ".", "^", "$":
                    i += 1
                default:
                    character = chars[i]
                    i += 1
                }
                let end = i
                var repeats = Repeat.once
                if i < chars.count {
                    switch chars[i] {
                    case "*", "?":
                        repeats = .optional
                        i += 1
                    case "+":
                        repeats = .atLeastOnce
                        i += 1
                    case "{":
                        guard let close = chars[i...].firstIndex(of: "}") else { return nil }
                        repeats = chars[i + 1] == "0" || chars[i + 1] == "," ? .optional : .atLeastOnce
                        i = close + 1
                    default:
                        break
                    }
                    // Lazy and possessive forms (`*?`, `++`).
                    if repeats != .once, i < chars.count, chars[i] == "?" || chars[i] == "+" { i += 1 }
                }
                atoms.append((character, repeats, start, end))
            }
            // Runs of single plain characters; a repeated one (`s+`) is left out, so the run is replaced by itself alone.
            var best = (text: "", start: 0, end: 0), run = (text: "", start: 0, end: 0)
            func endRun() {
                if run.text.utf8.count > best.text.utf8.count { best = run }
                run = ("", 0, 0)
            }
            for atom in atoms {
                guard let character = atom.character, atom.repeats == .once else { endRun(); continue }
                if run.text.isEmpty { run.start = atom.start }
                run.text.append(character)
                run.end = atom.end
            }
            endRun()
            let piece = RuleHash.fold(best.text)
            guard piece.utf8.count >= 3 else { return nil }
            return (piece, String(chars[..<best.start]) + placeholder + String(chars[best.end...]))
        }

        /// The piece and its place when the regex says nothing else; `.*` before or after the piece changes nothing in
        /// a search.
        static func simple(_ pattern: String) -> (piece: String, place: Matcher.Fragment.Place)? {
            guard let (piece, template) = split(pattern), let mark = template.range(of: placeholder) else { return nil }
            var head = String(template[..<mark.lowerBound]), tail = String(template[mark.upperBound...])
            if head == ".*" || head == "^.*" { head = "" }
            if tail == ".*" || tail == ".*$" { tail = "" }
            switch (head, tail) {
            case ("", ""): return (piece, .anywhere)
            case ("^", ""): return (piece, .start)
            case ("", "$"): return (piece, .end)
            case ("^", "$"): return (piece, .whole)
            case ("", "[^/]*$"): return (piece, .lastPart)
            default: return nil
            }
        }
    }

    /// A matched rule and the text it matched (the longest text names the group of an app file).
    struct Hit {
        let rule: Rule
        let text: String
    }

    private var names: [RuleKey: [Rule]] = [:]
    private var tails: [RuleKey: [Rule]] = [:]
    private var fullPaths: [RuleKey: [Rule]] = [:]
    private var regexes: [(rule: Rule, regex: Regex)] = []
    private var fragments: [UInt64: [Rule]] = [:]
    /// Piece lengths in use, each with `base^(length - 1)` for rolling the probe.
    private var fragmentLengths: [(length: Int, power: UInt64)] = []
    /// One bit per low 16 bits of a stored probe: most positions of a path are turned down without a dictionary lookup.
    private var fragmentFilter = [UInt64](repeating: 0, count: 1024)

    init(rules: some Sequence<Rule>) {
        var lengths = Set<Int>()
        for rule in rules {
            switch rule.matcher {
            case .name(let key): names[key, default: []].append(rule)
            case .pathTail(let key): tails[key, default: []].append(rule)
            case .fullPath(let key, _): fullPaths[key, default: []].append(rule)
            case .regex(let regex): regexes.append((rule, regex))
            case .fragment(let fragment):
                fragments[fragment.probe, default: []].append(rule)
                lengths.insert(fragment.length)
                fragmentFilter[Int(fragment.probe & 0xffff) >> 6] |= 1 << (fragment.probe & 63)
            }
        }
        let base = RuleHash.probeKeys.base
        fragmentLengths = lengths.sorted().map { length in
            (length, (1 ..< max(length, 1)).reduce(UInt64(1)) { power, _ in power &* base })
        }
    }

    /// Candidate strings a file is compared against.
    public struct Subject: Sendable {
        public let name: String
        public let relativePath: String
        public let fullPath: String
        public let tildePath: String

        /// A bare file name, matched on its own (no path context).
        public init(name: String) {
            self.name = name
            relativePath = name
            fullPath = name
            tildePath = name
        }

        public init(url: URL, root: URL, home: URL) {
            name = url.lastPathComponent
            let full = url.fsPath
            let rootPath = root.fsPath
            let homePath = home.fsPath
            fullPath = full
            relativePath = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : name
            tildePath = full.hasPrefix(homePath + "/") ? "~/" + full.dropFirst(homePath.count + 1) : full
        }
    }

    /// Every part of `path` that follows a `/`.
    static func tails(of path: String) -> [String] {
        var result: [String] = []
        var rest = path[...]
        while let slash = rest.firstIndex(of: "/") {
            rest = rest[rest.index(after: slash)...]
            if !rest.isEmpty { result.append(String(rest)) }
        }
        return result
    }

    /// Every non-empty part of `path` that precedes a `/`.
    static func ancestors(of path: String) -> [String] {
        path.indices.compactMap { index in
            path[index] == "/" && index != path.startIndex ? String(path[..<index]) : nil
        }
    }

    func hits(_ subject: Subject) -> [Hit] {
        var hits: [Hit] = []
        func collect(_ rules: [Rule]?, _ text: String, where condition: (Rule) -> Bool = { _ in true }) {
            for rule in rules ?? [] where condition(rule) { hits.append(Hit(rule: rule, text: text)) }
        }

        if !names.isEmpty {
            // `name == value` or `name == value + ".plist"`.
            collect(names[RuleHash.key(.name, subject.name)], subject.name)
            if subject.name.count > 6, subject.name.suffix(6).lowercased() == ".plist" {
                let bare = String(subject.name.dropLast(".plist".count))
                collect(names[RuleHash.key(.name, bare)], bare)
            }
        }

        if !tails.isEmpty {
            // `relativePath == value` or either path ends with `"/" + value`.
            var seen = Set<String>()
            for text in [subject.relativePath] + Self.tails(of: subject.relativePath) + Self.tails(of: subject.tildePath)
            where seen.insert(text).inserted {
                collect(tails[RuleHash.key(.pathTail, text)], text)
            }
        }

        if !fullPaths.isEmpty {
            // `~` rules compare with the tilde path, others with the full path. The two never share a string unless they
            // are the same path (outside home), so both are looked up in one table.
            var exact: [String: Bool] = [:]
            for path in [subject.fullPath, subject.tildePath] {
                for ancestor in Self.ancestors(of: path) where exact[ancestor] == nil { exact[ancestor] = false }
            }
            exact[subject.fullPath] = true
            exact[subject.tildePath] = true
            for (text, isExact) in exact {
                collect(fullPaths[RuleHash.key(.fullPath, text)], text) { rule in
                    guard case .fullPath(_, let prefixAllowed) = rule.matcher else { return false }
                    return isExact || prefixAllowed
                }
            }
        }

        func anyText(_ regex: Regex) -> Bool {
            regex.matches(subject.name) || regex.matches(subject.relativePath) || regex.matches(subject.fullPath)
                || regex.matches(subject.tildePath)
        }

        if !fragments.isEmpty {
            // Every position of each text, for every piece length in use: a stored probe names the rules whose piece may
            // be there, and its place says whether that position counts.
            var matched = Set<Int64>()
            var seenTexts = Set<String>()
            let base = RuleHash.probeKeys.base
            for text in [subject.fullPath, subject.tildePath, subject.relativePath, subject.name] where seenTexts.insert(text).inserted {
                let bytes = Array(RuleHash.fold(text).utf8)
                let afterLastSlash = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
                for (length, power) in fragmentLengths where length <= bytes.count {
                    var raw = RuleHash.rawProbe(bytes[0 ..< length])
                    var start = 0
                    while true {
                        let probe = RuleHash.mixProbe(raw)
                        if fragmentFilter[Int(probe & 0xffff) >> 6] & (1 << (probe & 63)) != 0, let rules = fragments[probe] {
                            let atStart = start == 0, atEnd = start + length == bytes.count
                            for rule in rules where !matched.contains(rule.id) {
                                guard case .fragment(let fragment) = rule.matcher else { continue }
                                let fits = switch fragment.place {
                                case .anywhere: true
                                case .start: atStart
                                case .end: atEnd
                                case .whole: atStart && atEnd
                                case .lastPart: start + length >= afterLastSlash
                                }
                                guard fits, fragment.regex.matches(text) else { continue }
                                matched.insert(rule.id)
                                hits.append(Hit(rule: rule, text: String(decoding: bytes[start ..< start + length], as: UTF8.self)))
                            }
                        }
                        guard start + length < bytes.count else { break }
                        raw = (raw &- (UInt64(bytes[start]) &+ 1) &* power) &* base &+ UInt64(bytes[start + length]) &+ 1
                        start += 1
                    }
                }
            }
        }

        for (rule, regex) in regexes where anyText(regex) {
            hits.append(Hit(rule: rule, text: regex.pattern))
        }
        return hits.sorted { $0.rule.id < $1.rule.id }
    }

    /// All rules that match the subject, by id.
    public func matchingRules(_ subject: Subject) -> [Rule] {
        hits(subject).map(\.rule)
    }

    /// Resolves matching rules to one verdict.
    /// Priority: keep > system > contents > expand > quit > junk > app (cache and data rules are app rules here).
    public func verdict(for subject: Subject, database: Database? = nil) -> RuleVerdict {
        let matched = hits(subject)
        guard !matched.isEmpty else { return .unknown }
        let actions = Set(matched.map(\.rule.action))
        if actions.contains(.keep) { return .keep }
        if actions.contains(.system) { return .system }
        if actions.contains(.contents) { return .contentsOnly }
        if actions.contains(.expand) { return .expand }
        if actions.contains(.quit) { return .quitFirst }
        if actions.contains(.junk) { return .junk }
        if actions.contains(where: \.isAppFile), let database {
            // The most specific pattern first (the first app names a leftovers group), by its text, never by row id:
            // ids carry no meaning and may be reshuffled. Apps of rules with the same text (Keystone of Chrome and of
            // Google Drive), and of one rule, go by bundle id and name, not in the order of their rows.
            let byText = Dictionary(grouping: matched.filter { $0.rule.action.isAppFile }, by: \.text)
            let apps = byText.keys.sorted { ($0.count, $1) > ($1.count, $0) }.flatMap { text in
                byText[text, default: []].flatMap { database.apps(for: $0) }
                    .sorted { ($0.bundleID.lowercased(), $0.name) < ($1.bundleID.lowercased(), $1.name) }
            }
            if !apps.isEmpty { return .appFile(apps) }
        }
        return .unknown
    }
}
