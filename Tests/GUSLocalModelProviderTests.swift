import XCTest
@testable import IysCodeMovilCore

private actor FixtureLocalInferenceEngine: LocalInferenceEngine {
    private let response: String
    private let stoppedAtEndOfTurn: Bool
    private(set) var loadedURL: URL?
    private(set) var lastMessages: [ModelMessage] = []
    private(set) var didUnload = false

    init(response: String = "respuesta local", stoppedAtEndOfTurn: Bool = true) {
        self.response = response
        self.stoppedAtEndOfTurn = stoppedAtEndOfTurn
    }
    func load(modelURL: URL, contextTokens: Int) async throws { loadedURL = modelURL; didUnload = false }
    func unload() async { didUnload = true; loadedURL = nil }
    func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String {
        lastMessages = messages
        return response
    }
    func generateMeasured(messages: [ModelMessage], options: GenerationOptions) async throws -> LocalGeneration {
        lastMessages = messages
        return LocalGeneration(text: response, stats: LocalGenerationStats(
            promptTokens: 50,
            generatedTokens: stoppedAtEndOfTurn ? 12 : 512,
            prefillMilliseconds: 10,
            generateMilliseconds: 20,
            templateSource: .embedded,
            stoppedAtEndOfTurn: stoppedAtEndOfTurn
        ))
    }
    func cancel() async {}
}

final class GUSLocalModelProviderTests: XCTestCase {
    func testProviderDeclaresLocalOnlyWithStrictToolCalls() async throws {
        let engine = FixtureLocalInferenceEngine()
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        XCTAssertTrue(provider.capabilities.localOnly)
        XCTAssertTrue(provider.capabilities.toolCalls)
        XCTAssertEqual(provider.id, "gus-local")
        XCTAssertEqual(provider.capabilities.maxTokens, 512)
        XCTAssertTrue(provider.capabilities.restrictions.contains { $0.localizedCaseInsensitiveContains("herramient") })

        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "hola")],
            tools: nil,
            options: GenerationOptions(maxTokens: 16)
        )
        XCTAssertEqual(response.content, "respuesta local")
        XCTAssertNil(response.toolCalls)
    }

    func testGenerationLimitIsReportedAsIncompleteInsteadOfSuccessfulStop() async throws {
        let engine = FixtureLocalInferenceEngine(response: "Los olmecas vivieron en el Golfo. Su legado incluye", stoppedAtEndOfTurn: false)
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "Háblame de los olmecas")],
            tools: nil,
            options: GenerationOptions(maxTokens: 512)
        )

        XCTAssertEqual(response.finishReason, "length")
        XCTAssertTrue(response.content.contains("Respuesta incompleta"))
        XCTAssertEqual(response.metadata["stopped_at_end_of_turn"], "false")
        XCTAssertEqual(response.metadata["generated_tokens"], "512")
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

    func testValidTaggedToolCallIsConvertedToExecutableCall() async throws {
        let engine = FixtureLocalInferenceEngine(response: #"<GUS_TOOL_CALL>{"name":"edit_file","arguments":{"path":"x.swift","old_text":"old","new_text":"new","replace_all":false}}</GUS_TOOL_CALL>"#)
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "cambia old por new")],
            tools: [ToolDefinition(
                name: "edit_file",
                description: "fixture",
                parameters: ToolDefinition.ToolParameters(properties: [
                    "path": .init(type: "string", description: nil, enumValues: nil),
                    "old_text": .init(type: "string", description: nil, enumValues: nil),
                    "new_text": .init(type: "string", description: nil, enumValues: nil),
                    "replace_all": .init(type: "boolean", description: nil, enumValues: nil)
                ], required: ["path", "old_text", "new_text"])
            )],
            options: GenerationOptions(maxTokens: 64)
        )
        let call = try XCTUnwrap(response.toolCalls?.first)
        XCTAssertEqual(call.name, "edit_file")
        XCTAssertEqual(call.arguments["path"], "x.swift")
        XCTAssertEqual(call.arguments["replace_all"], "false")
        XCTAssertEqual(response.content, "")
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

    func testUnknownTaggedToolStaysPlainText() async throws {
        let raw = #"<GUS_TOOL_CALL>{"name":"shell","arguments":{"command":"rm -rf /"}}</GUS_TOOL_CALL>"#
        let engine = FixtureLocalInferenceEngine(response: raw)
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "hazlo")],
            tools: [ToolDefinition(name: "read_file", description: "fixture", parameters: .init(properties: [:], required: []))],
            options: GenerationOptions(maxTokens: 32)
        )
        XCTAssertNil(response.toolCalls)
        XCTAssertEqual(response.content, raw)
    }
}
