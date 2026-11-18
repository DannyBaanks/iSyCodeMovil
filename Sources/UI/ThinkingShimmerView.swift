import SwiftUI

/// Single-line live process indicator while the assistant is thinking or running tools.
/// Shows the human-friendly current action, live elapsed timer, and step counter, respecting Reduce Motion.
public struct ThinkingShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let activeStepCount: Int
    let startedAt: Date?
    let onTap: () -> Void

    public init(
        label: String,
        activeStepCount: Int = 0,
        startedAt: Date? = nil,
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

                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(OCColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 4)

                if activeStepCount > 0 {
                    Text("\(activeStepCount) \(activeStepCount == 1 ? "paso" : "pasos")")
                        .font(OCTypography.metaMono)
                        .foregroundColor(IysThemePreferences.active.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(OCColor.agentBuildSoft))
                }

                if let startedAt {
                    Text(startedAt, style: .timer)
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textSecondary)
                        .monospacedDigit()
                        .fixedSize()
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OCColor.textFaint)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, OCSpacing.xs)
            .background(OCColor.bgBase.opacity(0.92))
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(OCColor.borderMuted), alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Muestra las herramientas de este turno")
        .accessibilityIdentifier("chat-turn-activity")
        .animation(reduceMotion ? nil : OCMotion.smooth, value: activeStepCount)
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
                    Label("Este turno aún no registra herramientas.", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundColor(OCColor.textSecondary)
                        .padding(.vertical, OCSpacing.sm)
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
            .navigationTitle("Actividad de este turno")
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
