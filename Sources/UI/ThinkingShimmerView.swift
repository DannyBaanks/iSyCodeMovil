import SwiftUI

/// Single-line live process indicator while the assistant is thinking or running tools.
/// Shows the human-friendly current action, live elapsed timer, and step counter, respecting Reduce Motion.
public struct ThinkingShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let activeStepCount: Int
    let startedAt: Date
    let onTap: () -> Void
    @State private var isVisible = false

    private static let cycleDuration: TimeInterval = 1.40
    private static let restDuration: TimeInterval = 0.304
    private static let sweepDuration: TimeInterval = 1.096
    private static let minIndicatorOpacity: Double = 0.35

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
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isVisible)) { context in
                    let state = shimmerState(at: context.date)
                    HStack(spacing: OCSpacing.sm) {
                        Circle()
                            .fill(IysThemePreferences.active.accent)
                            .frame(width: 8, height: 8)
                            .opacity(state.indicatorOpacity)

                        shimmerLabel(sweepPosition: state.sweepPosition, isSweeping: state.isSweeping)
                            .id(label)
                            .ocBlurReplaceTransition()
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: label)
                    }
                }

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
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    @ViewBuilder
    private func shimmerLabel(sweepPosition: Double, isSweeping: Bool) -> some View {
        let baseText = Text(label)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundColor(OCColor.textPrimary)
            .lineLimit(1)

        if !reduceMotion && isVisible && isSweeping {
            let s1 = max(0.0, min(1.0, sweepPosition - 0.25))
            let s2 = max(0.0, min(1.0, sweepPosition))
            let s3 = max(0.0, min(1.0, sweepPosition + 0.25))
            let accent = IysThemePreferences.active.accent

            baseText
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: s1),
                            .init(color: accent.opacity(0.55), location: s2),
                            .init(color: .clear, location: s3),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .mask(
                        Text(label)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                    )
                )
        } else {
            baseText
        }
    }

    private func shimmerState(at date: Date) -> (sweepPosition: Double, indicatorOpacity: Double, isSweeping: Bool) {
        guard !reduceMotion && isVisible else {
            return (-0.25, 1.0, false)
        }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let cycleTime = elapsed.truncatingRemainder(dividingBy: Self.cycleDuration)
        guard cycleTime >= Self.restDuration else {
            return (-0.25, 1.0, false)
        }
        let linearT = min(1.0, max(0.0, (cycleTime - Self.restDuration) / Self.sweepDuration))
        let eased = Self.cubicBezierEase(linearT, x1: 0.4, y1: 0.0, x2: 0.2, y2: 1.0)
        let sweepPosition = -0.25 + eased * 1.50
        let indicatorOpacity = 1.0 - (1.0 - Self.minIndicatorOpacity) * sin(eased * .pi)
        return (sweepPosition, indicatorOpacity, true)
    }

    private static func cubicBezierEase(_ t: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }

        func sample(_ u: Double, p1: Double, p2: Double) -> Double {
            (((1.0 - 3.0 * p2 + 3.0 * p1) * u + (3.0 * p2 - 6.0 * p1)) * u + 3.0 * p1) * u
        }

        func slope(_ u: Double, p1: Double, p2: Double) -> Double {
            (3.0 * (1.0 - 3.0 * p2 + 3.0 * p1) * u + 2.0 * (3.0 * p2 - 6.0 * p1)) * u + 3.0 * p1
        }

        var u = t
        for _ in 0..<5 {
            let err = sample(u, p1: x1, p2: x2) - t
            let d = slope(u, p1: x1, p2: x2)
            if abs(err) < 1e-6 || abs(d) < 1e-6 { break }
            u = min(1.0, max(0.0, u - err / d))
        }
        return min(1.0, max(0.0, sample(u, p1: y1, p2: y2)))
    }
}

/// Detail sheet opened when tapping the live thinking shimmer line.
public struct AgentActivityDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let events: [TimelineEvent]

    public init(events: [TimelineEvent]) {
        self.events = events
    }

    public var body: some View {
        NavigationStack {
            let recentTools = Array(events.filter { $0.kind == .toolCall }.suffix(20).reversed())
            List {
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
                    ForEach(recentTools) { step in
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
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(reduceMotion ? nil : OCMotion.expoOut(), value: recentTools.map(\.id))
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
