import SwiftUI

/// Single-line live process indicator while the assistant is thinking or running tools.
/// Shows the human-friendly current action, live elapsed timer, and step counter, respecting Reduce Motion.
public struct ThinkingShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let activeStepCount: Int
    let startedAt: Date
    let onTap: () -> Void
    @State private var phase: CGFloat = -0.6

    public init(
        label: String,
        activeStepCount: Int = 0,
        startedAt: Date = Date(),
        onTap: @escaping () -> Void = {}
    ) {
        self.label = label
        self.activeStepCount = activeStepCount
        self.startedAt = startedAt
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: {
            OCHaptics.light()
            onTap()
        }) {
            HStack(spacing: OCSpacing.sm) {
                Circle()
                    .fill(IysThemePreferences.active.accent)
                    .frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 1.0 : (phase > 0 ? 0.45 : 1.0))

                Text(label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
                    .overlay(
                        Group {
                            if !reduceMotion {
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.45), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .offset(x: phase * 180)
                                .mask(
                                    Text(label)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .lineLimit(1)
                                )
                            }
                        }
                    )

                Spacer(minLength: 4)

                if activeStepCount > 0 {
                    Text("\(activeStepCount) \(activeStepCount == 1 ? "paso" : "pasos")")
                        .font(OCTypography.metaMono)
                        .foregroundColor(IysThemePreferences.active.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(OCColor.agentBuildSoft))
                }

                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                    let secs = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text("\(secs)s")
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                        .monospacedDigit()
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, 9)
            .background(OCColor.bgBase.opacity(0.92))
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(OCColor.borderMuted), alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

/// Detail sheet opened when tapping the live thinking shimmer line.
public struct AgentActivityDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let events: [TimelineEvent]

    public init(events: [TimelineEvent]) {
        self.events = events
    }

    public var body: some View {
        NavigationStack {
            List {
                let recentTools = events.filter { $0.kind == .toolCall }.suffix(20)
                if recentTools.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(IysThemePreferences.active.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Analizando tu solicitud")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundColor(OCColor.textPrimary)
                            Text("El asistente está preparando su plan y eligiendo herramientas.")
                                .font(OCTypography.meta)
                                .foregroundColor(OCColor.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(Array(recentTools.reversed())) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: OCSpacing.sm) {
                                Image(systemName: ToolCallCollapsedView.iconName(for: step.toolName))
                                    .foregroundColor(step.toolState?.color ?? OCColor.iconPrimary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ToolCallCollapsedView.displayTitle(for: step.toolName))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(OCColor.textPrimary)
                                    if let detail = ToolCallCollapsedView.displayDetail(for: step.toolArguments) {
                                        Text(detail)
                                            .font(OCTypography.metaMono)
                                            .foregroundColor(OCColor.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if let state = step.toolState {
                                    Text(state.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(state.color)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(state.color.opacity(0.14)))
                                }
                            }
                            if let output = step.toolOutput, !output.isEmpty {
                                Text(String(output.prefix(240)))
                                    .font(OCTypography.codeSmall)
                                    .foregroundColor(OCColor.textFaint)
                                    .lineLimit(3)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(OCColor.bgDeep)
                                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r8))
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Proceso en vivo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
