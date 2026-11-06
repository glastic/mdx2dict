import XCTest
@testable import mdx2dict

final class SanitizerTests: XCTestCase {
    func testRemovesScriptsAndEventHandlers() {
        let html = """
        <html><body>
        <div class="x" onclick="evil()">
          <script>alert(1)</script>
          <p>Hello</p>
        </div>
        </body></html>
        """
        let output = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(output.lowercased().contains("<script"))
        XCTAssertFalse(output.lowercased().contains("onclick"))
        XCTAssertTrue(output.contains("Hello"))
    }

    func testRewritesEntryLinks() {
        let html = "<html><body><a href=\"entry://target\">go</a></body></html>"
        let output = HTMLSanitizer.sanitize(
            html,
            linkResolver: { $0 == "target" ? "e1" : nil }
        )
        XCTAssertTrue(output.contains("x-dictionary:r:e1"))
    }

    func testAudioExcludeRegex() {
        let html = """
        <html><body>
        <a href="sound://example.mp3" class="example">x</a>
        </body></html>
        """
        let regex = try! NSRegularExpression(pattern: "example")
        let output = HTMLSanitizer.sanitize(
            html,
            audioPolicy: .all,
            audioExclude: regex,
            audioResolver: { _ in "audio/x.mp3" }
        )
        XCTAssertFalse(output.contains("new Audio"))
    }

    func testPreservesCustomWrapper() {
        let html = """
        <html><body><custom-wrapper class="root"><p>Text</p></custom-wrapper></body></html>
        """
        let output = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(output.contains("<custom-wrapper"))
        XCTAssertTrue(output.contains("Text"))
    }
}
