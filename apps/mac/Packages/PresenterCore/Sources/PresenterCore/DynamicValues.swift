import Foundation

/// A named piece of text that slides read with `{Name}`. It holds its own
/// text, or follows a plain text file that something else keeps up to date.
public struct DynamicValue: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String

    /// Typed by hand. Also the fallback while the file is missing or empty.
    public var value: String

    /// A text file to read the value from. The file wins when it has content.
    public var filePath: String?

    public init(id: String = UUID().uuidString, name: String, value: String = "", filePath: String? = nil) {
        self.id = id
        self.name = name
        self.value = value
        self.filePath = filePath
    }
}

public enum DynamicValues {

    /// Longest text a file contributes. Keeps a stray large file from
    /// flooding a slide or the render loop.
    public static let maxFileCharacters = 4_000

    /// Names are matched without regard to case, so `{offering}` and
    /// `{Offering}` read the same value.
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether `name` can be written as a `{token}` and read back.
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.contains("{") && !trimmed.contains("}")
            && !trimmed.contains("\n")
    }

    public static func token(for name: String) -> String { "{\(name)}" }

    /// Replaces each `{Name}` with its value. A token with no matching name is
    /// left as written, so braces in lyrics and notes survive.
    public static func substitute(in text: String, values: [String: String]) -> String {
        guard !values.isEmpty, text.contains("{") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "{",
               let close = text[index...].firstIndex(of: "}") {
                let inner = text[text.index(after: index) ..< close]
                if !inner.isEmpty, !inner.contains("{"),
                   let value = values[key(String(inner))] {
                    result += value
                    index = text.index(after: close)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    public static func hasToken(in text: String, values: [String: String]) -> Bool {
        guard !values.isEmpty, text.contains("{") else { return false }
        return substitute(in: text, values: values) != text
    }

    /// The text of a value file: trailing blank lines and the final newline
    /// dropped, carriage returns normalised, capped at ``maxFileCharacters``.
    /// Nil when the file cannot be read as text or has nothing in it.
    public static func contents(ofFileAt path: String) -> String? {
        guard !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              var text = String(data: data, encoding: .utf8)
        else { return nil }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if text.count > maxFileCharacters { text = String(text.prefix(maxFileCharacters)) }
        return text
    }

    /// The lookup table slides read: lowercased name to current text. The
    /// first of two values with the same name wins.
    public static func lookup(
        _ values: [DynamicValue], fileText: (String) -> String? = contents(ofFileAt:)
    ) -> [String: String] {
        var table: [String: String] = [:]
        for entry in values where isValidName(entry.name) {
            let name = key(entry.name)
            guard table[name] == nil else { continue }
            let fromFile = entry.filePath.flatMap { $0.isEmpty ? nil : fileText($0) }
            table[name] = fromFile ?? entry.value
        }
        return table
    }

    /// A name for a new value that no existing value uses.
    public static func uniqueName(_ base: String, among values: [DynamicValue]) -> String {
        let taken = Set(values.map { key($0.name) })
        guard taken.contains(key(base)) else { return base }
        var number = 2
        while taken.contains(key("\(base) \(number)")) { number += 1 }
        return "\(base) \(number)"
    }
}
