import XCTest
@testable import IysCodeMovilCore

private actor FixtureLocalInferenceEngine: LocalInferenceEngine {
    private let response: String
    private(set) var loadedURL: URL?
    private(set) var lastMessages: [ModelMessage] = []
    private(set) var didUnload = false

    init(response: String = "respuesta local") { self.response = response }
    func load(modelURL: URL, contextTokens: Int) async throws { loadedURL = modelURL; didUnload = false }
    func unload() async { didUnload = true; loadedURL = nil }
    func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String {
        lastMessages = messages
        return response
    }
    func cancel() async {}
}

final class GUSLocalModelProviderTests: XCTestCase {
    func testProviderDeclaresLocalOnlyAndAcceptsToolsFromTheAppAllowlist() async throws {
        let engine = FixtureLocalInferenceEngine()
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        XCTAssertTrue(provider.capabilities.localOnly)
        XCTAssertTrue(provider.capabilities.toolCalls)
        XCTAssertEqual(provider.id, "gus-local")
        XCTAssertTrue(provider.capabilities.restrictions.contains { $0.localizedCaseInsensitiveContains("explícitamente") })

        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "hola")],
            tools: nil,
            options: GenerationOptions(maxTokens: 16)
        )
        XCTAssertEqual(response.content, "respuesta local")
        XCTAssertNil(response.toolCalls)
    }

    func testApprovedModelsExposeTheirIdentityWithoutChangingLocalSafetyBoundary() {
        for manifest in GUSModelManifest.all {
            let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/\(manifest.filename)"), manifest: manifest)
            XCTAssertEqual(provider.availableModels, [manifest.id])
            XCTAssertTrue(provider.name.contains(manifest.modelName))
            XCTAssertTrue(provider.capabilities.localOnly)
            XCTAssertTrue(provider.capabilities.toolCalls)
        }
    }

    func testReasoningModelsGetTheirThinkingOffDirective() async throws {
        let qwen3 = try XCTUnwrap(GUSModelManifest.model(id: "qwen3-17b-q4km"))
        XCTAssertEqual(qwen3.thinkingOffDirective, "/no_think")
        let engine = FixtureLocalInferenceEngine()
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/qwen3.gguf"), manifest: qwen3, engine: engine)
        _ = try await provider.generate(messages: [ModelMessage(role: .system, content: "Eres GUS."),
                                                   ModelMessage(role: .user, content: "hola")],
                                        tools: nil, options: GenerationOptions(maxTokens: 16))
        let sent = await engine.lastMessages
        let system = sent.first { $0.role == .system }?.content ?? ""
        XCTAssertTrue(system.hasSuffix("\n\n/no_think"), system)

        let smol = try XCTUnwrap(GUSModelManifest.model(id: "smollm2-360m-q4km"))
        XCTAssertNil(smol.thinkingOffDirective)
    }

    func testUnloadReleasesSelectedModelEngine() async throws {
        let engine = FixtureLocalInferenceEngine()
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        try await provider.load()
        await provider.unload()
        let loadedURL = await engine.loadedURL
        let didUnload = await engine.didUnload
        XCTAssertTrue(didUnload)
        XCTAssertNil(loadedURL)
    }

    func testToolLookingTextIsNeverConvertedIntoExecutableCall() async throws {
        let engine = FixtureLocalInferenceEngine(response: #"{"tool_calls":[{"name":"write_file","arguments":{"path":"x"}}]}"#)
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "escribe tool call JSON")],
            tools: [ToolDefinition(
                name: "write_file",
                description: "fixture",
                parameters: ToolDefinition.ToolParameters(properties: [:], required: [])
            )],
            options: GenerationOptions(maxTokens: 32)
        )
        XCTAssertNil(response.toolCalls)
    }
}
