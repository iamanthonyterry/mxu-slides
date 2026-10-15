import Foundation
import Testing
@testable import PresenterCore

@Suite struct DynamicValuesTests {

    private let values = ["offering": "$1,240", "sermon title": "Grace Upon Grace"]

    @Test func replacesTokensIgnoringCase() {
        let text = "Giving so far: {Offering}. Today: {SERMON TITLE}"
        #expect(
            DynamicValues.substitute(in: text, values: values)
                == "Giving so far: $1,240. Today: Grace Upon Grace"
        )
    }

    @Test func unknownTokensAndStrayBracesSurvive() {
        let text = "{Verse 1} { not a token } {} {Offering"
        #expect(DynamicValues.substitute(in: text, values: values) == text)
    }

    @Test func textWithoutBracesIsUntouched() {
        #expect(DynamicValues.substitute(in: "Amazing grace", values: values) == "Amazing grace")
        #expect(!DynamicValues.hasToken(in: "Amazing grace", values: values))
    }

    @Test func hasTokenOnlyForKnownNames() {
        #expect(DynamicValues.hasToken(in: "Total {offering}", values: values))
        #expect(!DynamicValues.hasToken(in: "Total {tithes}", values: values))
        #expect(!DynamicValues.hasToken(in: "Total {offering}", values: [:]))
    }

    @Test func replacementIsNotExpandedAgain() {
        let nested = ["a": "{b}", "b": "loop"]
        #expect(DynamicValues.substitute(in: "{a}", values: nested) == "{b}")
    }

    @Test func valuesMayContainNewlines() {
        let table = ["points": "One\nTwo"]
        #expect(DynamicValues.substitute(in: "Notes:\n{Points}", values: table) == "Notes:\nOne\nTwo")
    }

    @Test func namesAreValidatedForTokens() {
        #expect(DynamicValues.isValidName("Sermon Title"))
        #expect(!DynamicValues.isValidName("   "))
        #expect(!DynamicValues.isValidName("a{b"))
        #expect(!DynamicValues.isValidName("a}b"))
        #expect(!DynamicValues.isValidName("two\nlines"))
    }

    @Test func lookupPrefersFileTextAndFallsBackToTypedValue() {
        let entries = [
            DynamicValue(name: "Offering", value: "typed", filePath: "/live.txt"),
            DynamicValue(name: "Speaker", value: "Pastor Sam", filePath: "/missing.txt"),
            DynamicValue(name: "Welcome", value: "Hello"),
        ]
        let table = DynamicValues.lookup(entries) { path in
            path == "/live.txt" ? "from file" : nil
        }
        #expect(table == ["offering": "from file", "speaker": "Pastor Sam", "welcome": "Hello"])
    }

    @Test func lookupSkipsInvalidNamesAndKeepsTheFirstDuplicate() {
        let entries = [
            DynamicValue(name: "Title", value: "first"),
            DynamicValue(name: "title", value: "second"),
            DynamicValue(name: "{bad}", value: "x"),
        ]
        #expect(DynamicValues.lookup(entries) == ["title": "first"])
    }

    @Test func uniqueNameCountsUpPastTakenNames() {
        let existing = [DynamicValue(name: "Value"), DynamicValue(name: "value 2")]
        #expect(DynamicValues.uniqueName("Value", among: existing) == "Value 3")
        #expect(DynamicValues.uniqueName("Other", among: existing) == "Other")
    }

    @Test func fileContentsAreTrimmedNormalisedAndCapped() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-values-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = folder.appendingPathComponent("plain.txt")
        try "Line one\r\nLine two\r\n\r\n".write(to: plain, atomically: true, encoding: .utf8)
        #expect(DynamicValues.contents(ofFileAt: plain.path) == "Line one\nLine two")

        let empty = folder.appendingPathComponent("empty.txt")
        try "\n\n".write(to: empty, atomically: true, encoding: .utf8)
        #expect(DynamicValues.contents(ofFileAt: empty.path) == nil)

        let long = folder.appendingPathComponent("long.txt")
        try String(repeating: "x", count: DynamicValues.maxFileCharacters + 500)
            .write(to: long, atomically: true, encoding: .utf8)
        #expect(DynamicValues.contents(ofFileAt: long.path)?.count == DynamicValues.maxFileCharacters)

        #expect(DynamicValues.contents(ofFileAt: folder.appendingPathComponent("nope.txt").path) == nil)
    }

    @Test func valueRoundTripsThroughJSON() throws {
        let original = [
            DynamicValue(id: "1", name: "Offering", value: "0", filePath: "/tmp/offering.txt"),
            DynamicValue(id: "2", name: "Speaker", value: "Sam"),
        ]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([DynamicValue].self, from: data) == original)
    }
}
