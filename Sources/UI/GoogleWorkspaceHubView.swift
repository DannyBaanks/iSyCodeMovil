import SwiftUI

/// Hosts Google Workspace OAuth + Tools availability, Memory (folders & semantic graph),
/// and developer Event Log inside the shared AppShell without a separate fullScreenCover.
public struct GoogleWorkspaceHubView: View {
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            subtabPicker
            if let message = assistant.message {
                noticeBanner(message)
            }
            subtabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("Google y memoria")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var subtabPicker: some View {
        let visible = GoogleHubSubtab.visible(developerMode: assistant.developerMode)
        return Picker("Sección", selection: $router.googleSubtab) {
            ForEach(visible) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.vertical, OCSpacing.sm)
        .onChange(of: assistant.developerMode) { enabled in
            if !enabled && router.googleSubtab == .log {
                router.googleSubtab = .google
            }
        }
    }

    @ViewBuilder
    private var subtabContent: some View {
        switch router.googleSubtab {
        case .google:
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.lg) {
                    AssistantGoogleSectionView {
                        router.showGoogleOAuthSetupSheet = true
                    }
                    toolsAvailabilitySection
                        .padding(.horizontal, OCSpacing.contentMargin)
                        .padding(.bottom, OCSpacing.xl)
                }
            }
            .refreshable {
                assistant.refreshAll()
            }
        case .memory:
            AssistantMemorySectionView()
        case .log:
            AssistantLogSectionView()
        }
    }

    private var toolsAvailabilitySection: some View {
        let googleState = assistant.googleConnectionState
        return VStack(alignment: .leading, spacing: OCSpacing.md) {
            Text("Herramientas disponibles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(OCColor.textPrimary)

            Text("Las herramientas de lectura consultan datos al momento. Las escrituras siempre piden confirmación explícita antes de ejecutarse.")
                .font(.system(size: 13))
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(AssistantCatalog.tools) { tool in
                let availability = ConnectionStatusEvaluator.availability(
                    for: tool,
                    googleState: googleState,
                    grantedScopes: assistant.grantedScopes
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: tool.service?.symbol ?? "brain")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(IysThemePreferences.active.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(tool.serviceTitle)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundColor(OCColor.textPrimary)
                                Text(availability.badgeLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(availability.isReady ? (tool.mode == .writeConfirmed ? OCColor.warning : OCColor.success) : OCColor.warning)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(
                                            (availability.isReady ? (tool.mode == .writeConfirmed ? OCColor.warning : OCColor.success) : OCColor.warning)
                                                .opacity(0.14)
                                        )
                                    )
                            }
                            Text(tool.description)
                                .font(.system(size: 13))
                                .foregroundColor(OCColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if assistant.developerMode {
                                Text("\(tool.id) · \(tool.endpoint)")
                                    .font(OCTypography.metaMono)
                                    .foregroundColor(OCColor.textFaint)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if !availability.isReady, let cta = availability.ctaTitle, let target = availability.target {
                        Button {
                            router.handle(target, assistant: assistant)
                        } label: {
                            Label(cta, systemImage: "arrow.right.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(IysThemePreferences.active.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 34)
                        .accessibilityIdentifier("tool-cta-\(tool.id)")
                    }
                }
                .padding(OCSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ocCard(radius: OCRadius.r14)
            }
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 13.5))
                .foregroundColor(OCColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { assistant.message = nil } label: {
                Image(systemName: "xmark").foregroundColor(OCColor.textSecondary)
            }
            .accessibilityLabel("Cerrar aviso")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: OCRadius.r10).fill(OCColor.agentBuildSoft))
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.bottom, 6)
    }
}
