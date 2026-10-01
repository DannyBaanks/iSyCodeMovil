import XCTest
@testable import IysCodeMovilCore

final class GUSModelSelectionTests: XCTestCase {
    func testGUSIsSelectableWithoutEnteringAnAPIKey() {
        let local = SandboxModelProvider.provider(id: "gus-local")
        XCTAssertEqual(local?.id, "gus-local")
        XCTAssertTrue(local?.keyPlaceholder.isEmpty == true)
        XCTAssertEqual(local?.baseURL, "")
        XCTAssertFalse(SandboxModelProvider.all.contains { $0.id == "gus-local" })
        XCTAssertTrue(SandboxModelProvider.sandboxOptions.contains { $0.id == "gus-local" })
    }

    func testLocalProviderNeverLooksLikeARemoteModel() {
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/model.gguf"))
        XCTAssertTrue(provider.capabilities.localOnly)
        XCTAssertTrue(provider.capabilities.toolCalls)
        XCTAssertFalse(provider.capabilities.streaming)
    }
    func testGUSModelsAreExplicitlyPinnedAndDoNotAddRemoteOptions() {
        // The catalog grows through Catalog/models.json; every entry stays a pinned HF artifact.
        XCTAssertGreaterThanOrEqual(GUSModelManifest.all.count, 3)
        XCTAssertTrue(GUSModelManifest.all.allSatisfy { $0.sourceURL.scheme == "https" && $0.sourceURL.host == "huggingface.co" })
        XCTAssertFalse(SandboxModelProvider.all.contains { $0.id.hasPrefix("qwen") || $0.id.hasPrefix("smollm") })
    }

}
