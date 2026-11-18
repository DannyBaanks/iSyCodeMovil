import Foundation
import XCTest
@testable import IysCodeMovilCore

final class SequenceApprovalTests: XCTestCase {
    func testNotificationActionsMapToDecisions() {
        XCTAssertEqual(PermissionNotifier.decision(forAction: PermissionNotifier.approveID), .allowOnce)
        XCTAssertEqual(PermissionNotifier.decision(forAction: PermissionNotifier.alwaysID), .allowAlways)
        XCTAssertEqual(PermissionNotifier.decision(forAction: PermissionNotifier.sequenceID), .allowSequence)
        XCTAssertEqual(PermissionNotifier.decision(forAction: PermissionNotifier.denyID), .deny)
        XCTAssertNil(PermissionNotifier.decision(forAction: "iyscode.permission.nope"))
        XCTAssertNil(PermissionNotifier.decision(forAction: ""))
    }

    func testSequenceCoversOnlyIphoneToolsWhileActive() {
        // La secuencia cubre abrir, tocar, escribir y enviar en el iPhone.
        XCTAssertTrue(AgentLoop.isSequenceCovered(toolName: "iphone_launch_app", sequenceActive: true))
        XCTAssertTrue(AgentLoop.isSequenceCovered(toolName: "iphone_tap", sequenceActive: true))
        XCTAssertTrue(AgentLoop.isSequenceCovered(toolName: "iphone_type_text", sequenceActive: true))
        XCTAssertTrue(AgentLoop.isSequenceCovered(toolName: "iphone_press_button", sequenceActive: true))
        // Nunca cubre otras herramientas destructivas, aunque esté activa.
        XCTAssertFalse(AgentLoop.isSequenceCovered(toolName: "write_file", sequenceActive: true))
        XCTAssertFalse(AgentLoop.isSequenceCovered(toolName: "gmail.write.send", sequenceActive: true))
        XCTAssertFalse(AgentLoop.isSequenceCovered(toolName: "delete_file", sequenceActive: true))
        // Sin aprobación vigente no cubre nada.
        XCTAssertFalse(AgentLoop.isSequenceCovered(toolName: "iphone_tap", sequenceActive: false))
    }

    func testAllowSequenceDecisionRoundTripsAsCodable() throws {
        let response = PermissionResponse(requestId: "req-1", decision: .allowSequence)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(PermissionResponse.self, from: data)
        XCTAssertEqual(decoded.requestId, "req-1")
        XCTAssertEqual(decoded.decision, .allowSequence)
        XCTAssertEqual(decoded.decision.rawValue, "allowSequence")
    }
}
