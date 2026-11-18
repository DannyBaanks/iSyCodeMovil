import SwiftUI

/// Ajustes › "Carpetas de conversaciones": each conversation works in its own folder on
/// the iPhone. Shows how much they take and cleans them. Messages are never touched, and
/// a conversation that is working right now keeps its folder.
struct ConversationSandboxesSection: View {
    @EnvironmentObject private var store: WorkbenchStore

    @State private var summary: ConversationSandboxSummary?
    @State private var lastResult: ConversationSandboxes.CleanupResult?
    @State private var isCleaning = false
    @State private var confirmEmptyAll = false

    var body: some View {
        Section {
            HStack(spacing: OCSpacing.md) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(IysThemePreferences.active.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Carpetas de conversaciones")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundColor(OCColor.textSecondary)
                }
                Spacer(minLength: 0)
                if isCleaning || summary == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                Task { await clean(onlyOrphans: true) }
            } label: {
                Label(orphanButtonTitle, systemImage: "trash")
            }
            .disabled(isCleaning || (summary?.orphanFolders ?? 0) == 0)
            .accessibilityIdentifier("settings-clean-orphan-sandboxes")

            Button(role: .destructive) {
                confirmEmptyAll = true
            } label: {
                Label("Vaciar todas las carpetas", systemImage: "trash.slash")
            }
            .disabled(isCleaning || (summary?.folders ?? 0) == 0)
            .accessibilityIdentifier("settings-empty-all-sandboxes")

            if let lastResult {
                Text(resultLine(lastResult))
                    .font(.caption)
                    .foregroundColor(OCColor.textSecondary)
            }
        } header: {
            Text("Conversaciones en paralelo")
        } footer: {
            Text("Cada conversación trabaja en su propia carpeta del iPhone, así varias pueden avanzar a la vez sin pisarse. Limpiar borra los archivos que el agente creó, no los mensajes. Si elegiste una carpeta en Archivos, todas la comparten y aquí no se toca.")
        }
        .task { await refresh() }
        .confirmationDialog(
            "¿Vaciar todas las carpetas de conversaciones?",
            isPresented: $confirmEmptyAll,
            titleVisibility: .visible
        ) {
            Button("Vaciar todas", role: .destructive) {
                Task { await clean(onlyOrphans: false) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borran los archivos que el agente creó en cada conversación. Los mensajes se conservan y las conversaciones que están trabajando ahora no se tocan.")
        }
    }

    private var summaryLine: String {
        guard let summary else { return "Calculando…" }
        if summary.folders == 0 { return "Ninguna carpeta todavía" }
        let noun = summary.folders == 1 ? "carpeta" : "carpetas"
        return "\(summary.folders) \(noun) · \(Self.format(summary.bytes))"
    }

    private var orphanButtonTitle: String {
        guard let orphans = summary?.orphanFolders, orphans > 0, let summary else {
            return "Limpiar las de conversaciones borradas"
        }
        return "Limpiar las de conversaciones borradas (\(orphans) · \(Self.format(summary.orphanBytes)))"
    }

    private func resultLine(_ result: ConversationSandboxes.CleanupResult) -> String {
        var line = result.removedFolders == 0
            ? "No había nada que limpiar."
            : "Listo: \(result.removedFolders) \(result.removedFolders == 1 ? "carpeta" : "carpetas") · \(Self.format(result.freedBytes)) liberados."
        if result.skippedRunning > 0 {
            line += " \(result.skippedRunning) en uso no se tocaron."
        }
        return line
    }

    private func refresh() async {
        summary = await store.conversationSandboxSummary()
    }

    private func clean(onlyOrphans: Bool) async {
        isCleaning = true
        lastResult = await store.cleanConversationSandboxes(onlyOrphans: onlyOrphans)
        isCleaning = false
        OCHaptics.success()
        await refresh()
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
