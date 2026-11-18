import Foundation

public enum RecordedWorkflowStepKind: String, Codable, Sendable, CaseIterable {
    case launchApp
    case waitForScreen
    case tapElement
    case typeText
    case secureField

    public var displayTitle: String {
        switch self {
        case .launchApp: return "Abrir aplicación"
        case .waitForScreen: return "Esperar pantalla"
        case .tapElement: return "Tocar elemento"
        case .typeText: return "Escribir texto"
        case .secureField: return "Campo protegido (Llavero)"
        }
    }

    public var icon: String {
        switch self {
        case .launchApp: return "app.badge.checkmark"
        case .waitForScreen: return "hourglass"
        case .tapElement: return "hand.tap"
        case .typeText: return "keyboard"
        case .secureField: return "key.fill"
        }
    }
}

public struct RecordedWorkflowStep: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public var bundleID: String
    public var appDisplayName: String
    public var kind: RecordedWorkflowStepKind
    public var suggestedTool: String
    public var suggestedArgs: [String: String]
    public var elementSummary: String
    /// When set, `typeText` step compiles to `{{parameterName}}` instead of literal demonstrated text.
    public var parameterName: String?
    /// When set, binds a Keychain secret alias (`{{secret:alias.field}}`) cleanly without storing secrets.
    public var secretAlias: String?
    public var secretField: SecretVaultField
    public var included: Bool

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        bundleID: String,
        appDisplayName: String,
        kind: RecordedWorkflowStepKind,
        suggestedTool: String,
        suggestedArgs: [String: String],
        elementSummary: String,
        parameterName: String? = nil,
        secretAlias: String? = nil,
        secretField: SecretVaultField = .password,
        included: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.appDisplayName = appDisplayName
        self.kind = kind
        self.suggestedTool = suggestedTool
        self.suggestedArgs = suggestedArgs
        self.elementSummary = elementSummary
        self.parameterName = parameterName
        self.secretAlias = secretAlias
        self.secretField = secretField
        self.included = included
    }
}

public struct RecordedWorkflowSession: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var goalTitle: String
    public var goalDescription: String
    public var targetToolName: String
    public var expectedParameters: [String]
    public var linkedSecretAliases: [String]
    public let startedAt: Date
    public var finishedAt: Date?
    public var steps: [RecordedWorkflowStep]
    public var observedApps: [String]
    public var wdaConnectedDuringSession: Bool
    public var sampleCount: Int
    public var notes: [String]

    public init(
        id: String = UUID().uuidString,
        goalTitle: String,
        goalDescription: String,
        targetToolName: String,
        expectedParameters: [String] = [],
        linkedSecretAliases: [String] = [],
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        steps: [RecordedWorkflowStep] = [],
        observedApps: [String] = [],
        wdaConnectedDuringSession: Bool = false,
        sampleCount: Int = 0,
        notes: [String] = []
    ) {
        self.id = id
        self.goalTitle = goalTitle
        self.goalDescription = goalDescription
        self.targetToolName = targetToolName
        self.expectedParameters = expectedParameters
        self.linkedSecretAliases = linkedSecretAliases
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
        self.observedApps = observedApps
        self.wdaConnectedDuringSession = wdaConnectedDuringSession
        self.sampleCount = sampleCount
        self.notes = notes
    }
}

public enum ActionRecorderStatus: Equatable, Sendable {
    case idle
    case prepared
    case recording(elapsedSeconds: Int, sampleCount: Int, currentApp: String, stepsCount: Int)
    case reviewReady
    case wdaUnavailable(String)
    case error(String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// Pure, hardware-independent frame diffing engine for WebDriverAgent polling snapshots.
/// Reconstructs logical workflow transitions without capturing raw screen passwords or requiring touch stream hooks.
public enum ActionRecorderDiffEngine {
    public static func appDisplayName(for bundleID: String) -> String {
        switch bundleID {
        case "net.whatsapp.WhatsApp": return "WhatsApp"
        case "com.apple.mobilesafari": return "Safari"
        case "com.apple.Preferences": return "Ajustes"
        case "com.apple.MobileSMS": return "Mensajes"
        case "com.apple.mobilemail": return "Mail"
        case "com.openai.chat": return "ChatGPT"
        case "com.google.Gmail": return "Gmail"
        case "com.apple.springboard": return "Pantalla de inicio"
        case "": return "Desconocida"
        default:
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
    }

    public static func suggestToolSlug(from title: String) -> String {
        let ascii = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let mapped = ascii.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let clean = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        let body = clean.isEmpty ? "accion_aprendida" : String(clean.prefix(36))
        return body.hasPrefix("l1_") ? body : "l1_\(body)"
    }

    public static func diffFrames(
        previousBundleID: String?,
        previousElements: [LocalElement],
        currentBundleID: String,
        currentElements: [LocalElement],
        selfBundleID: String,
        expectedParameters: [String],
        linkedSecretAliases: [String]
    ) -> [RecordedWorkflowStep] {
        var emitted: [RecordedWorkflowStep] = []
        let appName = appDisplayName(for: currentBundleID)

        // Skip internal SpringBoard / self transitions unless leaving ISyCode into target app
        let isSelfApp = !selfBundleID.isEmpty && currentBundleID == selfBundleID
        let isSystemTransient = currentBundleID == "com.apple.springboard" || currentBundleID.isEmpty

        if let prevApp = previousBundleID, prevApp != currentBundleID, !isSelfApp, !isSystemTransient {
            emitted.append(RecordedWorkflowStep(
                bundleID: currentBundleID,
                appDisplayName: appName,
                kind: .launchApp,
                suggestedTool: "iphone_launch_app",
                suggestedArgs: ["bundle_id": currentBundleID],
                elementSummary: "Cambió a \(appName) (\(currentBundleID))"
            ))
        }

        guard !isSelfApp, !isSystemTransient else {
            return emitted
        }

        // Compare input fields
        let textInputKinds: Set<String> = ["TextField", "SearchField", "TextView"]
        let prevInputs = Dictionary(
            previousElements.filter { textInputKinds.contains($0.kind) }
                .map { (elementSignature($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for el in currentElements where textInputKinds.contains(el.kind) {
            let trimmedVal = el.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedVal.isEmpty, trimmedVal != el.label else { continue }
            let sig = elementSignature(el)
            let oldVal = prevInputs[sig]?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmedVal != oldVal else { continue }

            let fieldHint = [el.label, el.name, el.kind].filter { !$0.isEmpty }.joined(separator: " ")
            let tapLabel = [el.label, el.name].first(where: { !$0.isEmpty })
            if oldVal.isEmpty, let tapLabel {
                emitted.append(RecordedWorkflowStep(
                    bundleID: currentBundleID,
                    appDisplayName: appName,
                    kind: .tapElement,
                    suggestedTool: "iphone_tap_element",
                    suggestedArgs: ["text": tapLabel],
                    elementSummary: "Enfocar campo \"\(tapLabel)\""
                ))
            }

            let matchedParam = matchParameterName(fieldHint: fieldHint, value: trimmedVal, expectedParameters: expectedParameters)
            let looksLikeUsername = isLikelyUsernameField(fieldHint)
            let linkedAlias = looksLikeUsername ? linkedSecretAliases.first : nil

            let compileValue: String
            if let linkedAlias {
                compileValue = "{{secret:\(linkedAlias).username}}"
            } else if let matchedParam {
                compileValue = "{{\(matchedParam)}}"
            } else {
                compileValue = trimmedVal
            }

            emitted.append(RecordedWorkflowStep(
                bundleID: currentBundleID,
                appDisplayName: appName,
                kind: .typeText,
                suggestedTool: "iphone_type_text",
                suggestedArgs: ["text": compileValue, "submit": "false"],
                elementSummary: "Escribió en \(fieldHint.isEmpty ? "campo de texto" : fieldHint): \"\(String(trimmedVal.prefix(40)))\"",
                parameterName: linkedAlias == nil ? matchedParam : nil,
                secretAlias: linkedAlias,
                secretField: .username
            ))
        }

        // Detect SecureTextField (passwords / PINs / secrets) — NEVER read/persist plain value!
        let prevSecure = previousElements.filter { $0.kind == "SecureTextField" }
        let curSecure = currentElements.filter { $0.kind == "SecureTextField" }
        for sec in curSecure {
            let sig = elementSignature(sec)
            let existedBefore = prevSecure.contains { elementSignature($0) == sig }
            let changedValueLen = prevSecure.first(where: { elementSignature($0) == sig }).map { $0.value != sec.value } ?? false
            if (!existedBefore || changedValueLen) {
                let targetAlias = linkedSecretAliases.first
                let fieldTarget = [sec.label, sec.name].first(where: { !$0.isEmpty }) ?? "Contraseña"
                emitted.append(RecordedWorkflowStep(
                    bundleID: currentBundleID,
                    appDisplayName: appName,
                    kind: .secureField,
                    suggestedTool: "iphone_type_text",
                    suggestedArgs: [
                        "text": targetAlias.map { "{{secret:\($0).password}}" } ?? "{{secret:DEFINE_ALIAS.password}}",
                        "submit": "true"
                    ],
                    elementSummary: "Campo protegido \"\(fieldTarget)\" detectado (el valor real nunca se lee; usa el Llavero).",
                    secretAlias: targetAlias,
                    secretField: .password
                ))
            }
        }

        // Detect screen shift inside same app to infer the tapped control + wait marker
        if previousBundleID == currentBundleID, !previousElements.isEmpty, !currentElements.isEmpty {
            let prevSet = Set(previousElements.map(\.text).filter { !$0.isEmpty })
            let curSet = Set(currentElements.map(\.text).filter { !$0.isEmpty })
            let disappeared = prevSet.subtracting(curSet)
            let appeared = curSet.subtracting(prevSet)

            if disappeared.count >= 3 && appeared.count >= 3 {
                let interactiveKinds: Set<String> = ["Button", "Cell", "Link"]
                let candidates = previousElements.filter { el in
                    interactiveKinds.contains(el.kind) &&
                    !el.text.isEmpty &&
                    disappeared.contains(el.text) &&
                    el.height >= 20 && el.height <= 120
                }
                if let likelyTap = candidates.first,
                   let anchor = appeared.sorted().first(where: { $0.count >= 3 && $0.count <= 40 }) {
                    emitted.append(RecordedWorkflowStep(
                        bundleID: currentBundleID,
                        appDisplayName: appName,
                        kind: .tapElement,
                        suggestedTool: "iphone_tap_element",
                        suggestedArgs: ["text": likelyTap.text],
                        elementSummary: "Cambio de pantalla en \(appName) (posible toque en \"\(likelyTap.text)\")"
                    ))
                    emitted.append(RecordedWorkflowStep(
                        bundleID: currentBundleID,
                        appDisplayName: appName,
                        kind: .waitForScreen,
                        suggestedTool: "iphone_wait_for",
                        suggestedArgs: ["text": anchor, "timeout": "8"],
                        elementSummary: "Esperar elemento visible \"\(anchor)\""
                    ))
                }
            }
        }

        return emitted
    }

    private static func elementSignature(_ el: LocalElement) -> String {
        "\(el.kind)|\(el.label)|\(el.name)|\(el.centerX)x\(el.centerY)"
    }

    private static func isLikelyUsernameField(_ hint: String) -> Bool {
        let lower = hint.lowercased()
        return ["usuario", "user", "correo", "email", "nit", "rfc", "cuenta", "login"].contains { lower.contains($0) }
    }

    private static func matchParameterName(fieldHint: String, value: String, expectedParameters: [String]) -> String? {
        guard !expectedParameters.isEmpty else { return nil }
        let lowerHint = fieldHint.lowercased()
        for param in expectedParameters {
            let p = param.lowercased()
            if lowerHint.contains(p) {
                return param
            }
            if (p.contains("contact") || p.contains("destinat") || p.contains("search") || p.contains("buscar"))
                && (lowerHint.contains("search") || lowerHint.contains("buscar") || lowerHint.contains("para")) {
                return param
            }
            if (p.contains("mensaj") || p.contains("texto") || p.contains("body"))
                && (lowerHint.contains("mensaj") || lowerHint.contains("message") || lowerHint.contains("escrib")) {
                return param
            }
        }
        return expectedParameters.count == 1 ? expectedParameters[0] : nil
    }
}

/// Manages WDA background polling sessions while the user demonstrates a task in external apps,
/// keeping the app alive via `BackgroundRunKeeper` and compiling recorded steps into parameterized L1 tools.
@MainActor
public final class ActionRecorderService: ObservableObject {
    public static let shared = ActionRecorderService()

    @Published public private(set) var status: ActionRecorderStatus = .idle
    @Published public var draftSession: RecordedWorkflowSession?
    @Published public private(set) var liveBannerPrompt: (title: String, goal: String, parameters: [String], secretAliases: [String])?
    @Published public private(set) var savedSessions: [RecordedWorkflowSession] = []

    private let wdaFactory: @Sendable () -> any WdaDriving
    private let reader: WdaElementReader
    private let sessionsURL: URL
    private let selfBundleID: String
    private var pollTask: Task<Void, Never>?
    private var lastBundleID: String?
    private var lastElements: [LocalElement] = []

    public init(
        directoryURL: URL? = nil,
        wdaFactory: (@Sendable () -> any WdaDriving)? = nil,
        reader: WdaElementReader = WdaElementReader(),
        selfBundleID: String = Bundle.main.bundleIdentifier ?? "com.isyco.iyscodemovil"
    ) {
        let base: URL
        if let directoryURL {
            base = directoryURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = docs.appendingPathComponent(".isycode")
        }
        self.sessionsURL = base.appendingPathComponent("learned_workflows.json")
        self.wdaFactory = wdaFactory ?? { WdaClientDriver(client: WdaClient()) }
        self.reader = reader
        self.selfBundleID = selfBundleID
        loadSessions()
    }

    public func loadSessions() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? decoder.decode([RecordedWorkflowSession].self, from: data) {
            self.savedSessions = decoded
        }
    }

    /// Invoked either by the UI button or when the chat agent calls `learn_action_prepare`.
    public func prepareSession(
        goalTitle: String,
        goalDescription: String,
        parameters: [String],
        linkedSecretAliases: [String],
        fromAgent: Bool = false
    ) {
        let cleanTitle = goalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = ActionRecorderDiffEngine.suggestToolSlug(from: cleanTitle)
        let cleanParams = parameters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
            .filter { !$0.isEmpty }
        let cleanSecrets = linkedSecretAliases
            .map(SecretVaultEntryMetadata.normalizeAlias)
            .filter { !$0.isEmpty }

        draftSession = RecordedWorkflowSession(
            goalTitle: cleanTitle.isEmpty ? "Acción aprendida" : cleanTitle,
            goalDescription: goalDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            targetToolName: slug,
            expectedParameters: cleanParams,
            linkedSecretAliases: cleanSecrets
        )
        status = .prepared
        if fromAgent {
            liveBannerPrompt = (
                title: draftSession?.goalTitle ?? "Aprender acción",
                goal: draftSession?.goalDescription ?? "",
                parameters: cleanParams,
                secretAliases: cleanSecrets
            )
        }
    }

    public func dismissAgentPrompt() {
        liveBannerPrompt = nil
    }

    public func startRecording(pollIntervalNs: UInt64 = 1_200_000_000, maxDurationSeconds: Int = 300) async {
        stopPollingTaskOnly()

        let currentDraft = draftSession ?? RecordedWorkflowSession(
            goalTitle: "Acción aprendida",
            goalDescription: "Flujo demostrado por el usuario en pantalla",
            targetToolName: "l1_accion_aprendida"
        )

        let driver = wdaFactory()
        do {
            let initialStatus = try await driver.status()
            guard initialStatus.ready else {
                status = .wdaUnavailable("WDA respondió en 127.0.0.1:8100 pero aún no está listo. Verifica LocalDevVPN o crea los pasos manualmente.")
                return
            }
        } catch {
            status = .wdaUnavailable("No hay conexión con WebDriverAgent (127.0.0.1:8100): \(error.localizedDescription). Conecta LocalDevVPN en Conexiones o usa el editor manual de pasos.")
            return
        }

        var session = currentDraft
        session.steps = []
        session.observedApps = []
        session.sampleCount = 0
        session.wdaConnectedDuringSession = true
        session.finishedAt = nil
        draftSession = session
        lastBundleID = nil
        lastElements = []
        liveBannerPrompt = nil

        BackgroundRunKeeper.shared.begin()
        let startDate = Date()
        status = .recording(elapsedSeconds: 0, sampleCount: 0, currentApp: "ISyCode Móvil", stepsCount: 0)

        pollTask = Task { [weak self] in
            guard let self else { return }
            defer { BackgroundRunKeeper.shared.end() }
            var consecutiveErrors = 0

            while !Task.isCancelled {
                let elapsed = Int(Date().timeIntervalSince(startDate))
                if elapsed >= maxDurationSeconds {
                    await MainActor.run {
                        self.finalizeRecording(note: "Tiempo máximo de grabación (\(maxDurationSeconds)s) alcanzado.")
                    }
                    return
                }

                do {
                    let st = try await driver.status()
                    let xml = try await driver.pageSource()
                    let parsed = self.reader.parse(xml: xml)
                    let currentBundle = st.foregroundBundleID ?? ""
                    consecutiveErrors = 0

                    await MainActor.run {
                        self.ingestFrame(bundleID: currentBundle, elements: parsed, startedAt: startDate)
                    }
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 6 {
                        await MainActor.run {
                            self.finalizeRecording(note: "Se perdió el contacto con WDA durante la grabación (\(error.localizedDescription)).")
                        }
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }
    }

    public func stopRecording() {
        stopPollingTaskOnly()
        finalizeRecording(note: nil)
    }

    /// Allows transitioning into manual step composer when WDA is offline on the road.
    public func enterManualComposer() {
        stopPollingTaskOnly()
        var session = draftSession ?? RecordedWorkflowSession(
            goalTitle: "Flujo manual",
            goalDescription: "Pasos definidos manualmente",
            targetToolName: "l1_flujo_manual"
        )
        session.wdaConnectedDuringSession = false
        if session.steps.isEmpty {
            session.steps = [
                RecordedWorkflowStep(
                    bundleID: "net.whatsapp.WhatsApp",
                    appDisplayName: "WhatsApp",
                    kind: .launchApp,
                    suggestedTool: "iphone_launch_app",
                    suggestedArgs: ["bundle_id": "net.whatsapp.WhatsApp"],
                    elementSummary: "Abrir la app destino"
                )
            ]
        }
        draftSession = session
        status = .reviewReady
    }

    public func compileToL1Tool(
        from session: RecordedWorkflowSession,
        customName: String? = nil,
        description: String? = nil
    ) -> L1ToolDefinition {
        let chosenSlug = ActionRecorderDiffEngine.suggestToolSlug(from: customName ?? session.targetToolName)
        let activeSteps = session.steps.filter(\.included)
        var l1Steps: [L1ToolDefinition.Step] = []
        var detectedParams: [String] = session.expectedParameters
        var secretAliases: Set<String> = Set(session.linkedSecretAliases)

        for step in activeSteps {
            var finalArgs = step.suggestedArgs
            if let param = step.parameterName?.trimmingCharacters(in: .whitespacesAndNewlines), !param.isEmpty {
                let normalizedParam = param.lowercased().replacingOccurrences(of: " ", with: "_")
                if !detectedParams.contains(normalizedParam) {
                    detectedParams.append(normalizedParam)
                }
                if step.kind == .typeText {
                    finalArgs["text"] = "{{\(normalizedParam)}}"
                }
            }
            if let alias = step.secretAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                let cleanAlias = SecretVaultEntryMetadata.normalizeAlias(alias)
                secretAliases.insert(cleanAlias)
                if step.kind == .secureField || step.kind == .typeText {
                    finalArgs["text"] = "{{secret:\(cleanAlias).\(step.secretField.rawValue)}}"
                }
            }
            for val in finalArgs.values {
                for alias in SecretVaultStore.extractAliases(in: val) {
                    secretAliases.insert(alias)
                }
            }
            l1Steps.append(L1ToolDefinition.Step(tool: step.suggestedTool, args: finalArgs))
        }

        let summaryDesc = (description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? description!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (session.goalDescription.isEmpty ? session.goalTitle : session.goalDescription)

        let sortedSecrets = Array(secretAliases).sorted()
        let paramHint = detectedParams.isEmpty ? "" : " Parámetros: \(detectedParams.map { "{{\($0)}}" }.joined(separator: ", "))."
        let secretHint = sortedSecrets.isEmpty ? "" : " Usa Llavero: \(sortedSecrets.joined(separator: ", "))."

        let l1Params = Array(Set(detectedParams)).sorted().map { paramName in
            L1ToolDefinition.Parameter(
                name: paramName,
                type: "string",
                description: "Valor dinámico para {{\(paramName)}} en el flujo '\(session.goalTitle)'."
            )
        }

        return L1ToolDefinition(
            name: chosenSlug,
            description: "\(summaryDesc).\(paramHint)\(secretHint)",
            parameters: l1Params,
            outputSchema: "Resumen paso a paso de la automatización UI ejecutada.",
            steps: l1Steps,
            requiredPermissions: sortedSecrets.isEmpty ? ["Control visual del iPhone (WDA)"] : ["Control visual del iPhone (WDA)", "Llavero protegido (Face ID)"],
            restrictions: sortedSecrets.isEmpty
                ? ["Aprendido por demostración; requiere autorización según las políticas de pasos WDA."]
                : ["Contiene referencias del Llavero ({{secret:...}}); siempre exige confirmación manual y nunca pasa con modo Flow ni secuencia automática."],
            requiredSecrets: sortedSecrets,
            workflowSummary: session.goalTitle,
            provenance: L1ToolDefinition.provenanceLearned
        )
    }

    public func saveAndRegisterCompiledTool(session: RecordedWorkflowSession, customName: String, description: String) async throws -> L1ToolDefinition {
        let l1 = compileToL1Tool(from: session, customName: customName, description: description)
        try await DynamicToolRegistry.shared.upsert(l1)

        var stored = session
        stored.finishedAt = stored.finishedAt ?? Date()
        stored.targetToolName = l1.name
        stored.linkedSecretAliases = l1.requiredSecrets
        if let idx = savedSessions.firstIndex(where: { $0.id == stored.id }) {
            savedSessions[idx] = stored
        } else {
            savedSessions.insert(stored, at: 0)
        }
        persistSessions()
        draftSession = stored
        status = .idle
        return l1
    }

    public func statusSummaryForAgent() -> String {
        switch status {
        case .idle:
            return "Grabador inactivo. Hay \(savedSessions.count) flujo(s) aprendido(s) guardados."
        case .prepared:
            return "Grabación preparada para '\(draftSession?.goalTitle ?? "Acción")'. Esperando a que la persona pulse Iniciar grabación."
        case .recording(let elapsed, let samples, let app, let steps):
            return "Grabando en curso (\(elapsed)s, \(samples) muestras, app actual: \(app), \(steps) paso(s) detectados)."
        case .reviewReady:
            return "Grabación finalizada para '\(draftSession?.goalTitle ?? "Acción")' con \(draftSession?.steps.count ?? 0) paso(s) listos para compilar."
        case .wdaUnavailable(let msg):
            return "WDA no disponible: \(msg)"
        case .error(let msg):
            return "Error en grabador: \(msg)"
        }
    }

    // MARK: - Frame Ingestion

    private func ingestFrame(bundleID: String, elements: [LocalElement], startedAt: Date) {
        guard var session = draftSession else { return }
        session.sampleCount += 1

        if !bundleID.isEmpty, bundleID != selfBundleID, !session.observedApps.contains(bundleID) {
            session.observedApps.append(bundleID)
        }

        let newSteps = ActionRecorderDiffEngine.diffFrames(
            previousBundleID: lastBundleID,
            previousElements: lastElements,
            currentBundleID: bundleID,
            currentElements: elements,
            selfBundleID: selfBundleID,
            expectedParameters: session.expectedParameters,
            linkedSecretAliases: session.linkedSecretAliases
        )

        for step in newSteps {
            // Coalesce rapid incremental typing inside the exact same field summary
            if step.kind == .typeText,
               var last = session.steps.last,
               last.kind == .typeText,
               last.bundleID == step.bundleID,
               last.suggestedArgs["text"]?.hasPrefix("{{") == false,
               let newVal = step.suggestedArgs["text"],
               let prevVal = last.suggestedArgs["text"],
               newVal.hasPrefix(prevVal) || prevVal.hasPrefix(newVal) {
                last.suggestedArgs = step.suggestedArgs
                last.elementSummary = step.elementSummary
                last.parameterName = step.parameterName
                session.steps[session.steps.count - 1] = last
            } else {
                session.steps.append(step)
            }
        }

        lastBundleID = bundleID
        lastElements = elements
        draftSession = session

        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let displayApp = ActionRecorderDiffEngine.appDisplayName(for: bundleID)
        status = .recording(
            elapsedSeconds: elapsed,
            sampleCount: session.sampleCount,
            currentApp: displayApp,
            stepsCount: session.steps.count
        )
    }

    private func finalizeRecording(note: String?) {
        guard var session = draftSession else {
            status = .idle
            return
        }
        session.finishedAt = Date()
        if let note, !note.isEmpty {
            session.notes.append(note)
        }
        draftSession = session
        status = .reviewReady
    }

    private func stopPollingTaskOnly() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func persistSessions() {
        do {
            try FileManager.default.createDirectory(at: sessionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(savedSessions)
            try data.write(to: sessionsURL, options: .atomic)
        } catch {
            // Non-fatal metadata log failure
        }
    }
}
