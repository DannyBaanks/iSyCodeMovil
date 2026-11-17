import XCTest
@testable import IysCodeMovilCore

final class WorkspaceHomeAndRuntimeTests: XCTestCase {
    func testRuntimeEvaluatorRestoresSavedNvidiaProviderReadiness() {
        let ready = RuntimeSelectionEvaluator.evaluate(
            backendMode: .unconfigured,
            connectionHealth: .disconnected,
            connectionStatus: "",
            configuredProviderID: "nvidia",
            configuredModelName: "nvidia/nemotron-3-super-120b-a12b",
            selectedModel: nil,
            hasSavedAPIKey: true,
            hasInstalledLocalModel: false,
            sandboxUsesLiveModel: false,
            isChecking: false,
            lastError: nil,
            lastVerifiedAt: nil
        )
        XCTAssertEqual(ready.providerID, "nvidia")
        XCTAssertEqual(ready.providerName, "NVIDIA NIM")
        XCTAssertEqual(ready.readiness, .ready)
        XCTAssertFalse(ready.isLocal)
        XCTAssertEqual(ready.primaryCTATitle, "Continuar con NVIDIA NIM")

        let needsKey = RuntimeSelectionEvaluator.evaluate(
            backendMode: .unconfigured,
            connectionHealth: .disconnected,
            connectionStatus: "",
            configuredProviderID: "nvidia",
            configuredModelName: nil,
            selectedModel: nil,
            hasSavedAPIKey: false,
            hasInstalledLocalModel: false,
            sandboxUsesLiveModel: false,
            isChecking: false,
            lastError: nil,
            lastVerifiedAt: nil
        )
        XCTAssertEqual(needsKey.readiness, .needsKey)
        XCTAssertEqual(needsKey.readiness.badgeText, "Falta API key")
        XCTAssertEqual(needsKey.primaryCTATitle, "Introducir API key de NVIDIA NIM")
    }

    func testRuntimeEvaluatorSeparatesLocalModelStatesAndErrors() {
        let needsModel = RuntimeSelectionEvaluator.evaluate(
            backendMode: .unconfigured,
            connectionHealth: .disconnected,
            connectionStatus: "",
            configuredProviderID: "gus-local",
            configuredModelName: nil,
            selectedModel: nil,
            hasSavedAPIKey: false,
            hasInstalledLocalModel: false,
            sandboxUsesLiveModel: false,
            isChecking: false,
            lastError: nil,
            lastVerifiedAt: nil
        )
        XCTAssertTrue(needsModel.isLocal)
        XCTAssertEqual(needsModel.readiness, .needsModel)
        XCTAssertEqual(needsModel.primaryCTATitle, "Descargar modelo local")

        let checking = RuntimeSelectionEvaluator.evaluate(
            backendMode: .native,
            connectionHealth: .connecting,
            connectionStatus: "",
            configuredProviderID: "nvidia",
            configuredModelName: nil,
            selectedModel: nil,
            hasSavedAPIKey: true,
            hasInstalledLocalModel: false,
            sandboxUsesLiveModel: false,
            isChecking: true,
            lastError: nil,
            lastVerifiedAt: nil
        )
        XCTAssertEqual(checking.readiness, .checking)
        XCTAssertEqual(checking.readiness.badgeText, "Comprobando")

        let errored = RuntimeSelectionEvaluator.evaluate(
            backendMode: .native,
            connectionHealth: .connected,
            connectionStatus: "sandbox",
            configuredProviderID: "nvidia",
            configuredModelName: "nvidia/nemotron-3-super-120b-a12b",
            selectedModel: ModelInfo(name: "nvidia/nemotron-3-super-120b-a12b", provider: "NVIDIA NIM", isLocal: false, route: "nvidia"),
            hasSavedAPIKey: true,
            hasInstalledLocalModel: false,
            sandboxUsesLiveModel: true,
            isChecking: false,
            lastError: "401 Unauthorized",
            lastVerifiedAt: nil
        )
        XCTAssertEqual(errored.readiness, .error("401 Unauthorized"))
        XCTAssertEqual(errored.primaryCTATitle, "Reintentar conexión")
    }

    func testGoogleStatesAndBlockedToolDeepLinks() {
        let needsClient = ConnectionStatusEvaluator.evaluateGoogle(
            signedIn: false,
            email: nil,
            grantedScopes: [],
            clientId: "",
            sessionExpired: false
        )
        XCTAssertEqual(needsClient, .needsClientID)

        let expired = ConnectionStatusEvaluator.evaluateGoogle(
            signedIn: true,
            email: "ana@empresa.mx",
            grantedScopes: Set(GoogleService.gmail.scopes),
            clientId: "123-abc.apps.googleusercontent.com",
            sessionExpired: true
        )
        XCTAssertEqual(expired, .expired(email: "ana@empresa.mx"))
        XCTAssertEqual(expired.badgeText, "Sesión caducada")

        let partial = ConnectionStatusEvaluator.evaluateGoogle(
            signedIn: true,
            email: "ana@empresa.mx",
            grantedScopes: Set(GoogleService.gmail.scopes),
            clientId: "123-abc.apps.googleusercontent.com",
            sessionExpired: false
        )
        XCTAssertEqual(partial, GoogleConnectionState.connected(email: "ana@empresa.mx", services: [GoogleService.gmail]))

        let calendarTool = AssistantCatalog.tool("googlecalendar.read.events")!
        let blockedCalendar = ConnectionStatusEvaluator.availability(
            for: calendarTool,
            googleState: partial,
            grantedScopes: Set(GoogleService.gmail.scopes)
        )
        XCTAssertFalse(blockedCalendar.isReady)
        XCTAssertEqual(blockedCalendar.ctaTitle, "Autorizar Calendar")
        XCTAssertEqual(blockedCalendar.target, .authorizeService(.calendar))

        let expiredAvailability = ConnectionStatusEvaluator.availability(
            for: calendarTool,
            googleState: expired,
            grantedScopes: Set(GoogleService.gmail.scopes)
        )
        XCTAssertFalse(expiredAvailability.isReady)
        XCTAssertEqual(expiredAvailability.ctaTitle, "Volver a conectar")
        XCTAssertEqual(expiredAvailability.target, .reconnectExpired)
    }

    func testHostEvaluatorIsHonestWhenUnverified() {
        let unverified = ConnectionStatusEvaluator.evaluateHost(
            backendMode: .native,
            connectionHealth: .connected,
            remoteProviderName: nil,
            sandboxLink: nil,
            hostLiveness: .unknown,
            heartbeatState: .notPaired,
            monitorStatus: "Apagado"
        )
        XCTAssertEqual(unverified, .unverified)
        XCTAssertEqual(unverified.badgeText, "Equipo: estado no verificado")

        let paused = ConnectionStatusEvaluator.evaluateHost(
            backendMode: .native,
            connectionHealth: .connected,
            remoteProviderName: nil,
            sandboxLink: nil,
            hostLiveness: .unknown,
            heartbeatState: .paused,
            monitorStatus: "Apagado"
        )
        XCTAssertEqual(paused, .paused)
    }

    func testHumanConfirmationFormatterHidesTechnicalDetailsBehindDisclosure() {
        let action = PendingAction(
            title: "Enviar correo",
            message: "Se enviará desde tu cuenta de Gmail.",
            details: [("Para", "ana@empresa.mx"), ("Asunto", "Agenda")],
            toolId: "gmail.write.send",
            run: { "ok" }
        )
        let summary = HumanConfirmationFormatter.format(action: action)
        XCTAssertEqual(summary.headline, "Enviar correo a ana@empresa.mx")
        XCTAssertEqual(summary.readableDetails.first?.1, "ana@empresa.mx")
        XCTAssertTrue(summary.technicalDetails.contains { $0.0 == "Tool ID" && $0.1 == "gmail.write.send" })

        let perm = TimelineEvent.permission(
            requestId: "req-1",
            tool: "googlecalendar.write.event",
            command: "title=Revisión",
            explanation: "Se agregará un evento.",
            scope: "sandbox",
            agentMode: .build
        )
        let permSummary = HumanConfirmationFormatter.format(permission: perm)
        XCTAssertEqual(permSummary.headline, "Crear evento en Google Calendar")
        XCTAssertTrue(permSummary.technicalDetails.contains { $0.0 == "Herramienta" && $0.1 == "googlecalendar.write.event" })
    }
}
