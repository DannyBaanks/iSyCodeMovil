import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum AgentBuilderStep: Int, CaseIterable, Identifiable, Sendable {
    case goal = 0
    case capabilities = 1
    case customization = 2
    case authorizations = 3
    case liveTest = 4
    case saveAndExport = 5

    public var id: Int { rawValue }

    public var shortCode: String {
        switch self {
        case .goal: return "Paso A"
        case .capabilities: return "Paso B"
        case .customization: return "Paso C"
        case .authorizations: return "Paso D"
        case .liveTest: return "Paso E"
        case .saveAndExport: return "Paso F"
        }
    }

    public var title: String {
        switch self {
        case .goal: return "¿Qué quieres que haga?"
        case .capabilities: return "Capacidades"
        case .customization: return "Personalización"
        case .authorizations: return "Autorizaciones"
        case .liveTest: return "Prueba en vivo"
        case .saveAndExport: return "Guardar contrato"
        }
    }

    public var symbol: String {
        switch self {
        case .goal: return "sparkles"
        case .capabilities: return "wrench.and.screwdriver.fill"
        case .customization: return "slider.horizontal.3"
        case .authorizations: return "checkmark.shield.fill"
        case .liveTest: return "play.circle.fill"
        case .saveAndExport: return "doc.badge.gearshape.fill"
        }
    }
}

/// 6-step progressive Agent Builder ("Construir") with declarative templates,
/// L0/L1 composition, strict permission inheritance preview, live Python test,
/// and automatic draft persistence (Section 6).
public struct AgentBuilderView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var contractStore = AgentContractStore.shared
    @ObservedObject private var isymcpStore = ISyMCPStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var initialDraft = AgentBuilderDraft.forNewAgent()
    @State private var showsSteps = false
    @State private var showsTemplates = false
    @State private var pendingTemplate: AgentTemplate?
    private var draft: AgentBuilderDraft {
        get { contractStore.activeDraft ?? initialDraft }
        nonmutating set { contractStore.saveDraft(newValue) }
    }
    private var draftBinding: Binding<AgentBuilderDraft> {
        Binding(get: { draft }, set: { draft = $0 })
    }
    @State private var recommendationNote: String?
    @State private var isRunningTest = false
    @State private var lastTestReceipt: PythonExecutionReceipt?
    @State private var showCustomL1Composer = false
    @State private var showLearnRecorder = false
    @State private var showExportSheet = false
    @State private var savedBannerText: String?

    public init() {}

    private var currentStep: AgentBuilderStep {
        AgentBuilderStep(rawValue: max(0, min(draft.currentStepIndex, AgentBuilderStep.allCases.count - 1))) ?? .goal
    }

    public var body: some View {
        VStack(spacing: 0) {
            stepHeaderStrip

            if let savedBannerText {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(OCColor.success)
                    Text(savedBannerText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OCColor.textPrimary)
                    Spacer()
                    Button {
                        self.savedBannerText = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(OCColor.textFaint)
                    }
                }
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.vertical, 8)
                .background(OCColor.success.opacity(0.14))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.xl) {
                    stepBody
                }
                .padding(OCSpacing.contentMargin)
                .padding(.bottom, 76)
            }
            .id(currentStep)
            .scrollDismissesKeyboard(.interactively)

            navigationFooterBar
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("Construir agente")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if contractStore.activeDraft == nil { contractStore.saveDraft(initialDraft) }
        }
        .alert(item: $pendingTemplate) { template in
            Alert(title: Text("¿Usar la plantilla \(template.title)?"),
                  message: Text("Se reemplazarán el objetivo y las herramientas de este borrador."),
                  primaryButton: .default(Text("Usar plantilla")) {
                      var updated = draft
                      updated.selectedTemplateID = template.id
                      updated.contract = template.makeInitialContract()
                      draft = updated
                      recommendationNote = template.gusPitch
                      showsTemplates = false
                  }, secondaryButton: .cancel(Text("Conservar borrador")))
        }
        .sheet(isPresented: $showCustomL1Composer) {
            CustomL1ToolComposerSheet { newL1 in
                if !draft.contract.l1Tools.contains(where: { $0.name == newL1.name }) {
                    draft.contract.l1Tools.append(newL1)
                }
                for step in newL1.steps where !draft.contract.enabledL0Tools.contains(step.tool) {
                    draft.contract.enabledL0Tools.append(step.tool)
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            AgentContractInspectorSheet(contract: draft.contract)
        }
        .sheet(isPresented: $showLearnRecorder) {
            LearnActionRecorderSheet { compiled in
                if !draft.contract.l1Tools.contains(where: { $0.name == compiled.name }) {
                    draft.contract.l1Tools.append(compiled)
                }
                for step in compiled.steps where !draft.contract.enabledL0Tools.contains(step.tool) {
                    draft.contract.enabledL0Tools.append(step.tool)
                }
                for alias in compiled.requiredSecrets where !draft.contract.requiredSecrets.contains(alias) {
                    draft.contract.requiredSecrets.append(alias)
                }
            }
            .environmentObject(router)
        }
    }

    // MARK: - Step Progress Strip

    private var stepHeaderStrip: some View {
        VStack(alignment: .leading, spacing: OCSpacing.sm) {
            Button {
                OCHaptics.selection()
                withAnimation(reduceMotion ? nil : OCMotion.snappy) { showsSteps.toggle() }
            } label: {
                HStack {
                    Text("Paso \(currentStep.rawValue + 1) de \(AgentBuilderStep.allCases.count)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(showsSteps ? "Ocultar pasos" : "Ver pasos").font(.subheadline)
                    Image(systemName: showsSteps ? "chevron.up" : "chevron.down")
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("builder-step-menu")
            ProgressView(value: Double(currentStep.rawValue + 1), total: Double(AgentBuilderStep.allCases.count))
                .tint(IysThemePreferences.active.accent)
                .accessibilityHidden(true)
            if showsSteps {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(AgentBuilderStep.allCases) { step in
                            Button {
                                withAnimation(reduceMotion ? nil : OCMotion.smooth) {
                                    draft.currentStepIndex = step.rawValue
                                    showsSteps = false
                                }
                            } label: {
                                HStack {
                                    Label(step.title, systemImage: step.symbol)
                                    Spacer()
                                    if step == currentStep { Image(systemName: "checkmark") }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(step == currentStep ? .isSelected : [])
                            .accessibilityIdentifier("builder-step-\(step.rawValue)")
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
        .foregroundColor(OCColor.textPrimary)
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.bottom, OCSpacing.sm)
    }

    // MARK: - Step Body

    @ViewBuilder
    private var stepBody: some View {
        switch currentStep {
        case .goal:
            stepAGoalView
        case .capabilities:
            stepBCapabilitiesView
        case .customization:
            stepCCustomizationView
        case .authorizations:
            stepDAuthorizationsView
        case .liveTest:
            stepELiveTestView
        case .saveAndExport:
            stepFSaveView
        }
    }

    // MARK: - Paso A: Objetivo y Plantillas

    private var stepAGoalView: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("¿Qué quieres delegar?")
                    .font(.title2.weight(.bold))
                    .foregroundColor(OCColor.textPrimary)
                Text("Por ejemplo, revisar las ventas de tu tienda o clasificar tus documentos.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                HStack {
                    Text("Objetivo")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    Spacer()
                    DictationMicrophoneButton(targetText: draftBinding.contract.goal)
                }

                DictationLiveStatusBar()

                TextField("Describe qué resultado quieres conseguir…", text: draftBinding.contract.goal, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: 15))
                    .foregroundColor(OCColor.textPrimary)
                    .padding(12)
                    .background(OCColor.bgBase)
                    .clipShape(OCRoundedRect(OCRadius.r12))
                    .overlay(OCRoundedRect(OCRadius.r12).stroke(OCColor.borderBase, lineWidth: 1))
                    .accessibilityIdentifier("builder-goal-input")

                Button {
                    OCHaptics.light()
                    let rec = AgentTemplateCatalog.recommendTools(forGoal: draft.contract.goal)
                    draft.addTools(rec.l0, compositions: rec.l1)
                    recommendationNote = rec.explanation
                } label: {
                    Label("Añadir herramientas según el objetivo", systemImage: "sparkles")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(IysThemePreferences.active.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(OCColor.agentBuildSoft)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(OCColor.agentBuildBorder, lineWidth: 1))
                }
                .buttonStyle(OCInteractiveButtonStyle())
                .disabled(draft.contract.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let recommendationNote {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(IysThemePreferences.active.accent)
                        Text(recommendationNote)
                            .font(.system(size: 13))
                            .foregroundColor(OCColor.textSecondary)
                    }
                    .padding(10)
                    .background(OCColor.bgBase)
                    .clipShape(OCRoundedRect(OCRadius.r10))
                }
            }

            DisclosureGroup("Empezar con una plantilla", isExpanded: $showsTemplates) {
                ForEach(AgentTemplateCatalog.all) { template in templateCard(template) }
            }
            .tint(IysThemePreferences.active.accent)

        }
    }

    private func templateCard(_ template: AgentTemplate) -> some View {
        let isSelected = draft.selectedTemplateID == template.id
        let tint = Color(hex: template.accentHex)
        return Button {
            OCHaptics.selection()
            pendingTemplate = template
        } label: {
            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                HStack(spacing: OCSpacing.md) {
                    ZStack {
                        OCRoundedRect(OCRadius.r10)
                            .fill(tint.opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: template.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(tint)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(template.title)
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundColor(OCColor.textPrimary)
                            Spacer()
                            Text(template.preferredBackend.shortLabel)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.14)))
                        }
                        Text(template.subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(OCColor.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                if isSelected {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(tint)
                            Text("GUS: «\(template.gusPitch)»")
                                .font(.system(size: 12.5))
                                .foregroundColor(OCColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(OCColor.bgDeep)
                        .clipShape(OCRoundedRect(OCRadius.r8))

                        if !template.limitations.isEmpty {
                            Text("Alcance: \(template.limitations.joined(separator: " "))")
                                .font(.system(size: 11.5))
                                .foregroundColor(OCColor.textFaint)
                        }
                    }
                }
            }
            .padding(OCSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ocCard(
                radius: OCRadius.r14,
                border: isSelected ? tint.opacity(0.75) : OCColor.borderBase,
                background: isSelected ? tint.opacity(0.08) : OCColor.bgBase
            )
        }
        .buttonStyle(OCInteractiveButtonStyle())
        .accessibilityIdentifier("template-\(template.id)")
    }

    // MARK: - Paso B: Capacidades (L0 + L1)

    private var stepBCapabilitiesView: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Capacidades del agente")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .foregroundColor(OCColor.textPrimary)
                Text("Elige qué podrá hacer. Un flujo reúne varias herramientas en una secuencia que puedes revisar.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
            }

            // L1 Composite Capabilities Section
            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                HStack {
                    Text("Flujos")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    Spacer()
                    Button {
                        showLearnRecorder = true
                    } label: {
                        Label("Grabar pasos", systemImage: "record.circle")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(OCColor.danger)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showCustomL1Composer = true
                    } label: {
                        Label("Crear flujo", systemImage: "plus.circle.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(IysThemePreferences.active.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("builder-open-l1-composer")
                }

                l1CatalogCard(L1ToolDefinition.sampleCatalogImporter)

                ForEach(draft.contract.l1Tools.filter { $0.name != L1ToolDefinition.sampleCatalogImporter.name }) { customL1 in
                    l1CatalogCard(customL1)
                }
            }

            // L0 Primitives Section
            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Text("Herramientas")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)

                ForEach(Self.l0CatalogItems, id: \.id) { item in
                    l0ToggleCard(item)
                }
            }
        }
    }

    private func l1CatalogCard(_ l1: L1ToolDefinition) -> some View {
        let isEnabled = draft.contract.l1Tools.contains(where: { $0.name == l1.name })
        let effectiveCaps = DynamicToolRegistry.effectiveCapabilities(for: l1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(IysThemePreferences.active.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(l1.name)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundColor(OCColor.textPrimary)
                        Text("L1 · v\(l1.version)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(IysThemePreferences.active.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(OCColor.agentBuildSoft))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { isEnabled },
                            set: { on in
                                OCHaptics.selection()
                                if on {
                                    if !draft.contract.l1Tools.contains(where: { $0.name == l1.name }) {
                                        draft.contract.l1Tools.append(l1)
                                    }
                                    for step in l1.steps where !draft.contract.enabledL0Tools.contains(step.tool) {
                                        draft.contract.enabledL0Tools.append(step.tool)
                                    }
                                } else {
                                    draft.contract.l1Tools.removeAll { $0.name == l1.name }
                                }
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(l1.name)
                        .tint(IysThemePreferences.active.accent)
                    }

                    Text(l1.description)
                        .font(.system(size: 13))
                        .foregroundColor(OCColor.textSecondary)

                    DisclosureGroup("Ver \(l1.steps.count) pasos") {
                        VStack(alignment: .leading, spacing: OCSpacing.sm) {
                            ForEach(l1.steps.indices, id: \.self) { index in
                                let step = l1.steps[index]
                                let title = Self.l0CatalogItems.first(where: { $0.id == step.tool })?.title ?? step.tool
                                Text("\(index + 1). \(title)").font(.subheadline)
                            }
                            if !l1.parameters.isEmpty {
                                Text("Datos de entrada").font(.caption.weight(.semibold))
                                ForEach(l1.parameters, id: \.name) { parameter in
                                    Text(parameter.description).font(.caption)
                                }
                            }
                            Text(l1.outputSchema).font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline)
                    .tint(IysThemePreferences.active.accent)

                    HStack(spacing: 6) {
                        Image(systemName: effectiveCaps.isDestructive ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundColor(effectiveCaps.isDestructive ? OCColor.warning : OCColor.success)
                        Text(effectiveCaps.isDestructive ? "Hereda confirmación por escritura de sus pasos L0" : "Solo lectura y cálculo en memoria")
                            .font(.system(size: 11.5))
                            .foregroundColor(OCColor.textSecondary)
                    }
                }
            }
        }
        .padding(OCSpacing.md)
        .ocCard(radius: OCRadius.r14, border: isEnabled ? IysThemePreferences.active.accent.opacity(0.55) : OCColor.borderBase)
    }

    private struct L0CatalogItem {
        let id: String
        let title: String
        let reason: String
        let icon: String
        let badge: String
    }

    private static let l0CatalogItems: [L0CatalogItem] = [
        .init(id: "python_eval", title: "Python local (pocketpy)", reason: "Procesa CSV, JSON, tablas, fórmulas y validaciones en este iPhone con límite de tiempo.", icon: "terminal.fill", badge: "Local iPhone"),
        .init(id: "read_file", title: "Leer archivos del proyecto", reason: "Consulta documentos, listas de productos o notas de tu espacio de trabajo.", icon: "doc.text.fill", badge: "Local iPhone"),
        .init(id: "write_file", title: "Guardar archivos (con confirmación)", reason: "Escribe catálogos, reportes o páginas web tras mostrarte una vista previa.", icon: "square.and.arrow.down.fill", badge: "Pide permiso"),
        .init(id: "list_directory", title: "Explorar carpetas del proyecto", reason: "Revisa qué archivos existen en el proyecto activo.", icon: "folder.fill", badge: "Local iPhone"),
        .init(id: "http_request", title: "Consultas web HTTP/HTTPS", reason: "Conecta con APIs o descarga datos estructurados.", icon: "network", badge: "Red"),
        .init(id: "browser_navigate", title: "Navegador integrado de iSyCode", reason: "Abre y analiza páginas web sin salir de la aplicación.", icon: "safari.fill", badge: "Web integrada"),
        .init(id: "gmail.read.inbox", title: "Leer bandeja de Gmail", reason: "Revisa correos en segundo plano usando la API de Google (pide permiso la primera vez).", icon: "envelope.fill", badge: "Google"),
        .init(id: "googlecalendar.read.events", title: "Consultar Agenda de Google", reason: "Revisa tus eventos del día sin salir de iSyCode.", icon: "calendar", badge: "Google"),
        .init(id: "notifications.schedule", title: "Programar recordatorios en el iPhone", reason: "Crea alertas locales con tu confirmación.", icon: "bell.badge.fill", badge: "Pide permiso"),
        .init(id: "iphone_list_elements", title: "Consultar la pantalla del iPhone", reason: "Consulta los elementos visibles de la pantalla cuando el control del iPhone esté disponible.", icon: "iphone", badge: "WDA"),
        .init(id: "learn_action_prepare", title: "Aprender acción por demostración", reason: "Observa con WDA lo que haces en WhatsApp o Safari para enseñárselo al agente.", icon: "record.circle", badge: "WDA Polling"),
        .init(id: "secret_vault_list", title: "Llavero protegido (Face ID)", reason: "Lista únicamente aliases de contraseñas sin ver nunca su texto claro.", icon: "key.fill", badge: "Keychain"),
        .init(id: "isymcp_status", title: "Puente remoto ISyMCP (PC)", reason: "Consulta compuertas, tareas y compiladores de tu computadora por Tailscale + Face ID.", icon: "desktopcomputer", badge: "ISyMCP PC")
    ]

    private func l0ToggleCard(_ item: L0CatalogItem) -> some View {
        let requiredBy = draft.contract.l1Tools.filter { $0.steps.contains { $0.tool == item.id } }
        let isOn = draft.contract.enabledL0Tools.contains(item.id) || !requiredBy.isEmpty
        return Button {
            OCHaptics.selection()
            if isOn {
                draft.contract.enabledL0Tools.removeAll { $0 == item.id }
            } else {
                draft.contract.enabledL0Tools.append(item.id)
            }
        } label: {
            HStack(alignment: .top, spacing: OCSpacing.md) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(isOn ? IysThemePreferences.active.accent : OCColor.textFaint)
                    .padding(.top, 2)

                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(OCColor.iconPrimary)
                    .frame(width: 24)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Spacer()
                        Text(item.badge)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(OCColor.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(OCColor.bgLayer1))
                    }
                    if !requiredBy.isEmpty {
                        Text("Incluida en " + requiredBy.map(\.name).joined(separator: ", ")).font(.caption)
                    }
                    Text(item.reason)
                        .font(.system(size: 12.5))
                        .foregroundColor(OCColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(OCSpacing.md)
            .ocCard(radius: OCRadius.r12, border: isOn ? IysThemePreferences.active.accent.opacity(0.45) : OCColor.borderBase)
        }
        .buttonStyle(OCInteractiveButtonStyle())
        .disabled(!requiredBy.isEmpty)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Paso C: Personalización

    private var stepCCustomizationView: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Personalización")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .foregroundColor(OCColor.textPrimary)
                Text("Elige el nombre de tu agente, cómo quieres que te responda y dónde prefieres que ejecute sus operaciones.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Text("NOMBRE DEL AGENTE")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                TextField("Ej. Mi Creador de Tienda", text: draftBinding.contract.name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundColor(OCColor.textPrimary)
                    .padding(12)
                    .background(OCColor.bgBase)
                    .clipShape(OCRoundedRect(OCRadius.r12))
                    .overlay(OCRoundedRect(OCRadius.r12).stroke(OCColor.borderBase, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Text("COMPORTAMIENTO E INSTRUCCIONES")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                TextField("Cómo debe actuar y explicar sus resultados…", text: draftBinding.contract.systemInstructions, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: 14.5))
                    .foregroundColor(OCColor.textPrimary)
                    .padding(12)
                    .background(OCColor.bgBase)
                    .clipShape(OCRoundedRect(OCRadius.r12))
                    .overlay(OCRoundedRect(OCRadius.r12).stroke(OCColor.borderBase, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Text("Lugar de ejecución")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)

                ForEach(AgentBackendTarget.allCases) { backend in
                    let isSelected = draft.contract.preferredBackend == backend
                    Button {
                        OCHaptics.selection()
                        draft.contract.preferredBackend = backend
                    } label: {
                        HStack(spacing: OCSpacing.md) {
                            Image(systemName: backend.symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isSelected ? IysThemePreferences.active.accent : OCColor.iconPrimary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backend.title)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundColor(OCColor.textPrimary)
                                Text(backend == .remoteISyMCP
                                     ? "Para compilaciones nativas (Swift/Zig), shell real y procesos pesados en tu PC."
                                     : "Las operaciones cotidianas (CSV, JSON, archivos, web) corren directo en el iPhone sin PC.")
                                    .font(.system(size: 12))
                                    .foregroundColor(OCColor.textSecondary)
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(IysThemePreferences.active.accent)
                            }
                        }
                        .padding(OCSpacing.md)
                        .ocCard(radius: OCRadius.r12, border: isSelected ? IysThemePreferences.active.accent.opacity(0.6) : OCColor.borderBase)
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                }

                if draft.contract.preferredBackend == .remoteISyMCP && !isymcpStore.isPaired && store.sandboxLink == nil {
                    OCUnifiedStateCard(
                        kind: .offline,
                        title: "Tu computadora (ISyMCP) no está conectada aún",
                        message: "Puedes guardar este agente ahora y emparejar ISyMCP en Conexiones cuando necesites compilar o usar la terminal de tu PC. Mientras tanto, las herramientas locales de Python y archivos sí funcionarán en este iPhone.",
                        actionTitle: "Usar modo Automático (iPhone primero)",
                        actionSymbol: "iphone"
                    ) {
                        draft.contract.preferredBackend = .auto
                    }
                }
            }
        }
    }

    // MARK: - Paso D: Autorizaciones

    private var stepDAuthorizationsView: some View {
        let scopes = AgentContract.computeRequiredScopes(
            l0Tools: draft.contract.enabledL0Tools,
            l1Tools: draft.contract.l1Tools
        )
        return VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Alcance y Autorizaciones")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .foregroundColor(OCColor.textPrimary)
                Text("Revisa en lenguaje claro qué podrá hacer este agente. Las herramientas compuestas L1 heredan exactamente los permisos de sus pasos: nunca obtienen autoridad extra.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
            }

            ForEach(scopes) { scope in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: scope.requiresConfirmationPerAction ? "hand.raised.shield.fill" : "checkmark.shield.fill")
                            .font(.system(size: 17))
                            .foregroundColor(scope.requiresConfirmationPerAction ? OCColor.warning : OCColor.success)
                        Text(scope.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(OCColor.textPrimary)
                        Spacer()
                        Text(scope.requiresConfirmationPerAction ? "Pide confirmación" : "En memoria / lectura")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(scope.requiresConfirmationPerAction ? OCColor.warning : OCColor.success)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill((scope.requiresConfirmationPerAction ? OCColor.warning : OCColor.success).opacity(0.14)))
                    }

                    Text(scope.plainExplanation)
                        .font(.system(size: 13.5))
                        .foregroundColor(OCColor.textSecondary)

                    Text("Herramientas cubiertas: \(scope.sourceTools.joined(separator: ", "))")
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                }
                .padding(OCSpacing.md)
                .ocCard(radius: OCRadius.r14)
            }

            Button {
                OCHaptics.success()
                draft.contract.localApprovalGrantedAt = Date()
            } label: {
                HStack {
                    Image(systemName: draft.contract.localApprovalGrantedAt != nil ? "checkmark.seal.fill" : "shield.lefthalf.filled.badge.checkmark")
                    Text(draft.contract.localApprovalGrantedAt != nil
                         ? "Alcance revisado y aceptado en este iPhone"
                         : "Aceptar alcance de capacidades para este agente")
                        .font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundColor(OCColor.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background((draft.contract.localApprovalGrantedAt != nil ? OCColor.success : IysThemePreferences.active.accent).gradient)
                .clipShape(OCRoundedRect(OCRadius.r12))
            }
            .buttonStyle(OCInteractiveButtonStyle())
            .accessibilityIdentifier("builder-approve-scopes")
        }
    }

    // MARK: - Paso E: Prueba en vivo

    private var stepELiveTestView: some View {
        let test = draft.contract.tests.first ?? AgentTemplateCatalog.all[0].defaultTest
        return VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Prueba en workspace de prueba")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .foregroundColor(OCColor.textPrimary)
                Text("Ejecuta una tarea real de ejemplo con el motor Python local (`pocketpy` 2.2.0) antes de guardar tu agente.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: OCSpacing.md) {
                HStack {
                    Label(test.title, systemImage: "flask.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Spacer()
                    Text("Python 3 · Local")
                        .font(OCTypography.metaMono)
                        .foregroundColor(IysThemePreferences.active.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("DATOS DE PRUEBA (ENTRADA)")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    Text(test.sampleInput)
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textSecondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OCColor.bgDeep)
                        .clipShape(OCRoundedRect(OCRadius.r8))
                }

                Button {
                    runBuilderVerificationTest(test)
                } label: {
                    HStack(spacing: 8) {
                        if isRunningTest {
                            ProgressView().tint(OCColor.onAccent)
                            Text("Ejecutando prueba en este iPhone…")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Ejecutar prueba verificable ahora")
                        }
                    }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(OCColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(IysThemePreferences.active.accent.gradient)
                    .clipShape(OCRoundedRect(OCRadius.r12))
                }
                .buttonStyle(OCInteractiveButtonStyle())
                .disabled(isRunningTest)
                .accessibilityIdentifier("builder-run-test")

                if let receipt = lastTestReceipt, test.lastRunAt != nil {
                    let passed = test.lastPassed == true
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(passed ? OCColor.success : OCColor.danger)
                            Text(passed ? "Prueba superada · \(receipt.durationMs) ms" : "La prueba no obtuvo el resultado esperado")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(passed ? OCColor.success : OCColor.danger)
                            Spacer()
                            Text(receipt.runtimeVersion)
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.textFaint)
                        }

                        Text(receipt.error ?? receipt.stdout)
                            .font(OCTypography.codeSmall)
                            .foregroundColor(OCColor.textPrimary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(OCColor.bgDeep)
                            .clipShape(OCRoundedRect(OCRadius.r8))
                    }
                    .padding(OCSpacing.md)
                    .background((passed ? OCColor.success : OCColor.danger).opacity(0.10))
                    .clipShape(OCRoundedRect(OCRadius.r12))
                }
            }
            .padding(OCSpacing.lg)
            .ocCard(radius: OCRadius.r14)
        }
    }

    private func runBuilderVerificationTest(_ test: AgentContractTest) {
        guard !isRunningTest else { return }
        isRunningTest = true
        let contractID = draft.contract.id
        let script = test.pythonVerificationScript ?? "print(INPUT_TEXT)"
        Task {
            let receipt = await PythonRuntimeService.shared.evaluate(
                script: script,
                inputText: test.sampleInput,
                timeoutMs: 3000
            )
            await MainActor.run {
                isRunningTest = false
                guard draft.contract.id == contractID else { return }
                lastTestReceipt = receipt
                let passed = receipt.succeeded && receipt.stdout.contains(test.expectedSubstring)
                if passed {
                    OCHaptics.success()
                } else {
                    OCHaptics.error()
                }
                var updatedTest = test
                updatedTest.lastRunAt = Date()
                updatedTest.lastPassed = passed
                updatedTest.lastOutput = receipt.stdout
                if let index = draft.contract.tests.firstIndex(where: { $0.id == test.id }) {
                    draft.contract.tests[index] = updatedTest
                } else if draft.contract.tests.isEmpty {
                    draft.contract.tests.append(updatedTest)
                }
            }
        }
    }

    // MARK: - Paso F: Guardar y Exportar Contrato

    private var stepFSaveView: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Guardar y usar tu agente")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .foregroundColor(OCColor.textPrimary)
                Text("Tu agente queda guardado como un contrato de capacidades (`.isyagent.json`), listo para conversar, reutilizar sus herramientas L1 o exportarlo.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: OCSpacing.md) {
                HStack(spacing: 12) {
                    ZStack {
                        OCRoundedRect(OCRadius.r12)
                            .fill(Color(hex: draft.contract.accentHex).opacity(0.18))
                            .frame(width: 48, height: 48)
                        Image(systemName: draft.contract.icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(hex: draft.contract.accentHex))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.contract.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Esquema v\(draft.contract.schemaVersion) · \(draft.contract.enabledL0Tools.count) L0 · \(draft.contract.l1Tools.count) L1")
                            .font(OCTypography.metaMono)
                            .foregroundColor(OCColor.textSecondary)
                    }
                }

                Text(draft.contract.goal)
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)

                if draft.contract.localApprovalGrantedAt == nil {
                    Button {
                        draft.currentStepIndex = AgentBuilderStep.authorizations.rawValue
                    } label: {
                        Label("Revisar permisos antes de guardar", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("builder-review-permissions")
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            let reviewed = draft.contract
                            guard reviewed.localApprovalGrantedAt != nil,
                                  await contractStore.saveAgent(reviewed, registerL1Tools: true) else { return }
                            OCHaptics.success()
                            savedBannerText = "Agente '\(reviewed.name)' guardado en Mis agentes."
                        }
                    } label: {
                        Label("Guardar en Mis agentes", systemImage: "tray.and.arrow.down.fill")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(OCColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(IysThemePreferences.active.accent.gradient)
                            .clipShape(OCRoundedRect(OCRadius.r12))
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                    .accessibilityIdentifier("builder-save-agent")

                    Button {
                        Task {
                            let reviewed = draft.contract
                            guard reviewed.localApprovalGrantedAt != nil,
                                  await contractStore.saveAgent(reviewed, registerL1Tools: true) else { return }
                            contractStore.activeAgentForSession = reviewed
                            if await store.openOrCreateConversation(preferNew: true) { router.openConversations() }
                        }
                    } label: {
                        Label("Probar en Chat", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(OCColor.bgLayer1)
                            .clipShape(OCRoundedRect(OCRadius.r12))
                            .overlay(OCRoundedRect(OCRadius.r12).stroke(OCColor.borderBase, lineWidth: 1))
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                }
                .disabled(draft.contract.localApprovalGrantedAt == nil)

                if let error = contractStore.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundColor(OCColor.danger)
                }

                Button {
                    showExportSheet = true
                } label: {
                    Label("Inspeccionar o exportar contrato (.isyagent.json)", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(IysThemePreferences.active.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(OCColor.agentBuildSoft)
                        .clipShape(OCRoundedRect(OCRadius.r10))
                }
                .buttonStyle(OCInteractiveButtonStyle())
            }
            .padding(OCSpacing.lg)
            .ocCard(radius: OCRadius.r14)
        }
    }

    // MARK: - Footer Navigation Bar

    private var navigationFooterBar: some View {
        HStack(spacing: OCSpacing.md) {
            if currentStep.rawValue > 0 {
                Button {
                    OCHaptics.light()
                    withAnimation(reduceMotion ? nil : OCMotion.smooth) {
                        draft.currentStepIndex -= 1
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Anterior")
                    }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(OCColor.bgLayer1)
                    .clipShape(OCRoundedRect(OCRadius.r12))
                }
                .buttonStyle(OCInteractiveButtonStyle())
            }

            Spacer()



            if currentStep.rawValue < AgentBuilderStep.allCases.count - 1 {
                Button {
                    OCHaptics.light()
                    withAnimation(reduceMotion ? nil : OCMotion.smooth) {
                        draft.currentStepIndex += 1
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Siguiente")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent.gradient)
                    .clipShape(OCRoundedRect(OCRadius.r12))
                }
                .buttonStyle(OCInteractiveButtonStyle())
                .accessibilityIdentifier("builder-next-step")
            }
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.vertical, 10)
        .background(OCColor.bgBase)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(OCColor.borderMuted), alignment: .top)
    }
}

// MARK: - Custom L1 Composer Sheet (Scenario B: Developer Workflow)

private struct CustomL1ToolComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (L1ToolDefinition) -> Void

    @State private var name = "l1_procesar_datos"
    @State private var description = "Procesa texto con Python local y guarda el resultado."
    @State private var pythonScript = "rows = csv.parse(INPUT_TEXT)\nprint(json.dumps({'filas': len(rows), 'datos': rows}))"
    @State private var includeWriteStep = true
    @State private var outputPath = "resultado_l1.json"
    @State private var errorMessage: String?

    private var previewDefinition: L1ToolDefinition {
        var steps: [L1ToolDefinition.Step] = [
            .init(tool: "python_eval", args: ["input_text": "{{entrada}}", "script": pythonScript])
        ]
        if includeWriteStep {
            steps.append(.init(tool: "write_file", args: ["path": outputPath, "content": "{{prev_output}}"]))
        }
        return L1ToolDefinition(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: [.init(name: "entrada", type: "string", description: "Datos de entrada CSV o JSON", required: true)],
            steps: steps,
            provenance: "user"
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identidad de la capacidad L1") {
                    TextField("Nombre snake_case (ej. l1_procesar_datos)", text: $name)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Descripción", text: $description, axis: .vertical)
                }

                Section("Paso 1 · Python local (python_eval)") {
                    TextField("Script Python 3", text: $pythonScript, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(4...10)
                }

                Section("Paso 2 · Guardar en workspace (opcional)") {
                    Toggle("Guardar salida con write_file", isOn: $includeWriteStep)
                    if includeWriteStep {
                        TextField("Ruta de salida", text: $outputPath)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                Section("Herencia estricta de permisos (calculada)") {
                    let caps = DynamicToolRegistry.effectiveCapabilities(for: previewDefinition)
                    LabeledContent("Requiere confirmación por escritura", value: caps.isDestructive ? "Sí (heredado de write_file)" : "No")
                    LabeledContent("Requiere red", value: caps.requiresNetwork ? "Sí" : "No")
                    if let reason = caps.approvalReason {
                        Text(reason)
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.warning)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(OCColor.danger)
                    }
                }
            }
            .navigationTitle("Componer herramienta L1")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Registrar L1") {
                        let def = previewDefinition
                        Task {
                            do {
                                try await DynamicToolRegistry.shared.upsert(def)
                                await MainActor.run {
                                    onSave(def)
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Mis Agentes View & .isyagent.json Inspector / Importer

public struct MyAgentsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var contractStore = AgentContractStore.shared
    @ObservedObject private var isymcpStore = ISyMCPStore.shared

    @State private var reviewContract: AgentContract?
    @State private var inspectingContract: AgentContract?
    @State private var showImportSheet = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OCSpacing.lg) {
                headerBanner

                if contractStore.agents.isEmpty {
                    OCUnifiedStateCard(
                        kind: .empty,
                        title: "Aún no tienes agentes guardados",
                        message: "Usa el Constructor para crear un agente con capacidades reales (como importar un catálogo CSV o investigar en la web) o importa un contrato .isyagent.json.",
                        actionTitle: "Construir mi primer agente",
                        actionSymbol: "hammer.fill"
                    ) {
                        router.openBuilder()
                    }
                } else {
                    ForEach(contractStore.agents) { agent in
                        agentCard(agent)
                    }
                }
            }
            .padding(OCSpacing.contentMargin)
            .padding(.bottom, 76)
        }
        .refreshable {
            await contractStore.refresh()
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("Mis agentes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Importar contrato .isyagent.json")

                    Button {
                        router.openBuilder()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Crear nuevo agente")
                }
            }
        }
        .alert(item: $reviewContract) { agent in
            let scopes = AgentContract.computeRequiredScopes(l0Tools: agent.enabledL0Tools, l1Tools: agent.l1Tools)
            return Alert(title: Text("Permisos de \(agent.name)"),
                         message: Text(scopes.map { $0.title + " · " + $0.plainExplanation }.joined(separator: "\n\n")),
                         primaryButton: .default(Text("Aceptar alcance")) {
                             var approved = agent
                             approved.localApprovalGrantedAt = Date()
                             Task { await contractStore.saveAgent(approved) }
                         }, secondaryButton: .cancel(Text("Volver")))
        }
        .sheet(item: $inspectingContract) { contract in
            AgentContractInspectorSheet(contract: contract)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportAgentContractSheet()
        }
    }

    private var headerBanner: some View {
        HStack(spacing: OCSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elige con quién trabajar")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(OCColor.textPrimary)
                Text("Puedes abrir una conversación, revisar sus permisos o ajustar sus herramientas.")
                    .font(.system(size: 13))
                    .foregroundColor(OCColor.textSecondary)
            }
            Spacer()
        }
    }

    private func agentCard(_ agent: AgentContract) -> some View {
        let tint = Color(hex: agent.accentHex)
        let compat = contractStore.evaluateCompatibility(
            for: agent,
            googleConnected: assistant.googleConnectionState.isAuthorizedSession,
            isymcpPaired: isymcpStore.isPaired
        )
        return VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    OCRoundedRect(OCRadius.r12)
                        .fill(tint.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: agent.icon)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(agent.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(OCColor.textPrimary)
                        Spacer()
                        Text(agent.preferredBackend.shortLabel)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.14)))
                    }

                    Text(agent.goal)
                        .font(.system(size: 13.5))
                        .foregroundColor(OCColor.textSecondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Label("\(agent.enabledL0Tools.count) L0", systemImage: "wrench.fill")
                        if !agent.l1Tools.isEmpty {
                            Label("\(agent.l1Tools.count) L1", systemImage: "square.stack.3d.up.fill")
                        }
                        if agent.enabledL0Tools.contains("python_eval") {
                            Label("Python", systemImage: "terminal.fill")
                        }
                    }
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
                    .padding(.top, 2)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: compat.requiresUserAuthorization ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundColor(compat.requiresUserAuthorization ? OCColor.warning : OCColor.success)
                Text(compat.summary)
                    .font(.system(size: 12))
                    .foregroundColor(OCColor.textSecondary)
            }

            HStack(spacing: 8) {
                Button {
                    OCHaptics.light()
                    if compat.requiresUserAuthorization {
                        reviewContract = agent
                        return
                    }
                    contractStore.activeAgentForSession = agent
                    Task {
                        if await store.openOrCreateConversation(preferNew: true) { router.openConversations() }
                    }
                } label: {
                    Label(compat.requiresUserAuthorization ? "Revisar permisos" : "Conversar con agente", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OCColor.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(tint.gradient)
                        .clipShape(Capsule())
                }
                .buttonStyle(OCInteractiveButtonStyle())

                Button {
                    inspectingContract = agent
                } label: {
                    Label("Contrato", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OCColor.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(OCColor.bgLayer1)
                        .clipShape(Capsule())
                }
                .buttonStyle(OCInteractiveButtonStyle())

                Button {
                    contractStore.saveDraft(AgentBuilderDraft(
                        currentStepIndex: 1,
                        selectedTemplateID: agent.category,
                        contract: agent
                    ))
                    router.openBuilder()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OCColor.textSecondary)
                        .frame(width: 36, height: 34)
                        .background(OCColor.bgLayer1)
                        .clipShape(Circle())
                }
                .buttonStyle(OCInteractiveButtonStyle())
                .accessibilityLabel("Editar en Constructor")

                Spacer()
            }
        }
        .padding(OCSpacing.lg)
        .ocCard(radius: OCRadius.r14)
    }
}

public struct AgentContractInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contract: AgentContract
    @State private var copied = false

    public init(contract: AgentContract) {
        self.contract = contract
    }

    private var exportedJSON: String {
        (try? contract.exportSanitizedJSON()) ?? "{}"
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contract.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Contrato exportable `.isyagent.json` (v\(contract.schemaVersion)). Inspección segura sin ejecutar código. Los permisos aprobados nunca se transfieren al exportar.")
                            .font(.system(size: 13))
                            .foregroundColor(OCColor.textSecondary)
                    }

                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = exportedJSON
                        #endif
                        OCHaptics.success()
                        copied = true
                    } label: {
                        Label(copied ? "Contrato .isyagent.json copiado" : "Copiar .isyagent.json", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OCColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(IysThemePreferences.active.accent.gradient)
                            .clipShape(OCRoundedRect(OCRadius.r12))
                    }
                    .buttonStyle(OCInteractiveButtonStyle())

                    Text(exportedJSON)
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OCColor.bgBase)
                        .clipShape(OCRoundedRect(OCRadius.r12))
                        .overlay(OCRoundedRect(OCRadius.r12).stroke(OCColor.borderBase, lineWidth: 1))
                }
                .padding(OCSpacing.contentMargin)
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("Contrato .isyagent.json")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
}

private struct ImportAgentContractSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var contractStore = AgentContractStore.shared
    @State private var rawJSON = ""
    @State private var parsedPreview: AgentContract?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pega un contrato .isyagent.json") {
                    TextField("{ \"schemaVersion\": \"1.0\", ... }", text: $rawJSON, axis: .vertical)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(6...14)

                    Button("Inspeccionar sin ejecutar código") {
                        do {
                            parsedPreview = try AgentContract.importFromJSON(rawJSON)
                            errorMessage = nil
                        } catch {
                            parsedPreview = nil
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let preview = parsedPreview {
                    Section("Inspección previa de seguridad") {
                        LabeledContent("Nombre", value: preview.name)
                        LabeledContent("Herramientas L0", value: preview.enabledL0Tools.joined(separator: ", "))
                        LabeledContent("Herramientas L1", value: preview.l1Tools.isEmpty ? "Ninguna" : preview.l1Tools.map(\.name).joined(separator: ", "))
                        LabeledContent("Permisos transferidos", value: "Ninguno (requiere tu autorización en este iPhone)")

                        Button("Autorizar alcance e importar a Mis agentes") {
                            var approved = preview
                            approved.localApprovalGrantedAt = Date()
                            Task {
                                if await contractStore.saveAgent(approved, registerL1Tools: true) { dismiss() }
                                else { errorMessage = contractStore.lastError }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(OCColor.danger)
                    }
                }
            }
            .navigationTitle("Importar .isyagent.json")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
