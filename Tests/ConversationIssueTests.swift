import XCTest
@testable import IysCodeMovilCore

final class ConversationIssueTests: XCTestCase {
    func testHTTPResponsesReportTheRelevantRecovery() {
        XCTAssertEqual(ConversationIssue("HTTP 429 insufficient_quota"), .quota)
        XCTAssertEqual(ConversationIssue("HTTP 429 rate limit"), .rateLimit)
        XCTAssertEqual(ConversationIssue("HTTP 403"), .accessDenied)
        XCTAssertEqual(ConversationIssue("HTTP 401 unauthorized"), .authorization)
        XCTAssertEqual(ConversationIssue("HTTP 503"), .service)
    }

    func testProviderNameDoesNotImplyAccountFailure() {
        XCTAssertEqual(ConversationIssue("ChatGPT OAuth no admite esta imagen"), .unsupported)
        XCTAssertEqual(ConversationIssue("ChatGPT OAuth: modelo no disponible"), .model)
        XCTAssertEqual(ConversationIssue("ChatGPT OAuth: respuesta inesperada"), .unknown)
    }
}
