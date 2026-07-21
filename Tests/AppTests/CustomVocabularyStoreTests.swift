import XCTest
@testable import App

final class CustomVocabularyStoreTests: XCTestCase {
    func testParseIgnoresCommentsAndSplitsAliases() {
        let content = """
        # Comment
        Alex Christou: alex christu, alex chris too
        Claude Code: claw code, cloud code
        BareCanonical
        """

        let entries = CustomVocabularyCodec.parse(content)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0], .init(canonical: "Alex Christou", aliases: ["alex christu", "alex chris too"]))
        XCTAssertEqual(entries[1], .init(canonical: "Claude Code", aliases: ["claw code", "cloud code"]))
        XCTAssertEqual(entries[2], .init(canonical: "BareCanonical", aliases: []))
    }

    func testSerializeDeduplicatesAliasesAndDropsCanonicalAlias() {
        let entries = [
            CustomVocabularyStore.Entry(
                canonical: "Alex Christou",
                aliasesText: "alex christu, alex chris too, Alex Christou, alex christu"
            )
        ]

        let serialized = CustomVocabularyCodec.serialize(entries: entries)

        XCTAssertTrue(serialized.contains("Alex Christou: alex christu, alex chris too"))
        XCTAssertFalse(serialized.contains("Alex Christou,"))
    }

    func testSerializeWritesBareCanonicalWhenAliasesAreEmpty() {
        let entries = [
            CustomVocabularyStore.Entry(
                canonical: "OpenAI",
                aliasesText: ""
            )
        ]

        let serialized = CustomVocabularyCodec.serialize(entries: entries)

        XCTAssertTrue(serialized.contains("\nOpenAI\n"))
        XCTAssertFalse(serialized.contains("OpenAI:"))
    }
}
