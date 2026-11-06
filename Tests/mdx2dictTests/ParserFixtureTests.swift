import XCTest
@testable import mdx2dict

final class ParserFixtureTests: XCTestCase {
    private var fixturePath: String!

    override func setUpWithError() throws {
        fixturePath = NSTemporaryDirectory()
            + "mdx2dict-fixture-\(UUID().uuidString).mdx"
        try MDictFixture.make(path: fixturePath)
    }

    override func tearDownWithError() throws {
        if let fixturePath {
            try? FileManager.default.removeItem(atPath: fixturePath)
        }
    }

    func testEntryCountAndLookup() throws {
        let reader = try MDictReader(path: fixturePath)
        try reader.open()

        XCTAssertEqual(reader.entryCount, 3)

        let apple = try reader.lookup("apple")
        XCTAssertTrue(apple?.contains("A fruit.") == true)

        let plural = try reader.lookup("apples")
        XCTAssertTrue(plural?.contains("A fruit.") == true)
    }

    func testRedirectRecordAndOffset() throws {
        let reader = try MDictReader(path: fixturePath)
        try reader.open()

        guard let offset = try reader.recordOffset(for: "apples") else {
            return XCTFail("missing apples key")
        }
        let raw = try reader.rawDefinition(at: offset)
        XCTAssertTrue(raw.hasPrefix("@@@LINK=apple"))

        let followed = try reader.lookup("apples")
        XCTAssertTrue(followed?.contains("A fruit.") == true)
    }

    func testPrefixSuggestions() throws {
        let reader = try MDictReader(path: fixturePath)
        try reader.open()

        XCTAssertEqual(
            try reader.suggest("ap", limit: 10),
            ["apple", "apples"]
        )
    }
}
