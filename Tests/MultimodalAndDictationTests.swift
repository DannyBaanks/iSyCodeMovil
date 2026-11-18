import Foundation
import XCTest
@testable import IysCodeMovilCore

final class MultimodalAndDictationTests: XCTestCase {
    func testFileImporterCopiesToStagingExtractsTextAndCleansUpSafely() async throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("stg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let csvURL = sourceDir.appendingPathComponent("ventas.csv")
        try "producto,precio\nCafe,95.5\nPan,32.0\n".write(to: csvURL, atomically: true, encoding: .utf8)

        let manager = ChatAttachmentManager(directoryURL: stagingDir)
        let attachment = await manager.importFromFileURL(csvURL)

        XCTAssertEqual(attachment.type, .file)
        XCTAssertEqual(attachment.source, .filesImporter)
        XCTAssertTrue(attachment.state.isReady)
        XCTAssertEqual(attachment.mimeType, "text/csv")
        XCTAssertTrue((attachment.extractedText ?? "").contains("Cafe,95.5"))
        XCTAssertNotNil(attachment.path)
        XCTAssertTrue(attachment.path!.hasPrefix(stagingDir.path))

        // Deleting original must leave staged copy intact (no fragile external URL reference)
        try FileManager.default.removeItem(at: csvURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path!))

        await manager.removeStagedFile(for: attachment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.path!))
    }

    func testMultimodalProviderCompatibilityHonesty() async throws {
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-stg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let imgURL = stagingDir.appendingPathComponent("ticket.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: imgURL)

        let imgAttachment = Attachment(
            type: .image,
            source: .camera,
            state: .ready,
            name: "ticket.jpg",
            path: imgURL.path,
            icon: "camera.fill",
            mimeType: "image/jpeg",
            byteCount: 6
        )

        let manager = ChatAttachmentManager(directoryURL: stagingDir)

        // OpenAI supports image_url
        let openAIPrep = await manager.prepareForSend(attachments: [imgAttachment], providerID: "openai", modelID: "gpt-4o", backendMode: .native)
        XCTAssertNil(openAIPrep.blockedReason)
        XCTAssertEqual(openAIPrep.parts.first?.kind, .imageBase64)

        // GUS local cannot carry an image: no image part, no block; the model gets a note and
        // tells the person it can't see the photo (honest, without refusing the whole message).
        let localPrep = await manager.prepareForSend(attachments: [imgAttachment], providerID: "gus-local", modelID: "qwen1.5-1.8b", backendMode: .native)
        XCTAssertNil(localPrep.blockedReason)
        XCTAssertTrue(localPrep.parts.isEmpty)
        XCTAssertTrue(localPrep.fallbackPromptNotes.contains { $0.contains("ticket.jpg") && $0.contains("no recibe imágenes") })

        // NVIDIA: the name-based guess stays as a UI hint, but the image is sent for every model
        // (Nemotron VL used to be refused because the provider flag was computed without a model).
        let nimTextOnly = MultimodalProviderCompatibility.evaluate(providerID: "nvidia", modelID: "nvidia/nemotron-3-ultra-550b-a55b", backendMode: .native)
        XCTAssertFalse(nimTextOnly.supportsImages)
        XCTAssertTrue(nimTextOnly.canCarryImages)
        let nimVL = MultimodalProviderCompatibility.evaluate(providerID: "nvidia", modelID: "nvidia/nemotron-3.5-super-vl-120b-a12b", backendMode: .native)
        XCTAssertTrue(nimVL.supportsImages)
        for model in ["nvidia/nemotron-3.5-super-vl-120b-a12b", "nvidia/nemotron-3-ultra-550b-a55b"] {
            let prep = await manager.prepareForSend(attachments: [imgAttachment], providerID: "nvidia", modelID: model, backendMode: .native)
            XCTAssertNil(prep.blockedReason, model)
            XCTAssertEqual(prep.parts.first?.kind, .imageBase64, model)
        }
    }

    func testRefusedImagesAreReplacedByANoteForTheModel() {
        let messages = [
            ModelMessage(role: .system, content: "sys"),
            ModelMessage(role: .user, content: "¿Qué ves?", multimodalParts: [
                .image(base64: "AAAA", mimeType: "image/jpeg", filename: "foto.jpg"),
                .document(filename: "notas.md", mimeType: "text/markdown", text: "hola")
            ])
        ]
        let replaced = RemoteModelProvider.replacingImagesWithNotes(messages)
        XCTAssertNotNil(replaced)
        let user = replaced?[1]
        XCTAssertFalse(user?.multimodalParts?.contains { $0.kind == .imageBase64 } ?? false)
        XCTAssertEqual(user?.multimodalParts?.first?.kind, .documentText, "other attachments survive")
        XCTAssertTrue(user?.content.contains("¿Qué ves?") ?? false)
        XCTAssertTrue(user?.content.contains("'foto.jpg'") ?? false)
        XCTAssertTrue(user?.content.contains("no puede ver imágenes") ?? false)
        XCTAssertNil(RemoteModelProvider.replacingImagesWithNotes([ModelMessage(role: .user, content: "solo texto")]))
        XCTAssertTrue(RemoteModelProvider.mayBeImageRefusal(.invalidRequest("HTTP 400: image_url is not supported")))
        XCTAssertFalse(RemoteModelProvider.mayBeImageRefusal(.authenticationFailed))
    }

    func testSpeechTextMergerPreservesExistingDraftCleanly() {
        XCTAssertEqual(SpeechTextMerger.merge(existing: "", transcript: "  hola mundo "), "hola mundo")
        XCTAssertEqual(SpeechTextMerger.merge(existing: "Revisa", transcript: "el catálogo"), "Revisa el catálogo")
        XCTAssertEqual(SpeechTextMerger.merge(existing: "Revisa\n", transcript: "el catálogo"), "Revisa\nel catálogo")
        XCTAssertEqual(SpeechTextMerger.merge(existing: "Mantén esto", transcript: "   "), "Mantén esto")
    }
}
