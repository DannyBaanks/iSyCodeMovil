import XCTest
import UIKit

final class ChatDrawerTests: XCTestCase {
    @MainActor
    func testDrawerPreservesUnsentDraft() throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The compact drawer is an iPhone layout.")
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--readme-screenshot=assistant"]
        app.launch()

        let composer = app.descendants(matching: .any)["chat-landing-input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 12))
        composer.tap()
        let draft = "Borrador local"
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        attachScreen(app, named: "01-borrador")

        let open = app.buttons["chat-open-sidebar"]
        XCTAssertTrue(open.isHittable)
        open.tap()
        let newConversation = app.buttons["sidebar-new-conversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        XCTAssertTrue(newConversation.isHittable)
        attachScreen(app, named: "02-menu-abierto")

        let close = app.buttons["Cerrar barra lateral"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isHittable)
        XCTAssertFalse(newConversation.isHittable)
        XCTAssertEqual(composer.value as? String, draft)
        attachScreen(app, named: "03-borrador-recuperado")
        #else
        throw XCTSkip("This test runs only on an iPhone simulator.")
        #endif
    }

    @MainActor
    private func attachScreen(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
