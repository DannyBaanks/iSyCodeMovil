import SwiftUI

/// Slim status row above the chat while the agent works in a sandbox on the computer.
struct SandboxStatusBar: View {
    let link: SandboxLinkState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(OCColor.agentBuild)
                Text("Sandbox · \(link.repo ?? link.projectName)")
                    .font(OCTypography.controlMono)
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: OCSpacing.xs)
                Text(link.remainingLabel ?? link.phaseLabel)
                    .font(OCTypography.metaMono)
                    .foregroundColor(link.phase == "active" ? OCColor.textFaint : OCColor.warning)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OCColor.iconMuted)
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(OCColor.agentBuildSoft)
            .overlay(alignment: .bottom) {
                Rectangle().fill(OCColor.agentBuildBorder).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sandbox en tu computadora, \(link.phaseLabel). Abrir opciones.")
    }
}

/// Everything the person can do with the sandbox: publish, share, restart or unlink.
struct SandboxPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @State private var pullRequestTitle = ""
    @State private var pullRequestBody = ""
    @State private var workArchive: URL?
    @State private var confirmRestart = false
    @State private var confirmUnlink = false

    var body: some View {
        NavigationStack {
            Form {
                if let link = store.sandboxLink {
                    statusSection(link)
                    pullRequestSection(link)
                    shareSection
                    manageSection
                } else {
                    Text("No hay ningún sandbox vinculado.")
                        .foregroundColor(OCColor.textFaint)
                }
            }
            .navigationTitle("Sandbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task { await store.refreshSandboxStatus() }
        }
        .presentationDetents([.large])
    }

    private func statusSection(_ link: SandboxLinkState) -> some View {
        Section {
            LabeledContent("Proyecto", value: link.projectName)
            if let repo = link.repo {
                LabeledContent("Repositorio", value: repo)
            }
            LabeledContent("Estado", value: link.remainingLabel.map { "\(link.phaseLabel) · \($0)" } ?? link.phaseLabel)
            if !link.excludedFiles.isEmpty {
                LabeledContent("Secretos excluidos", value: "\(link.excludedFiles.count)")
            }
            if let message = store.sandboxLinkError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.danger)
            }
        } header: {
            Text("En tu computadora")
        } footer: {
            Text("El agente piensa en este iPhone y sus herramientas se ejecutan en un contenedor sin red, sin acceso a tu disco y sin credenciales. Cada uso reinicia la cuenta atrás.")
        }
    }

    private func pullRequestSection(_ link: SandboxLinkState) -> some View {
        Section {
            if link.canOpenPullRequest {
                TextField("Título del pull request", text: $pullRequestTitle)
                TextField("Descripción (opcional)", text: $pullRequestBody, axis: .vertical)
                    .lineLimit(2...5)
                Button {
                    Task { await store.openSandboxPullRequest(title: pullRequestTitle, body: pullRequestBody) }
                } label: {
                    if store.sandboxLinkBusy {
                        ProgressView()
                    } else {
                        Label("Abrir pull request", systemImage: "arrow.triangle.pull")
                    }
                }
                .disabled(store.sandboxLinkBusy || pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(link.repo == nil
                     ? "La carpeta vinculada no tiene un remoto de GitHub, así que no hay dónde abrir el pull request."
                     : "Tu computadora no tiene una cuenta de GitHub disponible. Inicia sesión allí con gh auth login y vuelve a ejecutar el comando.")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
            }
            if let pullRequest = link.lastPullRequest, let url = URL(string: pullRequest.url) {
                Link(destination: url) {
                    Label("Ver el pull request en GitHub", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Publicar")
        } footer: {
            Text("Tu computadora empuja el trabajo a una rama movilclaw/… y abre el pull request con su propia cuenta. Nunca empuja a la rama principal y nunca lo fusiona.")
        }
    }

    private var shareSection: some View {
        Section {
            ShareLink(item: store.conversationMarkdown()) {
                Label("Compartir la conversación", systemImage: "text.bubble")
            }
            if let workArchive {
                ShareLink(item: workArchive) {
                    Label("Compartir el archivo del trabajo", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    Task { workArchive = await store.exportSandboxWork() }
                } label: {
                    Label("Preparar el trabajo para compartir (.tar.gz)", systemImage: "archivebox")
                }
                .disabled(store.sandboxLinkBusy)
            }
        } header: {
            Text("Compartir")
        } footer: {
            Text("La conversación se comparte como texto. El trabajo es una copia de la carpeta del sandbox, sin los archivos que parecían secretos.")
        }
    }

    private var manageSection: some View {
        Section {
            Button("Empezar de cero con una copia nueva") { confirmRestart = true }
                .disabled(store.sandboxLinkBusy)
                .confirmationDialog("¿Reiniciar el sandbox?", isPresented: $confirmRestart, titleVisibility: .visible) {
                    Button("Destruir y empezar de cero", role: .destructive) {
                        workArchive = nil
                        Task { await store.restartSandbox() }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("Se pierde lo que no hayas publicado o compartido. El sandbox nuevo recibe la carpeta tal como está ahora en tu computadora.")
                }
            Button("Desvincular el sandbox", role: .destructive) { confirmUnlink = true }
                .confirmationDialog("¿Desvincular el sandbox?", isPresented: $confirmUnlink, titleVisibility: .visible) {
                    Button("Desvincular", role: .destructive) {
                        Task {
                            await store.unlinkSandbox()
                            dismiss()
                        }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("El agente vuelve a trabajar con los archivos de este iPhone. El sandbox sigue en tu computadora hasta que caduque o detengas el comando.")
                }
        } header: {
            Text("Administrar")
        }
    }
}
