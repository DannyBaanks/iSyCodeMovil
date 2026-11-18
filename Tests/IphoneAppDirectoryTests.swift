import XCTest
@testable import IysCodeMovilCore

/// The iPhone's apps by name → Bundle ID, learned from iphone_list_apps so agents stop
/// guessing IDs.
final class IphoneAppDirectoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "app-directory-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Same shape as iphone-control's listing (name, TAB, Bundle ID), including the
    /// invisible left-to-right mark it puts before "WhatsApp".
    private let listing = """
    ChatGPT\tcom.openai.chat
    Meta AI\tcom.facebook.stellaapp
    Muse\tcom.facebook.hatch
    Qwen Studio\tai.qwenlm.chat.ios
    YouTube\tcom.google.ios.youtube
    YouTube Music\tcom.google.ios.youtubemusic
    \u{200E}WhatsApp\tnet.whatsapp.WhatsApp
    una línea sin bundle
    """

    func testLearnsEveryAppFromAListing() {
        XCTAssertEqual(IphoneAppDirectory.learn(fromListing: listing, defaults: defaults), 7)
        let apps = IphoneAppDirectory.load(defaults: defaults)
        XCTAssertEqual(apps.count, 7)
        XCTAssertTrue(apps.contains(.init(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp")), "invisible mark stripped")
    }

    func testResolvesNamesTheWayPeopleSayThem() {
        IphoneAppDirectory.learn(fromListing: listing, defaults: defaults)
        XCTAssertEqual(IphoneAppDirectory.resolve("muse", defaults: defaults), "com.facebook.hatch")
        XCTAssertEqual(IphoneAppDirectory.resolve("  META ai ", defaults: defaults), "com.facebook.stellaapp")
        XCTAssertEqual(IphoneAppDirectory.resolve("whatsapp", defaults: defaults), "net.whatsapp.WhatsApp")
        XCTAssertEqual(IphoneAppDirectory.resolve("qwen", defaults: defaults), "ai.qwenlm.chat.ios", "unique prefix")
        // "YouTube" is an exact name, so it wins over "YouTube Music".
        XCTAssertEqual(IphoneAppDirectory.resolve("youtube", defaults: defaults), "com.google.ios.youtube")
        XCTAssertNil(IphoneAppDirectory.resolve("tube", defaults: defaults), "ambiguous: two apps contain it")
        XCTAssertNil(IphoneAppDirectory.resolve("muse de meta x", defaults: defaults))
    }

    func testRememberAddsOrRenamesAndRejectsNonBundleIDs() {
        XCTAssertTrue(IphoneAppDirectory.remember(name: "Muse", bundleID: "com.facebook.hatch", defaults: defaults))
        XCTAssertTrue(IphoneAppDirectory.remember(name: "Muse de Meta", bundleID: "com.facebook.hatch", defaults: defaults))
        let apps = IphoneAppDirectory.load(defaults: defaults)
        XCTAssertEqual(apps, [.init(name: "Muse de Meta", bundleID: "com.facebook.hatch")])
        XCTAssertFalse(IphoneAppDirectory.remember(name: "Muse", bundleID: "muse", defaults: defaults))
        XCTAssertFalse(IphoneAppDirectory.remember(name: "", bundleID: "com.a.b", defaults: defaults))
    }

    func testDescribeListsExactIDsAndExplainsAnEmptyDirectory() {
        XCTAssertTrue(IphoneAppDirectory.describe(defaults: defaults).contains("iphone_app_remember"))
        IphoneAppDirectory.learn(fromListing: listing, defaults: defaults)
        let all = IphoneAppDirectory.describe(defaults: defaults)
        XCTAssertTrue(all.contains("Muse → com.facebook.hatch"))
        let filtered = IphoneAppDirectory.describe(filter: "facebook", defaults: defaults)
        XCTAssertTrue(filtered.contains("Meta AI → com.facebook.stellaapp"))
        XCTAssertFalse(filtered.contains("ChatGPT"))
    }

    func testBundleIDShape() {
        XCTAssertTrue(IphoneAppDirectory.isBundleID("com.facebook.hatch"))
        XCTAssertTrue(IphoneAppDirectory.isBundleID("ai.x.GrokApp"))
        XCTAssertFalse(IphoneAppDirectory.isBundleID("muse"))
        XCTAssertFalse(IphoneAppDirectory.isBundleID("com..hatch"))
        XCTAssertFalse(IphoneAppDirectory.isBundleID("com.facebook hatch"))
    }

    func testCatalogOffersTheDirectoryWithoutApproval() throws {
        let tools = IphoneControlCatalog.tools(allowed: ["iphone_app_directory", "iphone_app_remember"])
        XCTAssertEqual(Set(tools.map(\.name)), ["iphone_app_directory", "iphone_app_remember"])
        XCTAssertTrue(tools.allSatisfy { !$0.capabilities.isDestructive })
        XCTAssertTrue(LocalIphoneController.supportedToolNames.isSuperset(of: ["iphone_app_directory", "iphone_app_remember"]))
    }
}
