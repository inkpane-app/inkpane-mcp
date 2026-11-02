import Foundation

/// A piece of text that looks like personal data.
public struct SensitiveMatch: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case email
        case phoneNumber = "phone_number"
    }

    public var kind: Kind
    public var range: Range<String.Index>
    public var text: String
}

/// Finds email addresses and phone numbers in recognized text, for auto-redaction.
///
/// Deliberately conservative about phone numbers: it wants 7–15 digits and either a leading
/// `+`, separators that look like a phone number (spaces, dashes, dots, parentheses), or a
/// Chinese mobile number (11 digits starting with 1[3-9]). Dates, IP addresses, version
/// numbers and long bare digit runs (ids, timestamps) are not matched.
public struct SensitiveTextDetector: Sendable {
    public var emails: Bool
    public var phoneNumbers: Bool

    public init(emails: Bool = true, phoneNumbers: Bool = true) {
        self.emails = emails
        self.phoneNumbers = phoneNumbers
    }

    public init(_ options: RedactionOptions) {
        self.init(emails: options.emails, phoneNumbers: options.phoneNumbers)
    }

    public var isEnabled: Bool { emails || phoneNumbers }

    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}+.\-])\+?\(?\d[\d  ().\-]{5,}\d\)?(?![\p{L}\p{N}])"#)
    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(?:\d{4}[\-./ ]\d{1,2}[\-./ ]\d{1,2}|\d{1,2}[\-./ ]\d{1,2}[\-./ ]\d{2,4})$"#)

    /// Matches in `text`, in order, without overlaps (emails win over phone numbers).
    public func matches(in text: String) -> [SensitiveMatch] {
        var found: [SensitiveMatch] = []
        let whole = NSRange(text.startIndex..., in: text)
        if emails {
            for result in Self.emailPattern.matches(in: text, range: whole) {
                guard let range = Range(result.range, in: text) else { continue }
                found.append(SensitiveMatch(kind: .email, range: range, text: String(text[range])))
            }
        }
        if phoneNumbers {
            for result in Self.phonePattern.matches(in: text, range: whole) {
                guard var range = Range(result.range, in: text) else { continue }
                // Trailing spaces or separators the pattern swallowed.
                while range.lowerBound < range.upperBound, let last = text[range].last, !last.isNumber, last != ")" {
                    range = range.lowerBound..<text.index(before: range.upperBound)
                }
                let candidate = String(text[range])
                guard Self.isPhoneNumber(candidate) else { continue }
                if found.contains(where: { $0.range.overlaps(range) }) { continue }
                found.append(SensitiveMatch(kind: .phoneNumber, range: range, text: candidate))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `text` with every match replaced by a placeholder such as `[email]`.
    public func redact(_ text: String) -> String {
        let found = matches(in: text)
        guard !found.isEmpty else { return text }
        var result = text
        for match in found.reversed() {
            result.replaceSubrange(match.range, with: Self.placeholder(match.kind))
        }
        return result
    }

    public static func placeholder(_ kind: SensitiveMatch.Kind) -> String {
        switch kind {
        case .email: "[email]"
        case .phoneNumber: "[phone]"
        }
    }

    static func isPhoneNumber(_ candidate: String) -> Bool {
        let digits = candidate.filter(\.isASCIIDigit)
        guard (7...15).contains(digits.count) else { return false }
        let separators = Set(candidate.filter { !$0.isASCIIDigit && $0 != "+" })
        let hasPlus = candidate.hasPrefix("+") || candidate.hasPrefix("(+")
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if datePattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil { return false }
        if separators.isEmpty {
            // A bare digit run: only an international number or a Chinese mobile number.
            if hasPlus { return digits.count >= 8 }
            return digits.count == 11 && digits.hasPrefix("1") && "3456789".contains(digits[digits.index(after: digits.startIndex)])
        }
        // Dots alone are IP addresses, versions and amounts far more often than phone numbers.
        if separators == ["."] && !hasPlus { return false }
        // Groups of digits: phone numbers have no group longer than 5 digits after the first
        // (except the subscriber part of some formats) and at least 7 digits overall.
        let groups = candidate.split { !$0.isASCIIDigit }.map(\.count)
        if groups.count >= 2, groups.dropFirst().contains(where: { $0 > 8 }) { return false }
        return true
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
