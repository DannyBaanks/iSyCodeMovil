import SwiftUI

// MARK: - Action Recorder Sheet ("Aprender acción")

public struct LearnActionRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var recorder = ActionRecorderService.shared
    @ObservedObject private var vault = SecretVaultStore.shared

    public var onCompiledTool: ((L1ToolDefinition) -> Void)?

    @State private var goalTitle: String = ""
    @State private var goalDescription: String = ""
    @State private var paramInput: String = ""
    @State private var parameters: [String] = []
    @State private var selectedSecretAliases: Set<String> = []
    @State private var compileName: String = ""
    @State private var compileDescription: String = ""
    @State private var showVaultSheet = false
    @State private var showAddStepSheet = false
    @State private var compileMessage: String?
    @State private var pulseAnimate = false

    public init(onCompiledTool: ((L1ToolDefinition) -> Void)? = nil) {
        self.onCompiledTool = onCompiledTool
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.lg) {
                    switch recorder.status {
                    case .idle, .prepared:
                        setupPhaseView
                    case .recording(let elapsed, let samples, let currentApp, let stepsCount):
                        recordingPhaseView(elapsed: elapsed, samples: samples, currentApp: currentApp, stepsCount: stepsCount)
                    case .reviewReady:
                        reviewAndCompileView
                    case .wdaUnavailable(let reason):
                        wdaUnavailableView(reason)
                    case .error(let msg):
                        OCUnifiedStateCard(
                            kind: .error,
                            title: "No se pudo completar la grabación",
                            message: msg,
                            actionTitle: "Volver a intentar"
                        ) {
                            Task { await recorder.startRecording() }
                        }
                    }

                    if let compileMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(OCColor.success)
                            Text(compileMessage)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(OCColor.textPrimary)
                        }
                        .padding(OCSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ocCard(radius: OCRadius.r12, border: OCColor.success.opacity(0.45), background: OCColor.bgBase)
                    }
                }
                .padding(OCSpacing.contentMargin)
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("Aprender acción")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showVaultSheet = true
                    } label: {
                        Label("Llavero", systemImage: "key.fill")
                    }
                }
            }
            .sheet(isPresented: $showVaultSheet) {
                SecretVaultSheet()
            }
            .sheet(isPresented: $showAddStepSheet) {
                AddRecordedStepSheet { step in
                    if var session = recorder.draftSession {
                        session.steps.append(step)
                        recorder.draftSession = session
                    }
                }
            }
            .onAppear {
                hydrateFromDraft()
            }
        }
    }

    private func hydrateFromDraft() {
        if let draft = recorder.draftSession {
            if goalTitle.isEmpty { goalTitle = draft.goalTitle }
            if goalDescription.isEmpty { goalDescription = draft.goalDescription }
            if parameters.isEmpty { parameters = draft.expectedParameters }
            if selectedSecretAliases.isEmpty { selectedSecretAliases = Set(draft.linkedSecretAliases) }
            if compileName.isEmpty { compileName = draft.targetToolName }
            if compileDescription.isEmpty { compileDescription = draft.goalDescription.isEmpty ? draft.goalTitle : draft.goalDescription }
        }
    }

    // MARK: - Step 1: Prepare Flow

    private var setupPhaseView: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Enséñale un flujo real haciéndolo tú", systemImage: "record.circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(OCColor.textPrimary)
                Text("ISyCode permanece activo en segundo plano consultando WebDriverAgent mientras sales a WhatsApp, Safari o cualquier app. Al volver, convierte tus pasos en una herramienta L1 con parámetros y llaves seguras.")
                    .font(.system(size: 13))
                    .foregroundColor(OCColor.textSecondary)
            }
            .padding(OCSpacing.md)
            .ocCard(radius: OCRadius.r14, border: IysThemePreferences.active.accent.opacity(0.28), background: OCColor.bgBase)

            VStack(alignment: .leading, spacing: 8) {
                Text("EJEMPLOS RÁPIDOS")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        presetChip("WhatsApp · Enviar mensaje") {
                            goalTitle = "Enviar mensaje por WhatsApp"
                            goalDescription = "Abre WhatsApp, busca un contacto, escribe un mensaje y pulsa enviar."
                            parameters = ["contacto", "mensaje"]
                            selectedSecretAliases = []
                        }
                        presetChip("FEL.mx · Hacer factura") {
                            goalTitle = "Facturar en FEL.mx"
                            goalDescription = "Abre Safari en fel.mx, inicia sesión con el Llavero y genera una factura con NIT, concepto y monto."
                            parameters = ["nit_cliente", "concepto", "monto"]
                            selectedSecretAliases.insert("fel_mx")
                        }
                        presetChip("Portal web · Consulta") {
                            goalTitle = "Consultar portal web"
                            goalDescription = "Abre Safari, autentícate con una llave del Llavero y revisa la información solicitada."
                            parameters = ["consulta"]
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("1. ¿QUÉ QUIERES AUTOMATIZAR?")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)

                TextField("Ej. Enviar mensaje por WhatsApp o Facturar en FEL.mx", text: $goalTitle)
                    .textFieldStyle(.roundedBorder)

                TextField("Describe qué debe hacer (pasos clave)", text: $goalDescription, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(OCSpacing.md)
            .ocCard(radius: OCRadius.r14, border: OCColor.borderMuted, background: OCColor.bgBase)

            VStack(alignment: .leading, spacing: 10) {
                Text("2. DATOS VARIABLES EN CADA USO ({{param}})")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                Text("Lo que escribas en pantalla que coincida con estos datos se volverá reutilizable (por ejemplo `contacto`, `mensaje`, `nit`).")
                    .font(.system(size: 12))
                    .foregroundColor(OCColor.textSecondary)

                HStack(spacing: 8) {
                    TextField("Nuevo parámetro (ej. contacto)", text: $paramInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Agregar") {
                        let clean = paramInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_")
                        if !clean.isEmpty && !parameters.contains(clean) {
                            parameters.append(clean)
                            OCHaptics.light()
                        }
                        paramInput = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(paramInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !parameters.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(parameters, id: \.self) { param in
                                HStack(spacing: 4) {
                                    Text("{{\(param)}}")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Button {
                                        parameters.removeAll { $0 == param }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(OCColor.info.opacity(0.14)))
                                .foregroundColor(OCColor.info)
                            }
                        }
                    }
                }
            }
            .padding(OCSpacing.md)
            .ocCard(radius: OCRadius.r14, border: OCColor.borderMuted, background: OCColor.bgBase)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("3. LLAVERO DE CONTRASEÑAS (OPCIONAL)")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    Spacer()
                    Button {
                        showVaultSheet = true
                    } label: {
                        Label("Nueva llave", systemImage: "plus.circle")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }

                Text("Si iniciarás sesión en un portal como FEL.mx, vincula aquí tu llave. Las contraseñas jamás salen del Keychain hacia el modelo de IA.")
                    .font(.system(size: 12))
                    .foregroundColor(OCColor.textSecondary)

                if vault.entries.isEmpty {
                    Button {
                        showVaultSheet = true
                    } label: {
                        Label("Configurar una credencial en el Llavero", systemImage: "key.viewfinder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                } else {
                    ForEach(vault.entries) { entry in
                        let isSelected = selectedSecretAliases.contains(entry.alias)
                        Button {
                            OCHaptics.selection()
                            if isSelected {
                                selectedSecretAliases.remove(entry.alias)
                            } else {
                                selectedSecretAliases.insert(entry.alias)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? IysThemePreferences.active.accent : OCColor.textFaint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundColor(OCColor.textPrimary)
                                    Text("{{secret:\(entry.alias)}} · \(entry.serviceDomain.isEmpty ? "Keychain" : entry.serviceDomain)")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(OCColor.textSecondary)
                                }
                                Spacer()
                                if entry.requireFaceID {
                                    Image(systemName: "faceid")
                                        .foregroundColor(OCColor.success)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(OCSpacing.md)
            .ocCard(radius: OCRadius.r14, border: OCColor.borderMuted, background: OCColor.bgBase)

            VStack(spacing: 10) {
                Button {
                    OCHaptics.medium()
                    syncDraftAndStart()
                } label: {
                    HStack {
                        Image(systemName: "record.circle.fill")
                        Text("Iniciar polling WDA y salir de ISyCode")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(IysThemePreferences.active.accent)

                Button {
                    recorder.prepareSession(
                        goalTitle: goalTitle,
                        goalDescription: goalDescription,
                        parameters: parameters,
                        linkedSecretAliases: Array(selectedSecretAliases)
                    )
                    recorder.enterManualComposer()
                    hydrateFromDraft()
                } label: {
                    Label("Definir pasos manualmente (sin esperar WDA)", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func presetChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            OCHaptics.light()
            action()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OCColor.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(OCColor.bgLayer1))
                .overlay(Capsule().stroke(OCColor.borderMuted, lineWidth: 1))
        }
        .buttonStyle(OCInteractiveButtonStyle())
    }

    private func syncDraftAndStart() {
        recorder.prepareSession(
            goalTitle: goalTitle.isEmpty ? "Acción aprendida" : goalTitle,
            goalDescription: goalDescription,
            parameters: parameters,
            linkedSecretAliases: Array(selectedSecretAliases)
        )
        Task {
            await recorder.startRecording()
            hydrateFromDraft()
        }
    }

    // MARK: - Step 2: Live Polling View

    private func recordingPhaseView(elapsed: Int, samples: Int, currentApp: String, stepsCount: Int) -> some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(OCColor.danger.opacity(0.22))
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulseAnimate && !reduceMotion ? 1.15 : 0.95)
                    Circle()
                        .fill(OCColor.danger)
                        .frame(width: 16, height: 16)
                }
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulseAnimate = true
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Observando en segundo plano (\(elapsed)s)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Text("App al frente: \(currentApp) · \(samples) muestras · \(stepsCount) pasos")
                        .font(.system(size: 12.5))
                        .foregroundColor(OCColor.textSecondary)
                }
                Spacer()
            }
            .padding(OCSpacing.md)
            .ocCard(radius: OCRadius.r14, border: OCColor.danger.opacity(0.4), background: OCColor.bgBase)

            Text("Sal ahora de ISyCode hacia WhatsApp o Safari y realiza la tarea normalmente. Cuando aparezca un campo de contraseña no leeremos tu clave: luego la vincularás a tu Llavero. Al terminar, regresa aquí y pulsa Detener.")
                .font(.system(size: 13.5))
                .foregroundColor(OCColor.textSecondary)

            if let steps = recorder.draftSession?.steps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PASOS DETECTADOS EN VIVO")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    ForEach(steps.suffix(6)) { step in
                        HStack(spacing: 10) {
                            Image(systemName: step.kind.icon)
                                .foregroundColor(step.kind == .secureField ? OCColor.warning : IysThemePreferences.active.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.elementSummary)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(OCColor.textPrimary)
                                Text("\(step.appDisplayName) · \(step.suggestedTool)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(OCColor.textFaint)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .ocCard(radius: OCRadius.r10, border: OCColor.borderMuted, background: OCColor.bgBase)
                    }
                }
            }

            Button {
                OCHaptics.success()
                recorder.stopRecording()
                hydrateFromDraft()
            } label: {
                Label("Detener grabación y revisar pasos", systemImage: "stop.circle.fill")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(OCColor.success)
        }
    }

    private func wdaUnavailableView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            OCUnifiedStateCard(
                kind: .offline,
                title: "WebDriverAgent no respondió en este momento",
                message: reason,
                technicalDetail: "Endpoint esperado: http://127.0.0.1:8100/status (requiere WDA activo por LocalDevVPN o puente USB).",
                actionTitle: "Reintentar WDA"
            ) {
                Task { await recorder.startRecording() }
            }

            HStack(spacing: 10) {
                Button("Ir a Conexiones") {
                    dismiss()
                    router.openConnections()
                }
                .buttonStyle(.bordered)

                Button("Definir pasos manualmente") {
                    recorder.enterManualComposer()
                    hydrateFromDraft()
                }
                .buttonStyle(.borderedProminent)
                .tint(IysThemePreferences.active.accent)
            }
        }
    }

    // MARK: - Step 3: Review, Bind Parameters/Secrets & Compile to L1

    private var reviewAndCompileView: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            if let session = recorder.draftSession {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flujo capturado: \(session.goalTitle)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Text("\(session.steps.count) paso(s) · \(session.wdaConnectedDuringSession ? "Grabado por WDA (\(session.sampleCount) muestras)" : "Editor manual")")
                        .font(.system(size: 12.5))
                        .foregroundColor(OCColor.textSecondary)
                }

                HStack {
                    Text("PASOS DE LA AUTOMATIZACIÓN")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    Spacer()
                    Button {
                        showAddStepSheet = true
                    } label: {
                        Label("Agregar paso", systemImage: "plus.circle")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }

                if session.steps.isEmpty {
                    OCUnifiedStateCard(
                        kind: .empty,
                        title: "No se detectaron cambios en pantalla",
                        message: "Puedes volver a grabar o añadir manualmente los pasos (abrir app, esperar pantalla, tocar elemento, escribir texto o secreto del Llavero).",
                        actionTitle: "Volver a grabar"
                    ) {
                        Task { await recorder.startRecording() }
                    }
                } else {
                    ForEach(session.steps.indices, id: \.self) { idx in
                        stepEditorCard(index: idx)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("GUARDAR COMO HERRAMIENTA L1")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)

                    TextField("Nombre técnico (ej. l1_enviar_whatsapp)", text: $compileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13.5, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    TextField("Descripción para el agente", text: $compileDescription, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        compileNow(session: session)
                    } label: {
                        Label("Guardar herramienta y enseñársela al agente", systemImage: "checkmark.shield.fill")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(IysThemePreferences.active.accent)
                    .disabled(session.steps.filter(\.included).isEmpty)
                }
                .padding(OCSpacing.md)
                .ocCard(radius: OCRadius.r14, border: OCColor.borderMuted, background: OCColor.bgBase)
            }
        }
    }

    private func stepEditorCard(index: Int) -> some View {
        let stepBinding = Binding<RecordedWorkflowStep>(
            get: {
                recorder.draftSession?.steps[index] ?? RecordedWorkflowStep(
                    bundleID: "",
                    appDisplayName: "",
                    kind: .tapElement,
                    suggestedTool: "iphone_tap_element",
                    suggestedArgs: [:],
                    elementSummary: ""
                )
            },
            set: { updated in
                recorder.draftSession?.steps[index] = updated
            }
        )
        let step = stepBinding.wrappedValue

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: stepBinding.included)
                    .labelsHidden()
                Image(systemName: step.kind.icon)
                    .foregroundColor(step.kind == .secureField ? OCColor.warning : IysThemePreferences.active.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(step.kind.displayTitle)")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(step.elementSummary)
                        .font(.system(size: 12))
                        .foregroundColor(OCColor.textSecondary)
                }
                Spacer()
            }

            if step.kind == .typeText {
                HStack(spacing: 8) {
                    Text("Variable:")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(OCColor.textFaint)
                    Menu {
                        Button("Texto literal capturado") {
                            stepBinding.wrappedValue.parameterName = nil
                            stepBinding.wrappedValue.secretAlias = nil
                        }
                        ForEach(parameters, id: \.self) { param in
                            Button("Usar parámetro {{\(param)}}") {
                                stepBinding.wrappedValue.secretAlias = nil
                                stepBinding.wrappedValue.parameterName = param
                            }
                        }
                        ForEach(vault.entries) { entry in
                            Button("Usuario del Llavero: {{secret:\(entry.alias).username}}") {
                                stepBinding.wrappedValue.parameterName = nil
                                stepBinding.wrappedValue.secretAlias = entry.alias
                                stepBinding.wrappedValue.secretField = .username
                            }
                        }
                    } label: {
                        Text(step.secretAlias.map { "{{secret:\($0).\(step.secretField.rawValue)}}" }
                             ?? step.parameterName.map { "{{\($0)}}" }
                             ?? (step.suggestedArgs["text"] ?? "Texto fijo"))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(OCColor.bgLayer1))
                    }
                }
            } else if step.kind == .secureField {
                HStack(spacing: 8) {
                    Text("Llavero:")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(OCColor.warning)
                    Menu {
                        ForEach(vault.entries) { entry in
                            Button("\(entry.label) ({{secret:\(entry.alias).password}})") {
                                stepBinding.wrappedValue.secretAlias = entry.alias
                                stepBinding.wrappedValue.secretField = .password
                            }
                        }
                        Button("+ Crear nueva credencial en Llavero") {
                            showVaultSheet = true
                        }
                    } label: {
                        Text(step.secretAlias.map { "{{secret:\($0).password}}" } ?? "Elige credencial del Llavero")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(OCColor.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(OCColor.warning.opacity(0.14)))
                    }
                }
            }
        }
        .padding(OCSpacing.md)
        .ocCard(radius: OCRadius.r12, border: OCColor.borderMuted, background: OCColor.bgBase)
        .opacity(step.included ? 1.0 : 0.52)
    }

    private func compileNow(session: RecordedWorkflowSession) {
        let finalName = compileName.isEmpty ? session.targetToolName : compileName
        let finalDesc = compileDescription.isEmpty ? session.goalTitle : compileDescription
        Task {
            do {
                let compiled = try await recorder.saveAndRegisterCompiledTool(
                    session: session,
                    customName: finalName,
                    description: finalDesc
                )
                onCompiledTool?(compiled)
                if var draft = AgentContractStore.shared.activeDraft {
                    if !draft.contract.l1Tools.contains(where: { $0.name == compiled.name }) {
                        draft.contract.l1Tools.append(compiled)
                    }
                    for s in compiled.steps where !draft.contract.enabledL0Tools.contains(s.tool) {
                        draft.contract.enabledL0Tools.append(s.tool)
                    }
                    for alias in compiled.requiredSecrets where !draft.contract.requiredSecrets.contains(alias) {
                        draft.contract.requiredSecrets.append(alias)
                    }
                    AgentContractStore.shared.saveDraft(draft)
                }
                OCHaptics.success()
                compileMessage = "Herramienta '\(compiled.name)' registrada y lista para que el agente la use."
            } catch {
                compileMessage = "No se pudo guardar la herramienta: \(error.localizedDescription)"
            }
        }
    }
}

private struct AddRecordedStepSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (RecordedWorkflowStep) -> Void

    @State private var selectedKind: RecordedWorkflowStepKind = .tapElement
    @State private var primaryValue: String = ""
    @State private var parameterName: String = ""
    @State private var secretAlias: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo de paso") {
                    Picker("Acción", selection: $selectedKind) {
                        ForEach(RecordedWorkflowStepKind.allCases, id: \.self) { kind in
                            Text(kind.displayTitle).tag(kind)
                        }
                    }
                }
                Section("Detalle") {
                    switch selectedKind {
                    case .launchApp:
                        TextField("Bundle ID (ej. net.whatsapp.WhatsApp)", text: $primaryValue)
                            .textInputAutocapitalization(.never)
                    case .waitForScreen:
                        TextField("Texto visible a esperar", text: $primaryValue)
                    case .tapElement:
                        TextField("Etiqueta o botón a tocar (ej. Enviar)", text: $primaryValue)
                    case .typeText:
                        TextField("Texto fijo o deja vacío si usas parámetro", text: $primaryValue)
                        TextField("Nombre de parámetro opcional (ej. mensaje)", text: $parameterName)
                            .textInputAutocapitalization(.never)
                    case .secureField:
                        TextField("Alias del Llavero (ej. fel_mx)", text: $secretAlias)
                            .textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle("Agregar paso manual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Añadir") {
                        onAdd(buildStep())
                        dismiss()
                    }
                }
            }
        }
    }

    private func buildStep() -> RecordedWorkflowStep {
        switch selectedKind {
        case .launchApp:
            let b = primaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return RecordedWorkflowStep(bundleID: b, appDisplayName: ActionRecorderDiffEngine.appDisplayName(for: b), kind: .launchApp, suggestedTool: "iphone_launch_app", suggestedArgs: ["bundle_id": b], elementSummary: "Abrir \(b)")
        case .waitForScreen:
            return RecordedWorkflowStep(bundleID: "", appDisplayName: "Manual", kind: .waitForScreen, suggestedTool: "iphone_wait_for", suggestedArgs: ["text": primaryValue, "timeout": "8"], elementSummary: "Esperar '\(primaryValue)'")
        case .tapElement:
            return RecordedWorkflowStep(bundleID: "", appDisplayName: "Manual", kind: .tapElement, suggestedTool: "iphone_tap_element", suggestedArgs: ["text": primaryValue], elementSummary: "Tocar '\(primaryValue)'")
        case .typeText:
            let param = parameterName.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = param.isEmpty ? primaryValue : "{{\(param)}}"
            return RecordedWorkflowStep(bundleID: "", appDisplayName: "Manual", kind: .typeText, suggestedTool: "iphone_type_text", suggestedArgs: ["text": val, "submit": "false"], elementSummary: "Escribir \(val)", parameterName: param.isEmpty ? nil : param)
        case .secureField:
            let alias = SecretVaultEntryMetadata.normalizeAlias(secretAlias)
            return RecordedWorkflowStep(bundleID: "", appDisplayName: "Llavero", kind: .secureField, suggestedTool: "iphone_type_text", suggestedArgs: ["text": "{{secret:\(alias).password}}", "submit": "true"], elementSummary: "Inyectar contraseña protegida ({{secret:\(alias)}})", secretAlias: alias, secretField: .password)
        }
    }
}

// MARK: - Secret Vault Sheet ("Sistema de Llavero")

public struct SecretVaultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vault = SecretVaultStore.shared

    @State private var alias: String = ""
    @State private var label: String = ""
    @State private var domain: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var requireFaceID: Bool = true
    @State private var feedback: String?
    @State private var isSaving = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 22))
                            .foregroundColor(OCColor.success)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tus claves nunca viajan al modelo de IA")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(OCColor.textPrimary)
                            Text("Se cifran en el Keychain de este iPhone. El agente solo recibe referencias opacas como {{secret:fel_mx.password}} que exigen confirmación manual y Face ID en cada ejecución.")
                                .font(.system(size: 12.5))
                                .foregroundColor(OCColor.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Nueva credencial o actualizar") {
                    TextField("Alias corto (ej. fel_mx)", text: $alias)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13.5, design: .monospaced))
                    TextField("Nombre amigable (ej. Portal FEL.mx)", text: $label)
                    TextField("Dominio o app (ej. fel.mx)", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Usuario / correo / NIT (opcional)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Contraseña o token secreto", text: $password)
                    Toggle("Pedir Face ID / código en cada uso", isOn: $requireFaceID)

                    Button {
                        saveEntry()
                    } label: {
                        HStack {
                            Label("Guardar en el Keychain de este iPhone", systemImage: "key.fill")
                                .fontWeight(.semibold)
                            if isSaving {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSaving || (alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (username.isEmpty && password.isEmpty))

                    if let feedback {
                        Text(feedback)
                            .font(.system(size: 12.5))
                            .foregroundColor(OCColor.success)
                    }
                }

                Section("Credenciales guardadas (\(vault.entries.count))") {
                    if vault.entries.isEmpty {
                        Text("Aún no tienes credenciales guardadas. Crea la primera arriba para usarla en portales como FEL.mx.")
                            .font(.system(size: 13))
                            .foregroundColor(OCColor.textSecondary)
                    } else {
                        ForEach(vault.entries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: "key.icloud.fill")
                                    .foregroundColor(IysThemePreferences.active.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.label)
                                        .font(.system(size: 14, weight: .bold))
                                    Text("{{secret:\(entry.alias)}} · Campos: \(entry.availableFields.joined(separator: ", "))")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(OCColor.textSecondary)
                                }
                                Spacer()
                                if entry.requireFaceID {
                                    Image(systemName: "faceid")
                                        .foregroundColor(OCColor.success)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await vault.deleteSecret(alias: entry.alias) }
                                } label: {
                                    Label("Eliminar", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Llavero de ISyCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .onAppear {
                if let draft = vault.requestedAliasDraft {
                    if alias.isEmpty { alias = draft.alias }
                    if label.isEmpty { label = draft.label }
                    if domain.isEmpty { domain = draft.domain }
                    vault.requestedAliasDraft = nil
                }
            }
        }
    }

    private func saveEntry() {
        isSaving = true
        feedback = nil
        let targetAlias = alias.isEmpty ? label : alias
        Task {
            do {
                try await vault.upsertSecret(
                    alias: targetAlias,
                    label: label.isEmpty ? targetAlias : label,
                    serviceDomain: domain,
                    username: username,
                    password: password,
                    requireFaceID: requireFaceID
                )
                let norm = SecretVaultEntryMetadata.normalizeAlias(targetAlias)
                password = ""
                username = ""
                feedback = "Guardada como {{secret:\(norm)}} en el Keychain."
                OCHaptics.success()
            } catch {
                feedback = "Error: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

// MARK: - Live Banner shown inside Chat / Shell when Recording or Agent Prepares Learning

public struct LearnActionLiveBanner: View {
    @ObservedObject private var recorder = ActionRecorderService.shared
    @ObservedObject private var vault = SecretVaultStore.shared
    let onOpenRecorder: () -> Void
    let onOpenVault: () -> Void

    public init(onOpenRecorder: @escaping () -> Void, onOpenVault: @escaping () -> Void) {
        self.onOpenRecorder = onOpenRecorder
        self.onOpenVault = onOpenVault
    }

    public var body: some View {
        Group {
            switch recorder.status {
            case .recording(let elapsed, _, let app, let steps):
                HStack(spacing: 10) {
                    Circle()
                        .fill(OCColor.danger)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Grabando acción (\(elapsed)s · \(steps) pasos)")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Última app: \(app) · Toca para detener y revisar")
                            .font(.system(size: 11))
                            .foregroundColor(OCColor.textSecondary)
                    }
                    Spacer()
                    Button("Revisar") { onOpenRecorder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(OCColor.danger)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OCColor.bgBase)
                .overlay(Rectangle().frame(height: 1).foregroundColor(OCColor.danger.opacity(0.35)), alignment: .bottom)

            case .reviewReady:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(OCColor.success)
                    Text("Flujo capturado listo para guardar como herramienta")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(OCColor.textPrimary)
                    Spacer()
                    Button("Compilar L1") { onOpenRecorder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(OCColor.success)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OCColor.bgBase)

            default:
                if let prompt = recorder.liveBannerPrompt {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle")
                            .foregroundColor(IysThemePreferences.active.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Listo para aprender: \(prompt.title)")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundColor(OCColor.textPrimary)
                            Text(prompt.parameters.isEmpty ? "Toca Iniciar grabación y haz el flujo" : "Variables: \(prompt.parameters.joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundColor(OCColor.textSecondary)
                        }
                        Spacer()
                        Button("Grabar") { onOpenRecorder() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(IysThemePreferences.active.accent)
                        if vault.requestedAliasDraft != nil {
                            Button("Llavero") { onOpenVault() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(OCColor.bgBase)
                } else if vault.requestedAliasDraft != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundColor(OCColor.warning)
                        Text("El agente sugiere guardar una credencial en tu Llavero")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Spacer()
                        Button("Abrir Llavero") { onOpenVault() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(OCColor.warning)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(OCColor.bgBase)
                }
            }
        }
    }
}
