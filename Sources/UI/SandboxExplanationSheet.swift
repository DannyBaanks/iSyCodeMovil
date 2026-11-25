import SwiftUI

/// One-screen illustrated card explaining what the sandbox is in plain Spanish.
public struct SandboxExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.xl) {
                    heroCard

                    VStack(alignment: .leading, spacing: OCSpacing.md) {
                        explanationRow(
                            symbol: "folder.badge.gearshape",
                            tint: OCColor.agentBuild,
                            title: "Copia aparte de tu carpeta",
                            detail: "Trabaja sobre una copia temporal en tu computadora. Tus archivos originales no se tocan."
                        )
                        explanationRow(
                            symbol: "wifi.slash",
                            tint: OCColor.warning,
                            title: "Sin internet ni contraseñas",
                            detail: "El contenedor no tiene red ni acceso a tus claves o al resto de tu disco."
                        )
                        explanationRow(
                            symbol: "checkmark.shield",
                            tint: OCColor.success,
                            title: "Tú decides qué sale",
                            detail: "Nada se publica ni cambia tu rama principal sin que tú apruebes abrir un pull request o compartir el resultado."
                        )
                    }
                }
                .padding(OCSpacing.contentMargin)
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("¿Qué es el sandbox?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack(spacing: OCSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: OCRadius.r14)
                        .fill(OCColor.agentBuildSoft)
                        .frame(width: 56, height: 56)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(OCColor.agentBuild)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Un espacio aparte en tu computadora")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Text("Donde el asistente puede probar cosas sin tocar tus archivos")
                        .font(.system(size: 13.5))
                        .foregroundColor(OCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(OCSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OCColor.bgBase)
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.agentBuildBorder, lineWidth: 1))
    }

    private func explanationRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: OCSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(OCSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OCColor.bgBase)
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, lineWidth: 1))
    }
}
