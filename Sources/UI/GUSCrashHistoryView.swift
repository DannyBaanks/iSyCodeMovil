import SwiftUI

/// Crash history: where and why the app died, from the flight recorder and MetricKit.
public struct GUSCrashHistoryView: View {
    @State private var reports: [GUSFlightRecorder.CrashReport] = []
    @State private var selected: GUSFlightRecorder.CrashReport?
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    static let issueURL = URL(string: "https://github.com/DannyBaanks/iSyCodeMovil/issues/new?template=crash-report.yml")!

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Se guarda en el iPhone qué estaba haciendo la app (fase, modelo, memoria, tokens) antes de cada paso riesgoso. Nunca se guarda el texto de tus mensajes ni de las respuestas.")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
                if reports.isEmpty {
                    Text("Sin fallos registrados.")
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                }
                ForEach(reports) { report in
                    Button { selected = report } label: { row(report) }
                }
            }
            .navigationTitle("Informes de fallos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Eliminar", role: .destructive) { confirmClear = true }.disabled(reports.isEmpty)
                }
            }
            .confirmationDialog("¿Borrar todos los informes?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Borrar todo", role: .destructive) {
                    GUSFlightRecorder.shared.deleteAllReports()
                    reports = []
                }
            }
            .sheet(item: $selected) { GUSCrashReportDetailView(report: $0) }
            .task { reports = GUSFlightRecorder.shared.reports() }
        }
    }

    private func row(_ report: GUSFlightRecorder.CrashReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: Self.icon(report.kind)).foregroundColor(.red)
                Text(report.summary).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            Text(report.likelyCause)
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(2)
        }
    }

    static func icon(_ kind: GUSFlightRecorder.CrashReport.Kind) -> String {
        switch kind {
        case .uncleanExit: return "memorychip"
        case .fatalSignal: return "exclamationmark.octagon"
        case .metricKitCrash: return "ladybug"
        case .metricKitExits: return "chart.bar.xaxis"
        }
    }
}

struct GUSCrashReportDetailView: View {
    let report: GUSFlightRecorder.CrashReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Qué pasó") {
                    Text(report.summary).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(report.likelyCause).font(.system(size: 11, design: .monospaced))
                }
                if let marker = report.marker {
                    Section("Contexto") {
                        fact("Fase", marker.phase)
                        fact("Modelo", marker.modelID ?? "—")
                        fact("En primer plano", marker.inForeground ? "sí" : "no")
                        fact("Pico de memoria", bytes(marker.peakFootprintBytes))
                        fact("RAM del equipo", bytes(marker.physicalMemory))
                        fact("Equipo", marker.deviceModel)
                        fact("iOS", marker.osVersion)
                        fact("App", marker.appVersion)
                    }
                }
                if !report.breadcrumbs.isEmpty {
                    Section("Últimos pasos (más reciente abajo)") {
                        ForEach(Array(report.breadcrumbs.enumerated()), id: \.offset) { _, crumb in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(crumb.time.formatted(date: .omitted, time: .standard))  \(crumb.event)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Text("uso \(bytes(crumb.footprintBytes)) · libre \(bytes(crumb.availableBytes))"
                                     + (crumb.fields.isEmpty ? "" : " · " + crumb.fields.sorted { $0.key < $1.key }
                                        .map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
                                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if report.appleDiagnostic != nil {
                    Section("Diagnóstico de iOS") {
                        Text("Incluye el JSON de MetricKit con la pila de llamadas; va dentro del archivo exportado.")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
                Section {
                    ShareLink(item: GUSFlightRecorder.shared.exportJSON(report),
                              preview: SharePreview("ISyCode crash \(report.id.prefix(8)).json")) {
                        Label("Exportar informe (JSON)", systemImage: "square.and.arrow.up")
                    }
                    Link(destination: GUSCrashHistoryView.issueURL) {
                        Label("Reportar en GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Informe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}
