import Foundation
import XCTest
@testable import IysCodeMovilCore

final class GUSMailboxWatcherTests: XCTestCase {
    func testSubjectRoundTrips() {
        let subject = GUSMailboxWatcher.subject(id: "gus-20261117-183000-a1b2", state: .enCurso, recipient: .gus)
        XCTAssertEqual(subject, "[GUS] gus-20261117-183000-a1b2 en-curso GUS")
        let parsed = GUSMailboxWatcher.parseSubject(subject)
        XCTAssertEqual(parsed?.id, "gus-20261117-183000-a1b2")
        XCTAssertEqual(parsed?.state, .enCurso)
        XCTAssertEqual(parsed?.recipient, .gus)
    }

    func testParseSubjectAcceptsBothStateSpellings() {
        XCTAssertEqual(GUSMailboxWatcher.parseSubject("[GUS] gus-1 pendiente Muse")?.state, .pendiente)
        XCTAssertEqual(GUSMailboxWatcher.parseSubject("[GUS] gus-1 en curso GUS")?.state, .enCurso)
        XCTAssertEqual(GUSMailboxWatcher.parseSubject("[GUS] gus-1 en-curso GUS")?.state, .enCurso)
        XCTAssertEqual(GUSMailboxWatcher.parseSubject("[GUS] gus-1 hecho Muse")?.state, .hecho)
        XCTAssertEqual(GUSMailboxWatcher.parseSubject("[GUS] gus-1 hecho GPT")?.recipient, .gpt)
    }

    func testParseSubjectRejectsAnythingOutsideTheProtocol() {
        XCTAssertNil(GUSMailboxWatcher.parseSubject("Hola"))
        XCTAssertNil(GUSMailboxWatcher.parseSubject("[GUS] solo-id"))
        XCTAssertNil(GUSMailboxWatcher.parseSubject("[GUS] gus-1 pendiente"))
        XCTAssertNil(GUSMailboxWatcher.parseSubject("[GUS] gus-1 volando GUS"))
        XCTAssertNil(GUSMailboxWatcher.parseSubject("[GUS] gus-1 pendiente NADIE"))
        XCTAssertNil(GUSMailboxWatcher.parseSubject("GUS gus-1 pendiente GUS"))
        XCTAssertNil(GUSMailboxWatcher.parseSubject("[GUS]  pendiente GUS"))
    }

    func testReconcileLatestStateWinsPerTask() {
        // Gmail lista lo más reciente primero: el primer mensaje de cada id manda.
        let summaries = [
            MailSummary(id: "m3", from: "yo", subject: "[GUS] gus-1 hecho GUS", date: "d3", snippet: ""),
            MailSummary(id: "m2", from: "yo", subject: "[GUS] gus-1 en-curso GUS", date: "d2", snippet: ""),
            MailSummary(id: "m1", from: "yo", subject: "[GUS] gus-1 pendiente GUS", date: "d1", snippet: ""),
            MailSummary(id: "m4", from: "yo", subject: "[GUS] gus-2 pendiente Muse", date: "d4", snippet: ""),
            MailSummary(id: "m5", from: "otro", subject: "GUS sin corchetes", date: "d5", snippet: ""),
            MailSummary(id: "m6", from: "yo", subject: "[GUS] gus-3 volando GUS", date: "d6", snippet: ""),
        ]
        let tasks = GUSMailboxWatcher.reconcile(summaries)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first { $0.id == "gus-1" }?.state, .hecho)
        XCTAssertEqual(tasks.first { $0.id == "gus-1" }?.messageID, "m3")
        XCTAssertEqual(tasks.first { $0.id == "gus-2" }?.recipient, .muse)
        XCTAssertNil(tasks.first { $0.id == "gus-3" })
    }

    func testNewTaskIDFormat() {
        let id = GUSMailboxWatcher.newTaskID(now: Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertTrue(id.hasPrefix("gus-"), id)
        XCTAssertEqual(id.split(separator: "-").count, 4)
    }

    func testMessageBodyPrefersPlainTextOverHTML() {
        let json = """
        {"id":"m1","snippet":"resumen","payload":{"mimeType":"multipart/alternative","parts":[
        {"mimeType":"text/html","body":{"data":"PGI+aG9sYTwvYj4"}},
        {"mimeType":"text/plain","body":{"data":"SG9sYSBHVVM"}}]}}
        """
        XCTAssertEqual(GoogleParsers.messageBody(Data(json.utf8)), "Hola GUS")
    }

    func testMessageBodyFallsBackToSnippetWithoutPlainPart() {
        let json = """
        {"id":"m1","snippet":"solo resumen","payload":{"mimeType":"text/html","body":{"data":"PGI+aG9sYTwvYj4"}}}
        """
        XCTAssertEqual(GoogleParsers.messageBody(Data(json.utf8)), "solo resumen")
    }

    func testDecodeBase64URLHandlesMissingPadding() {
        XCTAssertEqual(GoogleParsers.decodeBase64URL("SG9sYSBHVVM"), "Hola GUS")
        XCTAssertEqual(GoogleParsers.decodeBase64URL("SG9sYSBHVVM="), "Hola GUS")
        XCTAssertNil(GoogleParsers.decodeBase64URL("!!!no-base64!!!"))
    }
}
