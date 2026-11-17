import SwiftUI

/// Single-line shimmer indicator while the assistant is thinking or running a tool (inspired by chowder-iOS).
public struct ThinkingShimmerView: View {
    let label: String
    let onTap: () -> Void
    @State private var phase: CGFloat = -0.6

    public init(label: String, onTap: @escaping () -> Void = {}) {
        self.label = label
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.sm) {
                Circle()
                    .fill(IysThemePreferences.active.accent)
                    .frame(width: 7, height: 7)
                    .opacity(phase > 0 ? 0.45 : 1.0)

                Text(label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(OCColor.textSecondary)
                    .lineLimit(1)
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .offset(x: phase * 180)
                        .mask(
                            Text(label)
                                .font(.system(size: 13.5, weight: .medium))
                                .lineLimit(1)
                        )
                    )

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, 8)
            .background(OCColor.bgBase.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
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
                let recentTools = events.filter { $0.kind == .toolCall }.suffix(15)
                if recentTools.isEmpty {
                    Text("El asistente está preparando su respuesta.")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textSecondary)
                } else {
                    ForEach(Array(recentTools)) { step in
                        HStack(spacing: OCSpacing.sm) {
                            Image(systemName: ToolCallCollapsedView.iconName(for: step.toolName))
                                .foregroundColor(step.toolState?.color ?? OCColor.iconPrimary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ToolCallCollapsedView.displayTitle(for: step.toolName))
                                    .font(.system(size: 14, weight: .medium))
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
                                    .font(OCTypography.meta)
                                    .foregroundColor(state.color)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Actividad actual")
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
