import Foundation
import NaturalLanguage

/// Kinds of personal data replaced on the device. Each becomes a typed placeholder such as `[email]`.
public enum RedactionKind: String, CaseIterable, Codable, Sendable {
    case person, org, email, phone, number, link, address
    public var placeholder: String { "[\(rawValue)]" }
}

public struct RedactionResult: Sendable, Equatable {
    public let text: String
    public let counts: [RedactionKind: Int]
    public var total: Int { counts.values.reduce(0, +) }
}

/// Redaction method `on-device-v1`. Runs entirely on the Mac, before anything is sent.
///
/// Order matters: specific patterns first (emails, links, card-like and ID-like numbers), then
/// Foundation's data detectors (addresses, phone numbers), then name recognition. A person name
/// found anywhere is also removed everywhere else it appears ("Kemi's email").
public struct Redactor: Sendable {
    public static let method = "on-device-v1"

    public init() {}

    private struct Rule: Sendable {
        let kind: RedactionKind
        let pattern: String
        let options: NSRegularExpression.Options
        init(_ kind: RedactionKind, _ pattern: String, _ options: NSRegularExpression.Options = []) {
            self.kind = kind; self.pattern = pattern; self.options = options
        }
    }

    private static let leadingRules: [Rule] = [
        Rule(.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        // Any URL, with or without a scheme, including its path and query string (tokens live there).
        Rule(.link, #"\b(?:https?://|www\.)[^\s<>"]+"#, [.caseInsensitive]),
        Rule(.link, #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|ai|co|ca|dev|app|me|edu|gov|fr|uk|us)(?:/[^\s<>"]*)?"#, [.caseInsensitive]),
        // IBAN-like account identifiers.
        Rule(.number, #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#),
        // Card-like: 13 to 19 digits, optionally grouped by spaces or hyphens.
        Rule(.number, #"(?<![\w-])\d(?:[ -]?\d){12,18}(?![\w-])"#),
        // SIN- or SSN-shaped IDs: 3-3-3 or 3-2-4 digit groups.
        Rule(.number, #"(?<![\w-])\d{3}[ -]\d{3}[ -]\d{3}(?![\w-])"#),
        Rule(.number, #"(?<![\w-])\d{3}-\d{2}-\d{4}(?![\w-])"#),
        // Canadian postal codes and street lines the data detector can miss in short UI text.
        Rule(.address, #"\b\d{1,6}\s+(?:[A-Z][a-z]+\s+){1,3}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|Court|Ct|Place|Pl|Crescent|Cres)\b\.?(?:\s+(?:East|West|North|South|E|W|N|S)\b)?"#),
        Rule(.address, #"\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPR-TV-Z] ?\d[ABCEGHJ-NPR-TV-Z]\d\b"#),
    ]

    private static let trailingRules: [Rule] = [
        Rule(.phone, #"(?<![\w.])(?:\+\d{1,3}[ .-]?)?(?:\(\d{2,4}\)[ .-]?|\d{2,4}[ .-])\d{3,4}[ .-]?\d{3,4}(?!\w)"#),
        Rule(.number, #"(?<!\w)\d{6,}(?!\w)"#),
    ]

    public func redact(_ input: String) -> RedactionResult {
        var text = input
        var counts: [RedactionKind: Int] = [:]
        for rule in Self.leadingRules { apply(rule, to: &text, counts: &counts) }
        applyDataDetector(to: &text, counts: &counts)
        for rule in Self.trailingRules { apply(rule, to: &text, counts: &counts) }
        applyNames(to: &text, counts: &counts)
        return RedactionResult(text: text, counts: counts)
    }

    private func apply(_ rule: Rule, to text: inout String, counts: inout [RedactionKind: Int]) {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { return }
        replace(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range), with: rule.kind, in: &text, counts: &counts)
    }

    private func applyDataDetector(to text: inout String, counts: inout [RedactionKind: Int]) {
        let types: NSTextCheckingResult.CheckingType = [.address, .phoneNumber, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return }
        var byKind: [RedactionKind: [NSRange]] = [:]
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let matched = (text as NSString).substring(with: match.range)
            if matched.hasPrefix("[") && matched.hasSuffix("]") { continue }
            switch match.resultType {
            case .address: byKind[.address, default: []].append(match.range)
            case .phoneNumber: byKind[.phone, default: []].append(match.range)
            case .link: byKind[.link, default: []].append(match.range)
            default: break
            }
        }
        // Replace all detector hits in one pass, from the end, so earlier ranges stay valid.
        let all = byKind.flatMap { kind, ranges in ranges.map { (kind, $0) } }.sorted { $0.1.location > $1.1.location }
        var lastStart = Int.max
        for (kind, range) in all where range.location + range.length <= lastStart {
            guard let swiftRange = Range(range, in: text) else { continue }
            text.replaceSubrange(swiftRange, with: kind.placeholder)
            counts[kind, default: 0] += 1
            lastStart = range.location
        }
    }

    private func applyNames(to text: inout String, counts: inout [RedactionKind: Int]) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var people: [String] = []
        var orgs: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let token = String(text[range])
            if tag == .personalName { people.append(token) }
            if tag == .organizationName { orgs.append(token) }
            return true
        }
        // Every word of a detected name, so "Kemi's" and a bare "Bello" go too.
        var personWords = Set<String>()
        for name in people {
            for part in name.split(separator: " ") where part.count >= 2 && part.first?.isUppercase == true {
                personWords.insert(String(part))
            }
        }
        let byLength: (String, String) -> Bool = { $0.count > $1.count }
        replaceWords(personWords.sorted(by: byLength), kind: .person, in: &text, counts: &counts)
        replaceWords(Set(orgs).sorted(by: byLength), kind: .org, in: &text, counts: &counts)
    }

    private func replaceWords(_ words: [String], kind: RedactionKind, in text: inout String, counts: inout [RedactionKind: Int]) {
        for word in words {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\[])"# + escaped + #"(?!\p{L})"#) else { continue }
            replace(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range), with: kind, in: &text, counts: &counts)
        }
        // "[person] [person]" from a first and last name reads as one person.
        while let range = text.range(of: "\(kind.placeholder) \(kind.placeholder)") {
            text.replaceSubrange(range, with: kind.placeholder)
            counts[kind, default: 1] -= 1
        }
    }

    private func replace(_ ranges: [NSRange], with kind: RedactionKind, in text: inout String, counts: inout [RedactionKind: Int]) {
        for range in ranges.reversed() {
            guard let swiftRange = Range(range, in: text) else { continue }
            text.replaceSubrange(swiftRange, with: kind.placeholder)
            counts[kind, default: 0] += 1
        }
    }
}
