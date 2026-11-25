import SwiftUI

public struct GUSAdvisorExchange: Identifiable, Equatable, Sendable {
    public let id: String
    public let userQuestion: String?
    public let gusResponse: String
    public let suggestedActions: [GUSContextualAction]
    public let receiptPreview: String?

    public init(
        id: String = UUID().uuidString,
        userQuestion: String? = nil,
        gusResponse: String,
        suggestedActions: [GUSContextualAction] = [],
        receiptPreview: String? = nil
    ) {
        self.id = id
        self.userQuestion = userQuestion
        self.gusResponse = gusResponse
        self.suggestedActions = suggestedActions
        self.receiptPreview = receiptPreview
    }
}

public enum GUSContextualAction: String, Identifiable, Equatable, Sendable {
    case prepareCatalogCapability
    case applyRecommendedTools
    case explainPermissions
    case testWithSampleCSV
    case viewAvailableTools
    case openBuilder
    case dismissToScreen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prepareCatalogCapability: return "Proponer importador CSV"
        case .applyRecommendedTools: return "Revisar herramientas"
        case .explainPermissions: return "Explicar permisos"
        case .testWithSampleCSV: return "Probar con un archivo"
        case .viewAvailableTools: return "Ver herramientas"
        case .openBuilder: return "Ir a Construir agente"
        case .dismissToScreen: return "Volver"
        }
    }

    public var symbol: String {
        switch self {
        case .prepareCatalogCapability: return "wand.and.stars"
        case .applyRecommendedTools: return "plus.circle.fill"
        case .explainPermissions: return "checkmark.shield.fill"
        case .testWithSampleCSV: return "play.fill"
        case .viewAvailableTools: return "wrench.and.screwdriver.fill"
        case .openBuilder: return "hammer.fill"
        case .dismissToScreen: return "arrow.uturn.backward"
        }
    }
}

private final class GUSAdvisorSession: ObservableObject {
    @Published var questionInput = ""
    @Published var exchanges: [GUSAdvisorExchange] = []
    @Published var isRunningSample = false
    @Published var statusBanner: String?
}

private struct BuilderToolProposal: Identifiable {
    let id = UUID()
    let contractID: String
    let tools: [String]
    let compositions: [L1ToolDefinition]
}

/// Floating contextual GUS button that sits non-intrusively over primary screens
/// and opens the contextual GUS advisor sheet without losing navigation or builder state (Section 7).
public struct GUSFloatingAdvisorButton: View {
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var contractStore = AgentContractStore.shared
    @State private var isPresented = false
    @StateObject private var session = GUSAdvisorSession()

    public init() {}

    private var contextBadge: String {
        switch router.activeDestination {
        case .builder:
            return "GUS · Constructor"
        case .myAgents:
            return "GUS · Mis agentes"
        case .connections:
            return "GUS · Conexiones"
        case .google:
            return "GUS · Google"
        default:
            return "GUS"
        }
    }

    public var body: some View {
        Button {
            OCHaptics.light()
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(IysThemePreferences.active.accent.opacity(0.22))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(IysThemePreferences.active.accent)
                }
                Text(contextBadge)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 13)
            .frame(minHeight: 44)
            .background(
                Capsule()
                    .fill(OCColor.bgBase.opacity(0.96))
                    .overlay(
                        Capsule()
                            .stroke(IysThemePreferences.active.accent.opacity(0.55), lineWidth: 1.2)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 4)
            )
        }
        .buttonStyle(OCInteractiveButtonStyle())
        .accessibilityLabel("Abrir asistente contextual GUS")
        .accessibilityIdentifier("gus-floating-button")
        .sheet(isPresented: $isPresented) {
            GUSContextualSheet(session: session)
                .environmentObject(router)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

public struct GUSContextualSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var contractStore = AgentContractStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var session: GUSAdvisorSession
    @State private var proposal: BuilderToolProposal?
    private let canMinimize: Bool

    public init() {
        _session = StateObject(wrappedValue: GUSAdvisorSession())
        canMinimize = false
    }

    fileprivate init(session: GUSAdvisorSession) {
        _session = StateObject(wrappedValue: session)
        canMinimize = true
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextHeaderBanner

                if let statusBanner = session.statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(OCColor.textSecondary)
                        Text(statusBanner)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(OCColor.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.vertical, 8)
                    .background(OCColor.bgBase)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: OCSpacing.md) {
                        initialContextualCard

                        ForEach(session.exchanges) { item in
                            exchangeView(item)
                        }
                    }
                    .padding(OCSpacing.contentMargin)
                }

                Divider().overlay(OCColor.borderMuted)

                inputBar
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("GUS · Ayuda contextual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(canMinimize ? "Minimizar" : "Cerrar") { dismiss() }
                        .accessibilityIdentifier("gus-close")
                }
            }
        }
        .sheet(item: $proposal) { proposalReview($0) }
    }

    @ViewBuilder
    private func proposalReview(_ proposal: BuilderToolProposal) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.md) {
                    Text("Se añadirán al borrador. Podrás revisar sus permisos antes de usar el agente.")
                        .font(.body)
                    ForEach(proposal.tools + proposal.compositions.map(\.name), id: \.self) { name in
                        Label(name, systemImage: "wrench.and.screwdriver")
                            .font(.callout)
                    }
                    ForEach(AgentContract.computeRequiredScopes(l0Tools: proposal.tools, l1Tools: proposal.compositions)) { scope in
                        VStack(alignment: .leading) {
                            Text(scope.title).font(.headline)
                            Text(scope.plainExplanation).font(.subheadline).foregroundColor(OCColor.textSecondary)
                        }
                    }
                    Button("Añadir al agente") {
                        guard var draft = contractStore.activeDraft, draft.contract.id == proposal.contractID else {
                            session.statusBanner = "El borrador cambió. Vuelve a revisar las herramientas."
                            self.proposal = nil
                            return
                        }
                        draft.addTools(proposal.tools, compositions: proposal.compositions)
                        let saved = contractStore.saveDraft(draft)
                        session.statusBanner = saved ? "Borrador actualizado." : contractStore.lastError
                        if saved {
                            session.exchanges.append(GUSAdvisorExchange(gusResponse: "Tu borrador incluye " + (proposal.tools + proposal.compositions.map(\.name)).joined(separator: ", ") + "."))
                        }
                        self.proposal = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("gus-apply-proposal")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OCSpacing.contentMargin)
            }
            .navigationTitle("Herramientas propuestas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { self.proposal = nil } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var contextHeaderBanner: some View {
        HStack(spacing: OCSpacing.sm) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(IysThemePreferences.active.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Viendo: \(screenContextTitle)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                Text("GUS asesora y propone capacidades reales. Nunca amplía permisos sin tu confirmación.")
                    .font(.system(size: 11))
                    .foregroundColor(OCColor.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.vertical, 9)
        .background(OCColor.bgBase)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(OCColor.borderMuted), alignment: .bottom)
    }

    private var screenContextTitle: String {
        switch router.activeDestination {
        case .builder:
            if let draft = contractStore.activeDraft {
                return "Constructor de agentes · \(draft.contract.name)"
            }
            return "Constructor de agentes"
        case .myAgents:
            return "Mis agentes y contratos (.isyagent.json)"
        case .connections:
            return "Conexiones (iPhone local e ISyMCP)"
        case .google:
            return "Google Workspace y Memoria"
        case .browser:
            return "Navegador integrado"
        case .projects:
            return "Proyectos y archivos"
        case .settings:
            return "Ajustes"
        case .chat:
            return "Conversación principal"
        }
    }

    private var initialContextualCard: some View {
        let guidance = currentGuidance
        return VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack(spacing: 10) {
                ZStack {
                    OCRoundedRect(OCRadius.r10)
                        .fill(IysThemePreferences.active.accent.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(IysThemePreferences.active.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("GUS · Tu copiloto en iSyCode")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(guidance.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(OCColor.textSecondary)
                }
            }

            Text(guidance.body)
                .font(.system(size: 14))
                .foregroundColor(OCColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            actionChipsGrid(guidance.actions)

            VStack(alignment: .leading, spacing: 6) {
                Text("PREGUNTAS RÁPIDAS")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                ForEach(guidance.quickQuestions, id: \.self) { q in
                    Button {
                        askGUS(q)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 11))
                                .foregroundColor(IysThemePreferences.active.accent)
                            Text(q)
                                .font(.system(size: 13))
                                .foregroundColor(OCColor.textSecondary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(OCColor.bgDeep)
                        .clipShape(OCRoundedRect(OCRadius.r10))
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                }
            }
        }
        .padding(OCSpacing.lg)
        .ocCard(radius: OCRadius.r14, border: IysThemePreferences.active.accent.opacity(0.30), background: OCColor.bgBase)
    }

    private func exchangeView(_ item: GUSAdvisorExchange) -> some View {
        VStack(alignment: .leading, spacing: OCSpacing.sm) {
            if let q = item.userQuestion {
                HStack {
                    Spacer()
                    Text(q)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OCColor.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(IysThemePreferences.active.userSurface)
                        .clipShape(OCRoundedRect(OCRadius.r14))
                }
            }

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(IysThemePreferences.active.accent)
                    Text("GUS")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(IysThemePreferences.active.accent)
                }

                Text(item.gusResponse)
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let receipt = item.receiptPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Recibo de ejecución", systemImage: "doc.text")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(OCColor.textSecondary)
                        Text(receipt)
                            .font(OCTypography.codeSmall)
                            .foregroundColor(OCColor.textSecondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(OCColor.bgDeep)
                            .clipShape(OCRoundedRect(OCRadius.r8))
                    }
                }

                if !item.suggestedActions.isEmpty {
                    actionChipsGrid(item.suggestedActions, goal: item.userQuestion)
                }
            }
            .padding(OCSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IysThemePreferences.active.assistantSurface)
            .clipShape(OCRoundedRect(OCRadius.r14))
            .overlay(OCRoundedRect(OCRadius.r14).stroke(OCColor.borderBase, lineWidth: 1))
        }
    }

    private func actionChipsGrid(_ actions: [GUSContextualAction], goal: String? = nil) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        performAction(action, goal: goal)
                    } label: {
                        HStack(spacing: 6) {
                            if action == .testWithSampleCSV && session.isRunningSample {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: action.symbol)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(action.title)
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundColor(action == .prepareCatalogCapability || action == .applyRecommendedTools ? OCColor.onAccent : OCColor.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                action == .prepareCatalogCapability || action == .applyRecommendedTools
                                    ? AnyShapeStyle(IysThemePreferences.active.accent.gradient)
                                    : AnyShapeStyle(OCColor.bgLayer1)
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                action == .prepareCatalogCapability || action == .applyRecommendedTools
                                    ? Color.clear
                                    : OCColor.borderBase,
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                    .disabled(session.isRunningSample)
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            DictationLiveStatusBar()
                .padding(.horizontal, OCSpacing.contentMargin)

            HStack(spacing: 8) {
                TextField("Pregúntale a GUS sobre lo que estás construyendo…", text: $session.questionInput, axis: .vertical)
                    .font(.system(size: 14.5))
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(OCColor.bgBase)
                    .clipShape(OCRoundedRect(OCRadius.r18))
                    .overlay(OCRoundedRect(OCRadius.r18).stroke(OCColor.borderBase, lineWidth: 1))
                    .onSubmit { submitQuestion() }

                DictationMicrophoneButton(targetText: $session.questionInput)

                Button(action: submitQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(session.questionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OCColor.textFaint : IysThemePreferences.active.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preguntar a GUS")
                .accessibilityIdentifier("gus-submit")
                .disabled(session.questionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, 10)
        }
        .background(OCColor.bgBase)
    }

    private func submitQuestion() {
        let trimmed = session.questionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.questionInput = ""
        askGUS(trimmed)
    }

    private func askGUS(_ q: String) {
        OCHaptics.light()
        let lower = q.lowercased()
        let response: String
        let actions: [GUSContextualAction]

        if lower.contains("tienda") || lower.contains("csv") || lower.contains("producto") || lower.contains("catálogo") || lower.contains("catalogo") {
            response = "Podemos crear una herramienta para leer tu archivo CSV, revisar los precios con Python local en este iPhone y preparar un catálogo limpio. Necesitará permiso para leer el archivo y pedirte confirmación antes de guardar el resultado."
            actions = [.prepareCatalogCapability, .testWithSampleCSV, .explainPermissions, .viewAvailableTools, .dismissToScreen]
        } else if lower.contains("permiso") || lower.contains("seguridad") || lower.contains("autoriza") {
            response = "En iSyCode los permisos nunca se regalan por combinar herramientas: si una capacidad compuesta (L1) lee un archivo y guarda un catálogo, conserva exactamente esa exigencia y te pide confirmar antes de escribir. Además, para controlar apps del iPhone con WDA puedes aprobar una secuencia acotada solo para esa tarea."
            actions = [.explainPermissions, .applyRecommendedTools, .dismissToScreen]
        } else if lower.contains("pc") || lower.contains("computadora") || lower.contains("isymcp") || lower.contains("local") {
            response = "La regla es simple: todo lo cotidiano (archivos del proyecto, CSV, JSON, cálculos en Python, Gmail y navegador) corre directo en tu iPhone sin depender de nadie. Solo cuando necesites compilar código nativo (Swift, Zig), usar terminal bash o correr procesos pesados, el agente usa ISyMCP en tu computadora por Tailscale con tu Face ID."
            actions = [.viewAvailableTools, .applyRecommendedTools, .dismissToScreen]
        } else {
            let rec = AgentTemplateCatalog.recommendTools(forGoal: q)
            response = "Para lograr «\(q)», te recomiendo activar \(rec.l0.joined(separator: ", "))\(rec.l1.isEmpty ? "" : " más la capacidad compuesta \(rec.l1.map(\.name).joined(separator: ", "))"). \(rec.explanation)"
            actions = [.applyRecommendedTools, .prepareCatalogCapability, .testWithSampleCSV, .explainPermissions, .dismissToScreen]
        }

        withAnimation(reduceMotion ? nil : OCMotion.smooth) {
            session.exchanges.append(GUSAdvisorExchange(userQuestion: q, gusResponse: response, suggestedActions: actions))
        }
    }

    private func performAction(_ action: GUSContextualAction, goal: String?) {
        OCHaptics.selection()
        switch action {
        case .prepareCatalogCapability, .applyRecommendedTools:
            let draft = contractStore.activeDraft ?? AgentBuilderDraft.forNewAgent()
            if contractStore.activeDraft == nil { contractStore.saveDraft(draft) }
            let rec = AgentTemplateCatalog.recommendTools(forGoal: goal ?? draft.contract.goal)
            proposal = BuilderToolProposal(contractID: draft.contract.id,
                                           tools: action == .prepareCatalogCapability ? ["read_file", "python_eval", "write_file"] : rec.l0,
                                           compositions: action == .prepareCatalogCapability ? [.sampleCatalogImporter] : rec.l1)

        case .explainPermissions:
            let draft = contractStore.activeDraft ?? AgentBuilderDraft()
            let scopes = AgentContract.computeRequiredScopes(l0Tools: draft.contract.enabledL0Tools, l1Tools: draft.contract.l1Tools)
            let explanation = scopes.map { "• \($0.title): \($0.plainExplanation)" }.joined(separator: "\n")
            withAnimation(reduceMotion ? nil : OCMotion.smooth) {
                session.exchanges.append(GUSAdvisorExchange(
                    gusResponse: "Estos son los permisos efectivos que solicita tu agente (calculados automáticamente de sus herramientas L0 y L1, sin permisos ocultos):\n\n\(explanation)",
                    suggestedActions: [.testWithSampleCSV, .dismissToScreen]
                ))
            }

        case .testWithSampleCSV:
            guard !session.isRunningSample else { return }
            session.isRunningSample = true
            Task {
                let sampleCSV = "sku,nombre,precio,stock\nA01,Café Orgánico 500g,185.50,12\nA02,Prensa Francesa,420.00,5\nA03,Muestra Gratis,0,20"
                let script = L1ToolDefinition.sampleCatalogImporter.steps.first?.args["script"] ?? "print(INPUT_TEXT)"
                let receipt = await PythonRuntimeService.shared.evaluate(script: script, inputText: sampleCSV, timeoutMs: 3000)
                await MainActor.run {
                    session.isRunningSample = false
                    if receipt.succeeded { OCHaptics.success() } else { OCHaptics.error() }
                    withAnimation(reduceMotion ? nil : OCMotion.smooth) {
                        session.statusBanner = receipt.succeeded ? "Prueba terminada." : "No se pudo procesar la muestra."
                        session.exchanges.append(GUSAdvisorExchange(
                            gusResponse: receipt.succeeded ? "El intérprete procesó el CSV de ejemplo. Puedes consultar su salida." : "La prueba falló. Revisa el recibo o vuelve a intentarlo.",
                            suggestedActions: receipt.succeeded ? [.dismissToScreen] : [.testWithSampleCSV, .dismissToScreen],
                            receiptPreview: "Tiempo: \(receipt.durationMs) ms · Motor: \(receipt.runtimeVersion)\n\(receipt.error ?? receipt.stdout)"
                        ))
                    }
                }
            }

        case .viewAvailableTools:
            withAnimation(reduceMotion ? nil : OCMotion.smooth) {
                session.exchanges.append(GUSAdvisorExchange(
                    gusResponse: """
                    Capacidades disponibles hoy en iSyCode Móvil:
                    • En este iPhone (L0): Archivos (`read_file`, `write_file`), Python ligero (`python_eval` con `csv`, `json`, `math`), Navegador integrado (`browser_*`), HTTP (`http_request`), Google (`gmail.*`, `googlecalendar.*`) y Control del iPhone (`iphone_*` WDA).
                    • Compuestas (L1): `importar_catalogo_csv` y cualquier flujo que combines sin escalar permisos.
                    • En tu PC (ISyMCP): `isymcp_status`, `isymcp_tasks`, `isymcp_respond_task` y compiladores vía Tailscale + Face ID.
                    """,
                    suggestedActions: [.prepareCatalogCapability, .applyRecommendedTools, .dismissToScreen]
                ))
            }

        case .openBuilder:
            dismiss()
            router.openBuilder()

        case .dismissToScreen:
            dismiss()
        }
    }

    private func guidanceForStep(_ step: AgentBuilderStep) -> String {
        switch step {
        case .goal: return "Cuéntame una tarea que repites y qué resultado te gustaría obtener."
        case .capabilities: return "Puedo proponer herramientas para ese objetivo. Revisa qué hacen antes de añadirlas al borrador."
        case .customization: return "Elige dónde trabajará el agente. El teléfono puede procesar archivos locales y tu computadora necesita una conexión para recibir tareas."
        case .authorizations: return "Revisemos qué datos podrá consultar el agente y qué acciones requieren tu confirmación."
        case .liveTest: return "Prueba con datos de ejemplo. El recibo muestra la salida real y cuánto tardó."
        case .saveAndExport: return "Revisa el objetivo, las herramientas y los permisos. El contrato exportado se puede inspeccionar en otro dispositivo."
        }
    }

    private var currentGuidance: (subtitle: String, body: String, actions: [GUSContextualAction], quickQuestions: [String]) {
        switch router.activeDestination {
        case .builder:
            let draft = contractStore.activeDraft
            let draftName = draft?.contract.name ?? "tu agente"
            let step = AgentBuilderStep(rawValue: draft?.currentStepIndex ?? 0) ?? .goal
            return (
                subtitle: "\(draftName) · \(step.title)",
                body: guidanceForStep(step),
                actions: [.prepareCatalogCapability, .applyRecommendedTools, .explainPermissions, .testWithSampleCSV, .viewAvailableTools, .dismissToScreen],
                quickQuestions: [
                    "Quiero que mi agente importe productos de una tienda",
                    "¿Qué permisos necesita este agente y por qué?",
                    "¿Cuándo corre en mi iPhone y cuándo usa ISyMCP en la PC?"
                ]
            )
        case .myAgents:
            return (
                subtitle: "Administrando tus contratos de agentes (.isyagent.json)",
                body: "Cada agente que creas se guarda como un contrato verificable con sus herramientas L0/L1, scripts Python, permisos y pruebas. Si importas un contrato externo, puedes inspeccionarlo aquí sin ejecutar código y decidir si autorizas sus permisos.",
                actions: [.openBuilder, .explainPermissions, .viewAvailableTools],
                quickQuestions: [
                    "¿Cómo funciona el archivo .isyagent.json?",
                    "Quiero crear un agente para mi tienda"
                ]
            )
        default:
            return (
                subtitle: "Listo para ayudarte a conversar o construir agentes",
                body: "Puedes pedirme que te explique cualquier capacidad del sistema o abrir el Constructor para armar un agente paso a paso sin programar.",
                actions: [.openBuilder, .prepareCatalogCapability, .viewAvailableTools, .explainPermissions],
                quickQuestions: [
                    "Quiero que mi agente importe productos de una tienda",
                    "¿Qué herramientas pueden correr en este iPhone sin PC?"
                ]
            )
        }
    }
}
