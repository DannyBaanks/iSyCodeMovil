import SwiftUI

/// Settings section for repositories cloned on the iPhone: clone one, see which is
/// active, undo the agent's last change, or stop working in it.
struct PhoneProjectSection: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var repository = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedRepository: String {
        repository.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Section {
            if let project = store.phoneProject {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project)
                            .foregroundColor(OCColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Proyecto activo · copia desechable")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textFaint)
                    }
                } icon: {
                    Image(systemName: "shippingbox")
                        .foregroundColor(IysThemePreferences.active.accent)
                }

                Button {
                    Task { await store.undoPhoneProjectChange() }
                } label: {
                    Label("Deshacer el último cambio", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.phoneProjectCanUndo || store.phoneProjectBusy)

                Button("Cerrar el proyecto") {
                    Task { await store.closePhoneProject() }
                }
                .disabled(store.phoneProjectBusy)
            }

            TextField("dueño/nombre, p. ej. octocat/Hello-World", text: $repository)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($fieldFocused)
                .submitLabel(.go)
                .onSubmit { clone() }

            Button {
                clone()
            } label: {
                if store.phoneProjectBusy {
                    ProgressView()
                } else {
                    Label("Clonar repositorio de GitHub", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(trimmedRepository.isEmpty || store.phoneProjectBusy)

            if let message = store.phoneProjectMessage {
                Text(message)
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Repositorios en este iPhone")
        } footer: {
            Text("Se descarga una copia de un repositorio público, sin git ni historial, en la carpeta repos/. Con un modelo local, el agente trabaja dentro de esa copia sin pedir aprobación y cada cambio se puede deshacer. Cerrar el proyecto no borra los archivos.")
        }
        .task { await store.refreshPhoneProject() }
    }

    private func clone() {
        guard !trimmedRepository.isEmpty, !store.phoneProjectBusy else { return }
        fieldFocused = false
        let target = trimmedRepository
        Task {
            if await store.clonePhoneRepository(target) {
                repository = ""
            }
        }
    }
}
