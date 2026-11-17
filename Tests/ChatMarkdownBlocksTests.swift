import XCTest
@testable import IysCodeMovilCore

/// The chat flattened block structure, so paragraphs and list items ran together. These tests pin that every break the
/// model wrote survives, using the real messages that came out wrong on the phone.
final class ChatMarkdownBlocksTests: XCTestCase {
    func testParagraphsStaySeparate() {
        let blocks = ChatMarkdownParser.parse("Según el estado del iPhone:\n\n**App abierta al frente:** iSyCode\n**Bloqueado:** No")
        XCTAssertEqual(blocks, [
            .paragraph("Según el estado del iPhone:"),
            .paragraph("**App abierta al frente:** iSyCode\n**Bloqueado:** No")
        ])
    }

    func testSoftLineBreaksInsideAParagraphAreKept() {
        XCTAssertEqual(ChatMarkdownParser.parse("uno\ndos\ntres"), [.paragraph("uno\ndos\ntres")])
    }

    func testBulletsAndNumberedItemsAreOneBlockEach() {
        let blocks = ChatMarkdownParser.parse("Arquitectura:\n- Sandbox\n- WDA\n  - USB\n1. Uno\n2) Dos")
        XCTAssertEqual(blocks, [
            .paragraph("Arquitectura:"),
            .bullet(indent: 0, text: "Sandbox"),
            .bullet(indent: 0, text: "WDA"),
            .bullet(indent: 1, text: "USB"),
            .numbered(indent: 0, number: 1, text: "Uno"),
            .numbered(indent: 0, number: 2, text: "Dos")
        ])
    }

    func testBoldAtTheStartOfALineIsNotABullet() {
        XCTAssertEqual(ChatMarkdownParser.parse("**negrita** al inicio"), [.paragraph("**negrita** al inicio")])
        XCTAssertEqual(ChatMarkdownParser.parse("* viñeta"), [.bullet(indent: 0, text: "viñeta")])
    }

    func testHeadingsRulesAndQuotes() {
        XCTAssertEqual(ChatMarkdownParser.parse("# Título\n---\n> cita\n> más"), [
            .heading(level: 1, text: "Título"),
            .rule,
            .quote("cita\nmás")
        ])
        XCTAssertEqual(ChatMarkdownParser.parse("#sin espacio"), [.paragraph("#sin espacio")])
    }

    func testCodeFencesKeepTheirContentVerbatim() {
        let blocks = ChatMarkdownParser.parse("Mira:\n```swift\nlet a = 1\n\n- no es lista\n```\nListo.")
        XCTAssertEqual(blocks, [
            .paragraph("Mira:"),
            .code(language: "swift", text: "let a = 1\n\n- no es lista"),
            .paragraph("Listo.")
        ])
    }

    func testAnUnclosedFenceWhileStreamingStillShowsTheCode() {
        XCTAssertEqual(ChatMarkdownParser.parse("```\nlet a"), [.code(language: "", text: "let a")])
    }

    func testTablesGroupTheirRows() {
        XCTAssertEqual(ChatMarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |"), [.table(["| a | b |", "|---|---|", "| 1 | 2 |"])])
    }

    func testWindowsLineEndingsAndEmptyInput() {
        XCTAssertEqual(ChatMarkdownParser.parse("a\r\n\r\nb"), [.paragraph("a"), .paragraph("b")])
        XCTAssertEqual(ChatMarkdownParser.parse(""), [])
        XCTAssertEqual(ChatMarkdownParser.parse("\n\n  \n"), [])
    }

    func testTheStreamingCursorStaysInTheLastBlock() {
        XCTAssertEqual(ChatMarkdownParser.parse("- uno\n- dos▍").last, .bullet(indent: 0, text: "dos▍"))
    }
}
