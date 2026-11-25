import SwiftUI

/// Vista principal TUI/console-first.
/// NO es una app de chat con burbujas. Es una consola monospace con:
/// - status bar arriba
/// - transcript scrollable (monospace)
/// - input line abajo (con completado slash commands)
public struct ConsoleView: View {
    @StateObject private var vm = SessionViewModel()
    @FocusState private var inputFocused: Bool
    @State private var showMatrixSheet = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider().opacity(0.4)
            transcriptView
            if let request = vm.pendingPermission {
                permissionCard(request)
            }
            Divider().opacity(0.4)
            inputLine
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(.dark)
        .task { await vm.initialize() }
        .onDisappear { vm.cancelAgent() }
        .sheet(isPresented: $showMatrixSheet) {
            MatrixSheet(vm: vm)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("opencode-native")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundColor(.accentColor)
            Text(vm.statusLine)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button { showMatrixSheet = true } label: {
                Image(systemName: "square.grid.2x2").font(.caption)
            }
            Button { Task { await vm.runBootAttempt() } } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            Button { vm.transcript.removeAll() } label: {
                Image(systemName: "trash").font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.transcript) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(color(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .id(line.id)
                    }
                    if vm.isProcessing {
                        Text("▌")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .id("cursor")
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: vm.transcript.count) { _ in
                if let last = vm.transcript.last {
                    withAnimation(.easeOut(duration: 0.05)) { proxy.scrollTo(last.id, anchor: .bottom) }
                } else if vm.isProcessing {
                    proxy.scrollTo("cursor", anchor: .bottom)
                }
            }
        }
    }

    private var inputLine: some View {
        HStack(spacing: 8) {
            Text(vm.isProcessing ? "…" : ">")
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
            TextField(vm.isProcessing ? "" : "mensaje o /help (Enter)", text: $vm.inputText)
                .font(.system(.callout, design: .monospaced))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { vm.handleEnter() }
            Button { vm.handleEnter() } label: {
                Image(systemName: "arrow.up")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(canSend ? .accentColor : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var canSend: Bool {
        !vm.isProcessing && !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func permissionCard(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aprobación requerida", systemImage: "exclamationmark.shield.fill")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundColor(.orange)
            Text(request.reason)
                .font(.system(.caption, design: .monospaced))
            Text("\(request.toolName) · \(request.arguments.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Denegar") {
                    vm.respondToPermission(requestID: request.id, decision: .deny)
                }
                .accessibilityIdentifier("permission-deny")
                Spacer()
                Button("Aprobar una vez") {
                    vm.respondToPermission(requestID: request.id, decision: .allowOnce)
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("permission-allow-once")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r8).stroke(Color.orange.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func color(for kind: TranscriptLine.Kind) -> Color {
        switch kind {
        case .system:    return .secondary
        case .boot:      return .cyan
        case .user:      return .primary
        case .assistant: return .primary
        case .tool:      return .yellow
        case .toolResult:return .green
        case .error:     return .red
        case .success:   return .green
        }
    }
}

struct MatrixSheet: View {
    @ObservedObject var vm: SessionViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let ba = vm.lastBootAttempt {
                        ForEach(Array(ba.compatibilityReport.entries.enumerated()), id: \.element.id) { _, e in
                            entryRow(e)
                        }
                        Divider().padding(.vertical, 4)
                        Text(ba.compatibilityReport.canOpenCodeBoot ? "VERDICTO: arrancando" : "VERDICTO: BLOCKED")
                            .font(.system(.callout, design: .monospaced).weight(.bold))
                            .foregroundColor(ba.compatibilityReport.canOpenCodeBoot ? .green : .red)
                        if let b = ba.compatibilityReport.firstBlocker {
                            Text("Bloqueador: \(b.requirementLabel)").font(.system(.caption, design: .monospaced))
                            Text("Evidence: \(b.evidence)").font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        }
                    } else {
                        Text("Sin boot attempt aún.").font(.system(.caption, design: .monospaced))
                    }
                }
                .padding()
            }
            .navigationTitle("Capability Matrix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Re-run") { Task { await vm.runBootAttempt() } }
                }
            }
        }
    }

    private func entryRow(_ e: CompatibilityReport.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("[\(e.verdict.rawValue.uppercased())]")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundColor(verdictColor(e.verdict))
                Text(e.requirementLabel)
                    .font(.system(.caption, design: .monospaced))
            }
            Text("ev: \(e.evidence)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            if let h = e.href {
                Text("hint: \(h)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.orange.opacity(0.9))
            }
        }
        .padding(.vertical, 2)
    }

    private func verdictColor(_ v: CompatibilityReport.Entry.Verdict) -> Color {
        switch v {
        case .compatible: return .green
        case .partial:    return .yellow
        case .unsupported:return .red
        case .uncharted:  return .gray
        }
    }
}
