import Foundation
import XCTest
@testable import IysCodeMovilCore

final class ActionRecorderAndVaultTests: XCTestCase {
    // MARK: - Scenario 1: WDA Polling Frame Diff & L1 Compilation

    @MainActor
    func testDiffEngineDetectsWhatsAppFlowAndParameterizesInputs() async {
        let f1: [LocalElement] = [
            LocalElement(kind: "SearchField", label: "Buscar", name: "Search", value: "", centerX: 180, centerY: 120, width: 320, height: 40),
            LocalElement(kind: "Cell", label: "Maria Lopez", name: "Maria Lopez", value: "", centerX: 180, centerY: 220, width: 340, height: 64)
        ]
        let f2: [LocalElement] = [
            LocalElement(kind: "SearchField", label: "Buscar", name: "Search", value: "Maria", centerX: 180, centerY: 120, width: 320, height: 40),
            LocalElement(kind: "Cell", label: "Maria Lopez", name: "Maria Lopez", value: "", centerX: 180, centerY: 220, width: 340, height: 64)
        ]
        let f3: [LocalElement] = [
            LocalElement(kind: "TextField", label: "Mensaje", name: "ChatBar", value: "Hola desde iSyCode", centerX: 170, centerY: 760, width: 240, height: 40),
            LocalElement(kind: "Button", label: "Enviar", name: "Send", value: "", centerX: 350, centerY: 760, width: 40, height: 40)
        ]

        let stepLaunchAndSearch = ActionRecorderDiffEngine.diffFrames(
            previousBundleID: "com.isyco.iyscodemovil",
            previousElements: [],
            currentBundleID: "net.whatsapp.WhatsApp",
            currentElements: f2,
            selfBundleID: "com.isyco.iyscodemovil",
            expectedParameters: ["contacto", "mensaje"],
            linkedSecretAliases: []
        )
        XCTAssertTrue(stepLaunchAndSearch.contains { $0.kind == .launchApp && $0.suggestedArgs["bundle_id"] == "net.whatsapp.WhatsApp" })
        XCTAssertTrue(stepLaunchAndSearch.contains { $0.kind == .typeText && $0.suggestedArgs["text"] == "{{contacto}}" })

        let stepMessage = ActionRecorderDiffEngine.diffFrames(
            previousBundleID: "net.whatsapp.WhatsApp",
            previousElements: f1,
            currentBundleID: "net.whatsapp.WhatsApp",
            currentElements: f3,
            selfBundleID: "com.isyco.iyscodemovil",
            expectedParameters: ["contacto", "mensaje"],
            linkedSecretAliases: []
        )
        XCTAssertTrue(stepMessage.contains { $0.kind == .typeText && $0.suggestedArgs["text"] == "{{mensaje}}" })

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-test-\(UUID().uuidString)")
        let service = ActionRecorderService(directoryURL: dir)
        let session = RecordedWorkflowSession(
            goalTitle: "Enviar WhatsApp",
            goalDescription: "Abre WhatsApp y envía un mensaje al contacto",
            targetToolName: "l1_enviar_whatsapp",
            expectedParameters: ["contacto", "mensaje"],
            steps: stepLaunchAndSearch + stepMessage
        )
        let l1 = service.compileToL1Tool(from: session, customName: "l1_enviar_whatsapp", description: "Envía WhatsApp")
        XCTAssertEqual(l1.name, "l1_enviar_whatsapp")
        XCTAssertEqual(l1.provenance, L1ToolDefinition.provenanceLearned)
        XCTAssertTrue(l1.parameters.map(\.name).contains("contacto"))
        XCTAssertTrue(l1.parameters.map(\.name).contains("mensaje"))
    }

    @MainActor
    func testSecureFieldBindsSecretAliasWithoutCapturingPlaintextValue() {
        let before: [LocalElement] = [
            LocalElement(kind: "TextField", label: "Usuario FEL", name: "user", value: "", centerX: 180, centerY: 200, width: 280, height: 44),
            LocalElement(kind: "SecureTextField", label: "Contraseña", name: "pass", value: "", centerX: 180, centerY: 260, width: 280, height: 44)
        ]
        let after: [LocalElement] = [
            LocalElement(kind: "TextField", label: "Usuario FEL", name: "user", value: "danny_sat", centerX: 180, centerY: 200, width: 280, height: 44),
            LocalElement(kind: "SecureTextField", label: "Contraseña", name: "pass", value: "••••••••", centerX: 180, centerY: 260, width: 280, height: 44)
        ]

        let steps = ActionRecorderDiffEngine.diffFrames(
            previousBundleID: "com.apple.mobilesafari",
            previousElements: before,
            currentBundleID: "com.apple.mobilesafari",
            currentElements: after,
            selfBundleID: "com.isyco.iyscodemovil",
            expectedParameters: ["nit"],
            linkedSecretAliases: ["fel_mx"]
        )

        XCTAssertTrue(steps.contains { $0.suggestedArgs["text"] == "{{secret:fel_mx.username}}" })
        XCTAssertTrue(steps.contains { $0.kind == .secureField && $0.suggestedArgs["text"] == "{{secret:fel_mx.password}}" })
        XCTAssertFalse(steps.contains { ($0.suggestedArgs["text"] ?? "").contains("••••") })
    }

    // MARK: - Scenario 2: Secret Vault Resolution, Biometry, Redaction & Flow Guardrails

    func testSecretResolverEnforcesBiometryAndRedactsOutputsAndErrors() async throws {
        let resolver = SecretVaultRuntimeResolver(
            reader: { alias, field in
                if alias == "fel_mx" && field == .password { return "SuperSecret#991" }
                if alias == "fel_mx" && field == .username { return "usuario_fel" }
                return nil
            },
            metadataLookup: { alias in
                SecretVaultEntryMetadata(alias: alias, label: "Portal FEL.mx", serviceDomain: "fel.mx", hasUsername: true, hasPassword: true, requireFaceID: true)
            },
            authenticator: { _ in true }
        )

        let res = try await resolver.resolvePlaceholders(in: ["text": "{{secret:fel_mx.password}}"])
        XCTAssertEqual(res.arguments["text"], "SuperSecret#991")
        XCTAssertEqual(res.usedAliases, ["fel_mx"])

        let redacted = SecretVaultStore.redact("Falló al escribir SuperSecret#991 en pantalla", secrets: res.resolvedSecrets)
        XCTAssertFalse(redacted.contains("SuperSecret#991"))
        XCTAssertTrue(redacted.contains("••••••••"))

        let deniedResolver = SecretVaultRuntimeResolver(
            reader: { _, _ in "SuperSecret#991" },
            metadataLookup: { alias in
                SecretVaultEntryMetadata(alias: alias, label: "Portal FEL.mx", hasPassword: true, requireFaceID: true)
            },
            authenticator: { _ in false }
        )
        do {
            _ = try await deniedResolver.resolvePlaceholders(in: ["text": "{{secret:fel_mx.password}}"])
            XCTFail("Expected biometric failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("biométrica") || error.localizedDescription.contains("rechazada"))
        }
    }

    func testL1WithSecretRequiresEveryTimeApprovalAndExportNeverLeaksSecrets() throws {
        let l1 = L1ToolDefinition(
            name: "l1_login_fel",
            description: "Inicia sesión en FEL",
            steps: [
                .init(tool: "iphone_launch_app", args: ["bundle_id": "com.apple.mobilesafari"]),
                .init(tool: "iphone_type_text", args: ["text": "{{secret:fel_mx.password}}", "submit": "true"])
            ]
        )
        let caps = DynamicToolRegistry.effectiveCapabilities(for: l1)
        XCTAssertTrue(caps.isDestructive)
        XCTAssertTrue(caps.requiresApprovalEveryTime)
        XCTAssertEqual(l1.requiredSecrets, ["fel_mx"])

        let contract = AgentContract(
            name: "Facturador FEL",
            category: "custom",
            goal: "Facturar en fel.mx",
            summary: "Factura segura",
            systemInstructions: "Usa Llavero.",
            enabledL0Tools: ["iphone_launch_app", "iphone_type_text", "secret_vault_list"],
            l1Tools: [l1],
            localApprovalGrantedAt: Date()
        )
        let exported = try contract.exportSanitizedJSON()
        XCTAssertTrue(exported.contains("\"fel_mx\""))
        XCTAssertFalse(exported.contains("localApprovalGrantedAt"))
        XCTAssertFalse(exported.contains("SuperSecret"))
    }

    func testNativeExecutorRefusesAllowSequenceWhenToolUsesSecretReference() async throws {
        let ws = try IOSWorkspace(rootName: "secret-exec-test-\(UUID().uuidString)")
        let wsRoot = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: wsRoot) }

        let l1 = L1ToolDefinition(
            name: "l1_type_secret",
            description: "Escribe secreto",
            steps: [.init(tool: "iphone_type_text", args: ["text": "{{secret:fel_mx.password}}", "submit": "true"])]
        )
        let reg = DynamicToolRegistry(storageURL: wsRoot.appendingPathComponent("l1.json"))
        try await reg.upsert(l1)

        let resolver = SecretVaultRuntimeResolver(
            reader: { _, _ in "SecretoSecreto" },
            metadataLookup: { alias in SecretVaultEntryMetadata(alias: alias, label: "FEL", hasPassword: true, requireFaceID: false) },
            authenticator: { _ in true }
        )
        let exec = NativeCapabilityToolExecutor(workspace: ws, l1Registry: reg, secretResolver: resolver)
        _ = await exec.tools(relevantTo: [ModelMessage(role: .user, content: "hola")])

        let seqResult = await exec.execute(
            ToolInvocation(id: "t1", name: "l1_type_secret", arguments: [:]),
            approval: .allowSequence
        )
        XCTAssertNotNil(seqResult.error)
        XCTAssertFalse(seqResult.output.contains("SecretoSecreto"))
        XCTAssertFalse((seqResult.error ?? "").contains("SecretoSecreto"))
    }
}
