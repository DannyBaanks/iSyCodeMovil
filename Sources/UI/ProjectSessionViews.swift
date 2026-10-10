import SwiftUI
import UniformTypeIdentifiers

public struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let onTap: () -> Void
    
    public init(project: Project, isSelected: Bool = false, onTap: @escaping () -> Void) {
        self.project = project
        self.isSelected = isSelected
        self.onTap = onTap
    }
    
    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: OCRadius.r8)
                        .fill((project.avatarColor ?? IysThemePreferences.active.accent).opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(project.avatarColor ?? OCColor.iconPrimary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(OCTypography.rowPrimary)
                        .foregroundColor(OCColor.textPrimary)
                        .lineLimit(1)
                    
                    Text(project.path.replacingOccurrences(of: "~/", with: "~/"))
                        .font(OCTypography.rowSecondary)
                        .foregroundColor(OCColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("\(project.sessionCount) \(project.sessionCount == 1 ? "sesión" : "sesiones")")
                        .font(OCTypography.metaMono)
                        .foregroundColor(IysThemePreferences.active.accent.opacity(0.85))
                }
                
                Spacer()
                
                HStack(spacing: OCSpacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(OCSpacing.lg)
            .background(isSelected ? IysThemePreferences.active.accent.opacity(0.09) : OCColor.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
            .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(isSelected ? IysThemePreferences.active.accent.opacity(0.55) : OCColor.borderMuted, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct ProjectListView: View {
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ProjectListContent()
        }
    }
}

// Contenido de la lista de proyectos sin NavigationStack propio: lo usan el
// flujo iPhone (ProjectListView) y el sidebar del split en iPad (RootView).
public struct ProjectListContent: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @State private var selectedProject: Project?
    @State private var showSettings = false
    @State private var searchText = ""

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    public init() {}
    
    public var body: some View {
        List {
            if store.projects.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(filteredProjects, content: projectRow)
                } header: {
                    VStack(alignment: .leading, spacing: OCSpacing.xs) {
                        Text("PROYECTOS")
                            .font(OCTypography.sectionLabel)
                            .foregroundColor(OCColor.textFaint)
                            .textCase(nil)
                        Text("\(store.projects.count) \(store.projects.count == 1 ? "proyecto" : "proyectos") · \(store.projects.reduce(0) { $0 + $1.sessionCount }) sesiones")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textFaint)
                            .textCase(nil)
                    }
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.top, OCSpacing.xl)
                    .padding(.bottom, OCSpacing.xs)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("Proyectos")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Buscar proyectos")
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(store)
        }
    }

    // Extraido de la List: la expresion inline superaba el presupuesto de
    // type-check del compilador ("unable to type-check in reasonable time").
    @ViewBuilder
    private func projectRow(project: Project) -> some View {
        ProjectRow(
            project: project,
            isSelected: selectedProject?.id == project.id,
            onTap: { selectProject(project) }
        )
        .listRowInsets(EdgeInsets(top: 5, leading: OCSpacing.contentMargin, bottom: 5, trailing: OCSpacing.contentMargin))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // La seleccion vive en el onTap (no en onChange) para que re-tocar el
    // mismo proyecto en el sidebar del split tambien restaure el detalle.
    private func selectProject(_ project: Project) {
        selectedProject = project
        if let session = sessionState.currentSession, session.projectId != project.id {
            sessionState.currentSession = nil
        }
        sessionState.currentProject = project
        Task { await store.selectProject(project) }
    }

    private var emptyState: some View {
        VStack(spacing: OCSpacing.xl) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            VStack(spacing: OCSpacing.xs) {
                Text(searchText.isEmpty ? "Aún no hay proyectos" : "No encontramos proyectos")
                    .font(OCTypography.bodyStrong)
                    .foregroundColor(OCColor.textPrimary)
                
                Text(searchText.isEmpty
                     ? (store.backendMode == .remote
                        ? "Conecta un servidor OpenCode para ver sus proyectos."
                        : "Inicia el entorno nativo para crear un espacio de trabajo.")
                     : "Prueba con otro nombre o ruta.")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(OCSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

public struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let showsManagementActions: Bool
    
    public init(session: Session, isSelected: Bool = false, showsManagementActions: Bool = true, onTap: @escaping () -> Void, onRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.session = session
        self.isSelected = isSelected
        self.showsManagementActions = showsManagementActions
        self.onTap = onTap
        self.onRename = onRename
        self.onDelete = onDelete
    }
    
    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                RoundedRectangle(cornerRadius: OCRadius.r10)
                    .fill(session.agentMode.color.opacity(0.14))
                    .overlay {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(session.agentMode.color)
                    }
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: OCSpacing.xs) {
                        Text(session.title)
                            .font(OCTypography.rowPrimary)
                            .foregroundColor(OCColor.textPrimary)
                            .lineLimit(1)
                        
                        Circle()
                            .fill(session.agentMode.color)
                            .frame(width: 6, height: 6)
                        
                        if session.isRunning {
                            Circle()
                                .fill(session.agentMode.color)
                                .frame(width: 6, height: 6)
                                .modifier(PulsingDot())
                        }
                    }
                    
                    if let summary = session.lastEventSummary {
                        Text(summary)
                            .font(.system(size: 12.5, weight: .regular, design: .default))
                            .foregroundColor(OCColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.timestamp, style: .relative)
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                    
                    if session.isDirty {
                        Circle()
                            .fill(OCColor.warning)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(OCSpacing.md)
            .frame(minHeight: 68)
            .background(isSelected ? IysThemePreferences.active.accent.opacity(0.09) : OCColor.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
            .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(isSelected ? IysThemePreferences.active.accent.opacity(0.55) : OCColor.borderMuted, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if showsManagementActions {
                Button("Rename", action: onRename)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

public struct SessionListView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    let project: Project
    @State private var selectedSession: Session?
    @State private var showNewSessionSheet = false
    @State private var sessionToRename: Session?
    @State private var renameTitle = ""
    @State private var showDeleteConfirm = false
    @State private var sessionToDelete: Session?
    @State private var searchText = ""
    
    public init(project: Project) {
        self.project = project
    }
    
    private var filteredSessions: [Session] {
        guard !searchText.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.lastEventSummary?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    public var body: some View {
        List {
            Section {
                ForEach(filteredSessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: selectedSession?.id == session.id,
                        showsManagementActions: store.supportsSessionManagement,
                        onTap: {
                            // Seleccion directa (no onChange): re-tocar la misma
                            // sesion tras volver atras tambien debe re-entrar.
                            selectedSession = session
                            sessionState.currentSession = session
                            Task { await store.selectSession(session) }
                        },
                        onRename: { sessionToRename = session; renameTitle = session.title },
                        onDelete: { sessionToDelete = session; showDeleteConfirm = true }
                    )
                    .listRowInsets(EdgeInsets(top: 5, leading: OCSpacing.contentMargin, bottom: 5, trailing: OCSpacing.contentMargin))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if store.supportsSessionManagement {
                            Button(role: .destructive) {
                                sessionToDelete = session
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("SESSIONS")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.top, OCSpacing.xl)
                    .padding(.bottom, OCSpacing.xs)
                    .textCase(nil)
            }
            
            if store.sessions.isEmpty {
                emptyState
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // RootView navega por estado, no por push: volver a la lista de
                // proyectos significa soltar currentProject.
                Button {
                    selectedSession = nil
                    sessionState.currentProject = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNewSessionSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search sessions"
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.sessions.isEmpty {
                Button { showNewSessionSheet = true } label: {
                    Label("Nueva sesión", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(OCColor.bgDeep)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(IysThemePreferences.active.accent.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.sm)
                .padding(.bottom, OCSpacing.sm)
                .background(OCColor.bgDeep.opacity(0.96))
            }
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(project: project) { title in
                Task {
                    _ = await store.createNewSession(in: project, title: title)
                }
            }
        }
        .sheet(item: $sessionToRename) { session in
            RenameSessionSheet(session: session, initialTitle: session.title) { newTitle in
                Task { await store.renameSession(session, title: newTitle) }
            }
        }
        .alert("Delete Session", isPresented: $showDeleteConfirm, presenting: sessionToDelete) { session in
            Button("Delete", role: .destructive) {
                Task { await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: { session in
            Text("Delete this conversation? This action cannot be undone.")
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: OCSpacing.xl) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            VStack(spacing: OCSpacing.xs) {
                Text("No Sessions")
                    .font(OCTypography.bodyStrong)
                    .foregroundColor(OCColor.textPrimary)
                
                Text("Create a session to start working")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }
            Button { showNewSessionSheet = true } label: {
                Label("Iniciar conversación", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(OCColor.bgDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(IysThemePreferences.active.accent.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
            }
            .buttonStyle(.plain)
            .padding(.top, OCSpacing.sm)
        }
        .padding(OCSpacing.huge)
        .padding(.horizontal, OCSpacing.contentMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let onCreate: (String) -> Void
    @State private var title = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Session Details") {
                    TextField("Title (optional)", text: $title)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let initialTitle: String
    let onRename: (String) -> Void
    @State private var title = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Rename Session") {
                    TextField("Title", text: $title)
                }
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onRename(title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == initialTitle)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { title = initialTitle }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @State private var hasStoredPairing = false
    @State private var showRemoteUnavailableNote = false
    @State private var selectedTheme = IysThemePreferences.pending ?? IysThemePreferences.active
    @State private var showThemeRestartNotice = false
    @State private var showSandboxFolderPicker = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: OCSpacing.md) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(IysTheme.allCases) { theme in
                                ThemeChoiceRow(
                                    theme: theme,
                                    isSelected: selectedTheme == theme,
                                    isActive: IysThemePreferences.active == theme
                                ) {
                                    guard selectedTheme != theme else { return }
                                    selectedTheme = theme
                                    IysThemePreferences.pending = theme
                                    showThemeRestartNotice = true
                                }
                            }

                            ComingSoonThemeCard()
                        }
                    }
                    .padding(.vertical, OCSpacing.xs)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Tema de la app")
                } footer: {
                    Text("El tema se aplica al volver a abrir iSyCode.")
                }

                Section("ISyCode Host API") {
                    MobileHostPairingSection()
                        .environmentObject(hostStore)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                }

                Section("Legacy Bridge") {
                    if store.backendMode == .remote || store.backendMode == .native {
                        HStack {
                            Text("Backend")
                            Spacer()
                            Text(store.connectionStatus)
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.textFaint)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Connection")
                            Spacer()
                            Text(store.connectionHealth.rawValue.capitalized)
                                .font(OCTypography.metaMono)
                                .foregroundColor(healthColor(for: store.connectionHealth))
                        }
                        if store.backendMode == .remote {
                            Button("Forget Connection", role: .destructive) {
                                Task {
                                    await store.forgetPairing()
                                    await store.disconnect()
                                }
                            }
                        }
                    } else {
                        Text("Not connected")
                            .foregroundColor(OCColor.textFaint)
                    }
                }
                
                Section("Runtime") {
                    Picker("Mode", selection: modeBinding) {
                        Text("Remote (OpenCode Server)").tag(BackendMode.remote.rawValue)
                        Text("Sandbox (this phone)").tag(BackendMode.native.rawValue)
                    }
                    
                    if store.backendMode == .native {
                        NavigationLink("Proveedores y API keys") {
                            APIKeysView()
                        }
                    }
                    
                    if showRemoteUnavailableNote {
                        Text("No stored pairing — link a desktop first.")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.warning)
                    }
                }

                Section("Sandbox del iPhone") {
                    NavigationLink {
                        NativeCapabilitySettingsView()
                    } label: {
                        Label("Capacidades nativas", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }

                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.sandboxFolderName ?? "Carpeta privada de iSyCode")
                                .foregroundColor(OCColor.textPrimary)
                                .lineLimit(1)
                            Text(store.sandboxFolderName == nil
                                 ? "El agente solo ve su espacio privado"
                                 : "Acceso concedido por Archivos · carpeta seleccionada")
                                .font(OCTypography.meta)
                                .foregroundColor(OCColor.textFaint)
                        }
                    } icon: {
                        Image(systemName: store.sandboxFolderName == nil ? "iphone" : "folder.badge.plus")
                            .foregroundColor(IysThemePreferences.active.accent)
                    }

                    Button {
                        showSandboxFolderPicker = true
                    } label: {
                        Label(store.sandboxFolderName == nil ? "Elegir carpeta en Archivos" : "Cambiar carpeta autorizada",
                              systemImage: "folder.open")
                    }

                    if store.sandboxFolderName != nil {
                        Button("Revocar acceso a la carpeta", role: .destructive) {
                            Task {
                                do {
                                    try await store.revokeSandboxFolderAccess()
                                } catch {
                                    store.sandboxFolderError = error.localizedDescription
                                }
                            }
                        }
                    }

                    Text("El agente queda limitado a esta carpeta. Sus cambios y borrados siguen pidiendo aprobación. Si usas un modelo en la nube, el contenido que lea puede enviarse a ese proveedor. iOS puede revocar el acceso desde Ajustes; esto no da acceso a otras apps ni al resto del iPhone.")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textFaint)
                }
                
                Section("Attribution") {
                    HStack {
                        Text("ISyCode Móvil")
                        Spacer()
                        Text("Independent open-source app")
                            .foregroundColor(OCColor.textFaint)
                    }
                    HStack {
                        Text("License")
                        Spacer()
                        Text("MIT")
                            .foregroundColor(OCColor.textFaint)
                    }
                }

                Section("External providers & projects") {
                    LabeledContent("AI providers", value: "OpenAI · Anthropic · Google · xAI · NVIDIA · OpenRouter")
                    LabeledContent("Desktop runtime", value: "OpenCode · Codex")
                    LabeledContent("Local model", value: "Qwen · Hugging Face")
                    LabeledContent("Inference runtime", value: "llama.cpp")

                    Text("All names and trademarks belong to their respective owners. ISyCode Móvil is an independent client and is not affiliated with or endorsed by these providers or projects. Provider access, terms, model licenses, and charges are set by their respective owners.")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                Task { hasStoredPairing = await store.hasStoredPairing() }
            }
            .alert("Tema listo", isPresented: $showThemeRestartNotice) {
                Button("Entendido", role: .cancel) { }
            } message: {
                Text("Cierra y vuelve a abrir iSyCode para aplicar el tema \(selectedTheme.title). iOS no permite que la app se reinicie por sí sola.")
            }
        }
        .presentationDetents([.medium, .large])
        .fileImporter(
            isPresented: $showSandboxFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                Task {
                    do {
                        try await store.authorizeSandboxFolder(folder)
                    } catch {
                        store.sandboxFolderError = error.localizedDescription
                    }
                }
            case .failure(let error):
                store.sandboxFolderError = error.localizedDescription
            }
        }
        .alert("No se pudo autorizar la carpeta", isPresented: Binding(
            get: { store.sandboxFolderError != nil },
            set: { if !$0 { store.clearSandboxFolderError() } }
        )) {
            Button("Entendido", role: .cancel) { store.clearSandboxFolderError() }
        } message: {
            Text(store.sandboxFolderError ?? "")
        }
    }
    
    // El picker conmuta de verdad: `native` arranca el runtime Swift; `remote`
    // reconecta el pairing guardado (o avisa si no existe ninguno).
    private var modeBinding: Binding<String> {
        Binding(
            get: { store.backendMode.rawValue },
            set: { newValue in
                if newValue == BackendMode.native.rawValue {
                    Task { await store.useNativeRuntime() }
                } else if hasStoredPairing {
                    Task { await store.reconnectStoredPairing() }
                } else {
                    showRemoteUnavailableNote = true
                }
            }
        )
    }
    
    private func healthColor(for health: ConnectionHealth) -> Color {
        switch health {
        case .connected: return OCColor.success
        case .connecting: return OCColor.warning
        case .disconnected: return OCColor.danger
        }
    }
}

private struct ThemeChoiceRow: View {
    let theme: IysTheme
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Circle().fill(theme.accent).frame(width: 5, height: 5)
                            Capsule().fill(Color.white.opacity(0.22)).frame(width: 27, height: 3)
                        }
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accent.opacity(0.14))
                            .frame(height: 12)
                            .overlay(alignment: .leading) {
                                Capsule().fill(theme.accent).frame(width: 31, height: 3).padding(.leading, 5)
                            }
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 12)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.22)).frame(width: 24, height: 3).padding(.leading, 5)
                            }
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
                    .background(theme == .console ? Color(hex: "07100D") : Color(hex: "151C29"))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.accent)
                            .background(Circle().fill(OCColor.bgDeep).padding(1))
                            .padding(4)
                    }
                }

                Text(theme.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
                Text(theme == .console ? "Enfoque total. Estilo terminal." : "Moderno. Elegante. Listo para todo.")
                    .font(.system(size: 9))
                    .foregroundColor(OCColor.textFaint)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
            }
            .padding(8)
            .background(isSelected ? theme.accent.opacity(0.08) : OCColor.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
            .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(isSelected ? theme.accent.opacity(0.55) : OCColor.borderMuted, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: OCRadius.r14))
        }
        .buttonStyle(.plain)
    }
}

private struct ComingSoonThemeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.035))
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(OCColor.textFaint)
            }
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)

            Text("Próximamente")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(OCColor.textSecondary)
                .lineLimit(1)
            Text("Más temas llegarán pronto")
                .font(.system(size: 9))
                .foregroundColor(OCColor.textFaint)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
        }
        .padding(8)
        .background(OCColor.bgBase.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}

struct APIKeysView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @State private var keys: [String: String] = [:]
    @State private var configuredProviderIDs = Set<String>()
    @State private var selectedProviderID = "nvidia"
    @State private var showProviderDirectory = false
    
    var body: some View {
        Form {
            Section {
                Picker("Proveedor predeterminado", selection: $selectedProviderID) {
                    ForEach(SandboxModelProvider.all) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                ForEach(SandboxModelProvider.all) { provider in
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField(provider.keyPlaceholder, text: binding(for: provider.id))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if configuredProviderIDs.contains(provider.id) && (keys[provider.id] ?? "").isEmpty {
                            Label("Ya configurada · valor oculto en Keychain", systemImage: "key.fill")
                                .font(OCTypography.meta)
                                .foregroundStyle(IysThemePreferences.active.accent)
                        }
                    }
                }
            } header: {
                Text("API keys · sandbox del iPhone")
            } footer: {
                Text("Las claves se guardan en Keychain. El proveedor predeterminado se intenta primero; después se usan otras claves configuradas.")
            }
        }
        .navigationTitle("Proveedores")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showProviderDirectory = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Ayuda de proveedores y MCP")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Guardar") {
                    Task {
                        await store.saveAPIKeys(values: keys, selectedProviderID: selectedProviderID)
                        keys = [:]
                        dismiss()
                    }
                }
                .disabled(keys.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && !configuredProviderIDs.contains(selectedProviderID))
            }
        }
        .sheet(isPresented: $showProviderDirectory) { ProviderDirectoryView() }
        .task { await loadConfiguredProviders() }
    }

    private func binding(for providerID: String) -> Binding<String> {
        Binding(get: { keys[providerID] ?? "" }, set: { keys[providerID] = $0 })
    }

    private func loadConfiguredProviders() async {
        guard let persistence = try? IOSPersistence() else { return }
        for provider in SandboxModelProvider.all {
            if let key = try? await persistence.loadAPIKey(provider: provider.id), !key.isEmpty {
                configuredProviderIDs.insert(provider.id)
            }
        }
    }
}

// Indicador "running" de sesion: punto con pulso (antes era un segundo punto
// estatico identico al de agentMode, indistinguible a la vista).
struct PulsingDot: ViewModifier {
    @State private var pulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
