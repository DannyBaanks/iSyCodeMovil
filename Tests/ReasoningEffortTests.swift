import Foundation
import XCTest
@testable import IysCodeMovilCore

final class ReasoningEffortTests: XCTestCase {
    func testApiValues() {
        XCTAssertNil(ReasoningEffort.auto.apiValue)
        XCTAssertEqual(ReasoningEffort.low.apiValue, "low")
        XCTAssertEqual(ReasoningEffort.medium.apiValue, "medium")
        XCTAssertEqual(ReasoningEffort.high.apiValue, "high")
    }

    func testDisplayNames() {
        XCTAssertEqual(ReasoningEffort.auto.displayName, "Auto")
        XCTAssertEqual(ReasoningEffort.low.displayName, "Bajo")
        XCTAssertEqual(ReasoningEffort.medium.displayName, "Medio")
        XCTAssertEqual(ReasoningEffort.high.displayName, "Alto")
    }

    func testSettingRoundTripsAndDefaultsToAuto() {
        let previous = UserDefaults.standard.string(forKey: ReasoningEffortSetting.defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: ReasoningEffortSetting.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ReasoningEffortSetting.defaultsKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: ReasoningEffortSetting.defaultsKey)
        XCTAssertEqual(ReasoningEffortSetting.current, .auto)
        ReasoningEffortSetting.current = .high
        XCTAssertEqual(ReasoningEffortSetting.current, .high)
        XCTAssertNil(GenerationOptions().reasoningEffort)
    }

    func testShouldSendReasoningEffortMatrix() {
        // NVIDIA NIM y OpenRouter: el campo viaja (superficie compatible con OpenAI).
        XCTAssertTrue(RemoteModelProvider.shouldSendReasoningEffort(host: "integrate.api.nvidia.com", model: "nvidia/nemotron-3-ultra-550b"))
        XCTAssertTrue(RemoteModelProvider.shouldSendReasoningEffort(host: "openrouter.ai", model: "deepseek/deepseek-r1"))
        // OpenAI: solo para modelos de razonamiento conocidos; a gpt-4o le rechazaría el parámetro.
        XCTAssertTrue(RemoteModelProvider.shouldSendReasoningEffort(host: "api.openai.com", model: "gpt-5"))
        XCTAssertTrue(RemoteModelProvider.shouldSendReasoningEffort(host: "api.openai.com", model: "o3-mini"))
        XCTAssertFalse(RemoteModelProvider.shouldSendReasoningEffort(host: "api.openai.com", model: "gpt-4o"))
        XCTAssertFalse(RemoteModelProvider.shouldSendReasoningEffort(host: "api.openai.com", model: "gpt-5-chat-latest"))
        // Otros proveedores nunca lo reciben.
        XCTAssertFalse(RemoteModelProvider.shouldSendReasoningEffort(host: "api.x.ai", model: "grok-4"))
        XCTAssertFalse(RemoteModelProvider.shouldSendReasoningEffort(host: "generativelanguage.googleapis.com", model: "gemini-2.0-flash"))
        XCTAssertFalse(RemoteModelProvider.shouldSendReasoningEffort(host: nil, model: "gpt-5"))
    }

    func testGenerationOptionsKeepsReasoningEffort() {
        let options = GenerationOptions(model: "gpt-5", reasoningEffort: .high)
        XCTAssertEqual(options.reasoningEffort, .high)
        XCTAssertEqual(options.model, "gpt-5")
    }
}
