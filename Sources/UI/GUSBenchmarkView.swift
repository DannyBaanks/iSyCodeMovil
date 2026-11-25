import SwiftUI
import UIKit

/// Runs the fixed GUS benchmark for one downloaded model and exports the result
/// for publication in the repository (docs/BENCHMARKS.md).
public struct GUSBenchmarkView: View {
    let manifest: GUSModelManifest
    let modelURL: URL
    @State private var running = false
    @State private var step = ""
    @State private var report: GUSBenchmarkReport?
    @State private var killed: GUSBenchmarkReport?
    @Environment(\.dismiss) private var dismiss

    static let issueURL = URL(string: "https://github.com/DannyBaanks/iSyCodeMovil/issues/new?template=benchmark.yml")!

    public init(manifest: GUSModelManifest, modelURL: URL) {
        self.manifest = manifest
        self.modelURL = modelURL
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(manifest.modelName).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("Protocolo v\(GUSBenchmark.protocolVersion): 4 tareas fijas, decodificación greedy, contexto 2K. Mide carga, prefill, generación, memoria pico y temperatura. El informe no contiene texto de prompts ni respuestas.")
                        .font(OCTypography.controlMono).foregroundColor(.secondary)
                    Text("Para una medición limpia, no tengas GUS respondiendo con otro modelo al mismo tiempo. Si iOS cierra la app, al volver podrás exportar el resultado como KILLED: también es un dato útil.")
                        .font(OCTypography.controlMono).foregroundColor(.secondary)
                }

                if let killed {
                    Section("Corrida anterior interrumpida") {
                        Text(killed.error ?? "iOS terminó la app.").font(OCTypography.controlMono)
                        exportButtons(killed)
                    }
                }

                Section {
                    Button {
                        Task {
                            running = true
                            report = await GUSBenchmark.run(manifest: manifest, modelURL: modelURL) { step = $0 }
                            running = false
                        }
                    } label: {
                        HStack {
                            if running { ProgressView() }
                            Text(running ? step : "Iniciar benchmark")
                        }
                    }
                    .disabled(running)
                }

                if let report {
                    Section("Resultado · \(report.status.rawValue.uppercased())") {
                        metric("Carga", report.loadMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                        metric("Memoria pico", bytes(report.peakFootprintBytes))
                        metric("Memoria antes", bytes(report.footprintBeforeBytes))
                        metric("Temperatura", "\(report.thermalStart) → \(report.thermalEnd ?? "?")")
                        ForEach(report.tasks, id: \.id) { task in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(task.passed ? "✓" : "✗") \(task.id)")
                                    .font(OCTypography.controlMonoStrong)
                                Text(String(format: "prefill %.1f tok/s · gen %.1f tok/s · %d→%d tok · %@",
                                            task.prefillTokensPerSecond, task.generationTokensPerSecond,
                                            task.promptTokens, task.generatedTokens, task.template))
                                    .font(OCTypography.controlMono).foregroundColor(.secondary)
                            }
                        }
                        if let error = report.error {
                            Text(error).font(OCTypography.controlMono).foregroundColor(.red)
                        }
                        exportButtons(report)
                    }
                }
            }
            .navigationTitle("Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() }.disabled(running) } }
            .interactiveDismissDisabled(running)
            .task {
                if let pending = GUSBenchmark.takeKilledRun() {
                    GUSBenchmark.save(pending)
                    if pending.model.id == manifest.id { killed = pending }
                }
            }
        }
    }

    @ViewBuilder
    private func exportButtons(_ report: GUSBenchmarkReport) -> some View {
        ShareLink(item: report.json(), preview: SharePreview("gus-benchmark-\(report.model.id).json")) {
            Label("Exportar JSON", systemImage: "square.and.arrow.up")
        }
        Button {
            UIPasteboard.general.string = report.json()
        } label: {
            Label("Copiar JSON", systemImage: "doc.on.doc")
        }
        Link(destination: Self.issueURL) {
            Label("Publicar en GitHub (pega el JSON)", systemImage: "arrow.up.right.square")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
        .font(OCTypography.controlMono)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}
