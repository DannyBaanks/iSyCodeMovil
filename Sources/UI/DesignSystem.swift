import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

// MARK: - Appearance (automatic dark mode)

/// Light, dark or follow the system. Colors below are dynamic, so switching
/// is instant and needs no relaunch.
public enum IysAppearance: String, CaseIterable, Identifiable {
    case automatic, dark, light

    public static let storageKey = "iyscode.appearance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automático"
        case .dark: return "Oscuro"
        case .light: return "Claro"
        }
    }

    /// nil lets iOS decide (the user's system setting).
    public var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

extension Color {
    /// A color that resolves per trait collection: one value for dark, one for light.
    public static func iys(dark: String, light: String, darkOpacity: Double = 1, lightOpacity: Double? = nil) -> Color {
        #if canImport(UIKit)
        let darkColor = UIColor(Color(hex: dark, opacity: darkOpacity))
        let lightColor = UIColor(Color(hex: light, opacity: lightOpacity ?? darkOpacity))
        return Color(UIColor { $0.userInterfaceStyle == .light ? lightColor : darkColor })
        #else
        return Color(hex: dark, opacity: darkOpacity)
        #endif
    }
}

// MARK: - App Themes

public enum IysTheme: String, CaseIterable, Identifiable {
    case console
    case premium

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .console: return "ISyCode"
        case .premium: return "Violeta"
        }
    }

    public var subtitle: String {
        switch self {
        case .console: return "Noche índigo. Acento coral."
        case .premium: return "La misma noche, acento violeta."
        }
    }

    public var accent: Color {
        switch self {
        case .console: return .iys(dark: "FF7891", light: "AD2045")
        case .premium: return .iys(dark: "BD91FF", light: "7137B5")
        }
    }

    public var userSurface: Color {
        switch self {
        case .console: return .iys(dark: "E94560", light: "D12F4E", darkOpacity: 0.16, lightOpacity: 0.10)
        case .premium: return .iys(dark: "9B5DE5", light: "7A3FC7", darkOpacity: 0.18, lightOpacity: 0.10)
        }
    }

    public var assistantSurface: Color {
        switch self {
        case .console: return .iys(dark: "242433", light: "EFEDF5")
        case .premium: return .iys(dark: "2A2438", light: "F1ECF8")
        }
    }

    public var background: Color {
        switch self {
        case .console: return .iys(dark: "12121C", light: "F6F5FA")
        case .premium: return .iys(dark: "14141F", light: "F7F5FB")
        }
    }

    public var base: Color {
        switch self {
        case .console: return .iys(dark: "1A1A2E", light: "FFFFFF")
        case .premium: return .iys(dark: "1C1A2E", light: "FFFFFF")
        }
    }

    public var layer: Color {
        switch self {
        case .console: return .iys(dark: "222236", light: "EFEDF5")
        case .premium: return .iys(dark: "262433", light: "F1ECF8")
        }
    }

    public var secondaryLayer: Color {
        switch self {
        case .console: return .iys(dark: "2C2C42", light: "E6E3EF")
        case .premium: return .iys(dark: "312A44", light: "E9E2F4")
        }
    }

    public var border: Color {
        switch self {
        case .console: return .iys(dark: "9AA3AD", light: "505A6B", darkOpacity: 0.28, lightOpacity: 0.22)
        case .premium: return .iys(dark: "9B5DE5", light: "7A3FC7", darkOpacity: 0.28, lightOpacity: 0.22)
        }
    }

    /// Prose stays in the system face. Code, tools, and meta keep the mono styles.
    public var usesMonospacedBody: Bool { false }
}

public enum IysThemePreferences {
    private static let activeKey = "iyscode.theme.active"
    public static let pendingKey = "iyscode.theme.pending"

    public static var active: IysTheme {
        get { UserDefaults.standard.string(forKey: activeKey).flatMap(IysTheme.init(rawValue:)) ?? .console }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: activeKey) }
    }

    public static var pending: IysTheme? {
        get { UserDefaults.standard.string(forKey: pendingKey).flatMap(IysTheme.init(rawValue:)) }
        set {
            if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: pendingKey) }
            else { UserDefaults.standard.removeObject(forKey: pendingKey) }
        }
    }

    /// Applies a theme selected in a previous run. iOS does not allow apps to relaunch themselves.
    public static func applyPendingOnLaunch() {
        guard let pending else { return }
        active = pending
        self.pending = nil
    }
}

// MARK: - Color Tokens (OpenCode v2 → iOS Dark Mode)

public struct OCColor {
    // Core neutrals
    private static var theme: IysTheme { IysThemePreferences.active }
    public static var bgDeep: Color { theme.background }
    public static var bgBase: Color { theme.base }
    public static var bgLayer1: Color { theme.layer }
    public static var bgLayer2: Color { theme.secondaryLayer }
    public static var borderMuted: Color { theme.border }
    public static var borderBase: Color { theme.border.opacity(0.75) }
    public static let borderStrong = Color.iys(dark: "FFFFFF", light: "1B1B28", darkOpacity: 0.20, lightOpacity: 0.18)
    public static let textPrimary  = Color.iys(dark: "E0E0E0", light: "1B1B28")
    public static let textSecondary = Color.iys(dark: "9AA3AD", light: "545C6B")
    public static let textFaint    = Color.iys(dark: "7A8490", light: "6E7684")
    public static let iconPrimary  = Color.iys(dark: "E0E0E0", light: "1B1B28")
    public static let iconMuted    = Color.iys(dark: "9AA3AD", light: "545C6B")
    /// Ink follows the luminance of the filled controls in each appearance.
    public static let onAccent     = Color.iys(dark: "23131C", light: "FFFFFF")

    // Agent / Mode colors
    public static var agentBuild: Color { theme.accent }
    public static let agentPlan    = Color.iys(dark: "F799C6", light: "902858")
    public static let agentExplore = Color.iys(dark: "F3DA9B", light: "734A12")
    public static let agentReview  = Color.iys(dark: "96E3A6", light: "245E3B")
    public static let agentCustom  = Color.iys(dark: "9E99F7", light: "553D99")

    public static var agentBuildSoft: Color { theme.accent.opacity(0.10) }
    public static let agentPlanSoft    = agentPlan.opacity(0.08)
    public static let agentExploreSoft = agentExplore.opacity(0.08)
    public static let agentReviewSoft  = agentReview.opacity(0.08)
    public static let agentCustomSoft  = agentCustom.opacity(0.08)

    public static var agentBuildBorder: Color { theme.accent.opacity(0.28) }
    public static let agentPlanBorder    = agentPlan.opacity(0.30)
    public static let agentExploreBorder = agentExplore.opacity(0.30)
    public static let agentReviewBorder  = agentReview.opacity(0.30)
    public static let agentCustomBorder  = agentCustom.opacity(0.30)

    // Syntax & Diff
    public static let diffAddFg      = Color.iys(dark: "C4FFC0", light: "166534")
    public static let diffDeleteFg   = Color.iys(dark: "EC2F14", light: "B91C1C")
    public static let syntaxComment  = Color.iys(dark: "8F8F8F", light: "6B7280")
    public static let syntaxKeyword  = Color.iys(dark: "EDB2F1", light: "9D174D")
    public static let syntaxString   = Color.iys(dark: "00CEB9", light: "0F766E")
    public static let syntaxPrimitive = Color.iys(dark: "8CB0FF", light: "1D4ED8")
    public static let syntaxProperty = Color.iys(dark: "FAB283", light: "C2410C")
    public static let syntaxType     = Color.iys(dark: "FCD53A", light: "A16207")

    public static let diffAddBg      = Color.iys(dark: "14361D", light: "DCFCE7", darkOpacity: 0.60, lightOpacity: 1)
    public static let diffDeleteBg   = Color.iys(dark: "461516", light: "FEE2E2", darkOpacity: 0.60, lightOpacity: 1)
    public static let diffContextBg  = Color.iys(dark: "161616", light: "F4F3F8")
    public static var diffSelectedBg: Color { theme.accent.opacity(0.10) }

    // Semantic
    public static let success        = Color.iys(dark: "4ADE80", light: "15803D")
    public static let warning        = Color.iys(dark: "FBBF24", light: "A16207")
    public static let danger         = Color.iys(dark: "F87171", light: "C62828")
    public static let info           = Color.iys(dark: "22D3EE", light: "0E7490")

    // Liquid Glass approximations (for Figma parity; prefer system APIs in code)
    public static let glassNavFill   = Color.iys(dark: "FFFFFF", light: "FFFFFF", darkOpacity: 0.06, lightOpacity: 0.55)
    public static let glassNavBlur: CGFloat = 28
    public static let glassNavHighlight = Color.white.opacity(0.10)
    public static let glassNavStroke = Color.white.opacity(0.12)
    public static let glassNavShadow = Color.black.opacity(0.20)
}

extension Color {
    public init(hex: String, opacity: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Spacing Tokens

public struct OCSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 6
    public static let base: CGFloat = 8
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 12
    public static let xl: CGFloat = 16
    public static let xxl: CGFloat = 20
    public static let xxxl: CGFloat = 24
    public static let huge: CGFloat = 32

    public static let contentMargin: CGFloat = 16
    public static let compactMargin: CGFloat = 12
    public static let timelineEventGap: CGFloat = 20
    public static let timelineBlockGap: CGFloat = 10
    public static let toolClusterGap: CGFloat = 6
}

// MARK: - Radius Tokens

public struct OCRadius {
    public static let r4: CGFloat  = 4
    private static var premium: Bool { IysThemePreferences.active == .premium }
    public static var r8: CGFloat  { premium ? 12 : 10 }
    public static var r10: CGFloat { premium ? 14 : 12 }
    public static var r12: CGFloat { premium ? 16 : 14 }
    public static var r14: CGFloat { premium ? 18 : 16 }
    public static var r18: CGFloat { premium ? 22 : 18 }
    public static var r22: CGFloat { premium ? 26 : 22 }
    public static var r24: CGFloat { premium ? 28 : 24 }
    public static var r28: CGFloat { premium ? 32 : 26 }
}

// MARK: - Typography Tokens

public struct OCTypography {
    // Every token is a Dynamic Type text style, so it follows the size the person picks in
    // Settings > Display & Text Size. Sizes at the default setting: body 17, callout 16,
    // subheadline 15, footnote 13, caption 12, caption2 11.
    // Monospaced is reserved for code, diffs and file paths. Prose, labels, status and
    // pills use the system face; numbers that tick (times, durations, counts) use
    // monospaced digits so they do not jitter.

    // Font families
    public static let ui = Font.system(.body, design: .default)
    public static let mono = Font.system(.body, design: .monospaced)
    private static var bodyDesign: Font.Design { IysThemePreferences.active.usesMonospacedBody ? .monospaced : .default }

    // Style definitions
    public static var navTitle: Font { Font.system(.subheadline, design: bodyDesign, weight: .semibold) }
    public static let navSubtitle    = Font.system(.caption2, design: .default, weight: .regular)
    public static var body: Font { Font.system(.callout, design: bodyDesign, weight: .regular) }
    public static var bodyStrong: Font { Font.system(.callout, design: bodyDesign, weight: .semibold) }
    public static var userPrompt: Font { Font.system(.callout, design: bodyDesign, weight: .regular) }
    public static let meta           = Font.system(.caption2, design: .default, weight: .regular)
    /// Kept for existing call sites: times, durations and counts. System face, fixed-width digits.
    public static let metaMono       = Font.system(.caption2, design: .default, weight: .regular).monospacedDigit()
    public static var control: Font { Font.system(.caption, design: bodyDesign, weight: .medium) }
    public static let controlMono    = Font.system(.caption2, design: .monospaced, weight: .medium)
    public static let code           = Font.system(.footnote, design: .monospaced, weight: .regular)
    public static let codeSmall      = Font.system(.caption, design: .monospaced, weight: .regular)
    public static let sectionLabel   = Font.system(.caption2, design: .default, weight: .semibold)
    public static var rowPrimary: Font { Font.system(.subheadline, design: bodyDesign, weight: .semibold) }
    public static let rowSecondary   = Font.system(.caption2, design: .default, weight: .regular)
    public static let pillLabel      = Font.system(.caption2, design: .default, weight: .medium)
    public static let modelPillLabel = Font.system(.caption2, design: .default, weight: .regular)
    public static let toolLabel      = Font.system(.footnote, design: .default, weight: .medium)
    public static let toolDetail     = Font.system(.caption, design: .default, weight: .regular)
    public static let diffHeader     = Font.system(.caption, design: .monospaced, weight: .regular)
    public static let diffLineNum    = Font.system(.caption2, design: .monospaced, weight: .regular)
    public static let diffCode       = Font.system(.footnote, design: .monospaced, weight: .regular)
    public static let fileRow        = Font.system(.footnote, design: .monospaced, weight: .regular)
    public static let permissionTitle = Font.system(.subheadline, design: .default, weight: .semibold)
    public static let permissionBody  = Font.system(.footnote, design: .default, weight: .regular)
    public static let questionChoice  = Font.system(.subheadline, design: .default, weight: .regular)
    public static let todoText        = Font.system(.footnote, design: .default, weight: .regular)
    public static let todoMeta        = Font.system(.caption2, design: .default, weight: .regular).monospacedDigit()
}

// MARK: - Shadow / Elevation

public struct OCShadow {
    public static let composer = ShadowStyle(
        color: Color.black.opacity(0.18),
        radius: 18,
        x: 0,
        y: -4
    )
    public static let elevated = ShadowStyle(
        color: Color.black.opacity(0.25),
        radius: 12,
        x: 0,
        y: 4
    )
    public static let navGlass = ShadowStyle(
        color: Color.black.opacity(0.20),
        radius: 24,
        x: 0,
        y: 8
    )
}

public struct ShadowStyle {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
}

// MARK: - Agent Mode Enum

public enum AgentMode: String, CaseIterable, Identifiable, Sendable {
    case build   = "build"
    case plan    = "plan"
    case explore = "explore"
    case review  = "review"
    case custom  = "custom"

    public var displayName: String {
        switch self {
        case .build: return "Construir"
        case .plan: return "Plan"
        case .explore: return "Explorar"
        case .review: return "Revisar"
        case .custom: return "Personalizado"
        }
    }

    public var id: String { rawValue }

    public var color: Color {
        switch self {
        case .build:   return OCColor.agentBuild
        case .plan:    return OCColor.agentPlan
        case .explore: return OCColor.agentExplore
        case .review:  return OCColor.agentReview
        case .custom:  return OCColor.agentCustom
        }
    }

    public var softColor: Color {
        switch self {
        case .build:   return OCColor.agentBuildSoft
        case .plan:    return OCColor.agentPlanSoft
        case .explore: return OCColor.agentExploreSoft
        case .review:  return OCColor.agentReviewSoft
        case .custom:  return OCColor.agentCustomSoft
        }
    }

    public var borderColor: Color {
        switch self {
        case .build:   return OCColor.agentBuildBorder
        case .plan:    return OCColor.agentPlanBorder
        case .explore: return OCColor.agentExploreBorder
        case .review:  return OCColor.agentReviewBorder
        case .custom:  return OCColor.agentCustomBorder
        }
    }

    public var description: String {
        switch self {
        case .build:   return "Can edit files and run tools"
        case .plan:    return "Read-only exploration and planning"
        case .explore: return "Exploration and sub-agent tasks"
        case .review:  return "Review and check changes"
        case .custom:  return "Custom agent behavior"
        }
    }

    public var icon: String {
        switch self {
        case .build:   return "hammer.fill"
        case .plan:    return "doc.text.magnifyingglass"
        case .explore: return "map.fill"
        case .review:  return "checkmark.seal.fill"
        case .custom:  return "sparkles"
        }
    }
}

// MARK: - Tool Call State

public enum ToolCallState: String, Sendable {
    case running
    case success
    case failed
    case permission

    public var color: Color {
        switch self {
        case .running:    return OCColor.agentBuild
        case .success:    return OCColor.success
        case .failed:     return OCColor.danger
        case .permission: return OCColor.warning
        }
    }

    public var title: String {
        switch self {
        case .running:    return "En curso"
        case .success:    return "Listo"
        case .failed:     return "Falló"
        case .permission: return "Permiso"
        }
    }

    public var icon: String {
        switch self {
        case .running:    return "circle.dotted"
        case .success:    return "checkmark"
        case .failed:     return "xmark"
        case .permission: return "exclamationmark.shield"
        }
    }
}

// MARK: - Timeline Event Types

public enum TimelineEventKind: String, Sendable {
    case userPrompt
    case assistantText
    case toolCall
    case toolResult
    case diff
    case codeBlock
    case permission
    case question
    case thinking
    case todo
    case system
}

// MARK: - Work Surface

public enum WorkSurface: String, CaseIterable, Identifiable, Sendable {
    case chat    = "Chat"
    case files   = "Files"
    case review  = "Review"
    case terminal = "Terminal"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat: return "Chat"
        case .files: return "Archivos"
        case .review: return "Revisión"
        case .terminal: return "Terminal"
        }
    }

    public var icon: String {
        switch self {
        case .chat:      return "bubble.left.and.bubble.right"
        case .files:     return "doc.text"
        case .review:    return "arrow.left.arrow.right"
        case .terminal:  return "terminal"
        }
    }
}

// MARK: - View Modifiers for consistent styling

public struct OCNavGlassModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(
                OCColor.glassNavFill
                    .background(.ultraThinMaterial)
            )
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )
    }
}

public struct OCCardStyle: ViewModifier {
    let radius: CGFloat
    let border: Color
    let background: Color

    public init(radius: CGFloat = OCRadius.r12, border: Color = OCColor.borderBase, background: Color = OCColor.bgBase) {
        self.radius = radius
        self.border = border
        self.background = background
    }

    public func body(content: Content) -> some View {
        content
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(border, lineWidth: 1)
            )
    }
}

public struct OCPillStyle: ViewModifier {
    let height: CGFloat
    let radius: CGFloat
    let background: Color
    let border: Color
    let horizontalPadding: CGFloat

    public init(
        height: CGFloat = 28,
        radius: CGFloat = OCRadius.r14,
        background: Color = OCColor.bgLayer1,
        border: Color = OCColor.borderBase,
        horizontalPadding: CGFloat = 9
    ) {
        self.height = height
        self.radius = radius
        self.background = background
        self.border = border
        self.horizontalPadding = horizontalPadding
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(border, lineWidth: 1)
            )
    }
}

extension View {
    public func ocNavGlass() -> some View { modifier(OCNavGlassModifier()) }
    public func ocCard(radius: CGFloat = OCRadius.r12, border: Color = OCColor.borderBase, background: Color = OCColor.bgBase) -> some View {
        modifier(OCCardStyle(radius: radius, border: border, background: background))
    }
    public func ocPill(height: CGFloat = 28, radius: CGFloat = OCRadius.r14, background: Color = OCColor.bgLayer1, border: Color = OCColor.borderBase, horizontalPadding: CGFloat = 9) -> some View {
        modifier(OCPillStyle(height: height, radius: radius, background: background, border: border, horizontalPadding: horizontalPadding))
    }
    public func ocInteractivePress(scale: CGFloat = 0.97) -> some View {
        buttonStyle(OCInteractiveButtonStyle(scale: scale))
    }
    public func ocSkeleton(_ isLoading: Bool) -> some View {
        modifier(OCSkeletonModifier(isLoading: isLoading))
    }
}

// MARK: - Flow Layout (chips that wrap)

/// Places subviews left to right and wraps to a new line when the next one does not fit,
/// centering each line vertically. Chip rows use it so a larger Dynamic Type size wraps
/// the chips instead of truncating them to "Con…". A subview wider than the whole row is
/// offered the row width (so its own lineLimit/truncation applies).
public struct OCFlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = OCSpacing.base, lineSpacing: CGFloat = OCSpacing.base) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        func closeLine(upTo end: Int) {
            // Center every item of the finished line inside the line's height.
            for i in lineStart..<end {
                frames[i].origin.y = y + (lineHeight - frames[i].height) / 2
            }
        }

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if maxWidth.isFinite, size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if x > 0, x + size.width > maxWidth {
                closeLine(upTo: frames.count)
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
                lineStart = frames.count
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        closeLine(upTo: frames.count)
        return (frames, CGSize(width: widest, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}

public enum OCNavigation {
    public static let drawerWidth: CGFloat = 320
    public static let dismissGutter: CGFloat = 48
    public static let edgeActivation: CGFloat = 24
    /// Projected travel (pt) past which a release commits the drawer.
    public static let drawerCommitDistance: CGFloat = 72
    /// A release faster than this (pt/s) commits regardless of distance.
    public static let drawerFlickVelocity: CGFloat = 800
}

// MARK: - 2026 Motion, Haptics & Reusable State Primitives

/// One curve for every time-driven movement, at three lengths. Entrances and state changes
/// use a strong ease-out (0.23, 1, 0.32, 1) — nothing in the app eases in. Anything a finger
/// releases settles with `drawerSpring` instead, so it carries the gesture velocity.
public enum OCMotion {
    public static let drawer = Animation.timingCurve(0.20, 0.75, 0.25, 1, duration: 0.25)
    /// Critically damped spring for the drawer release; callers seed it with release velocity.
    public static func drawerSpring(velocity: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: 460, damping: 32, initialVelocity: velocity)
    }
    public static let curve = (x1: 0.23, y1: 1.0, x2: 0.32, y2: 1.0)
    public static func timed(_ duration: Double) -> Animation {
        .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)
    }
    public static let snappy = timed(0.2)
    public static let smooth = timed(0.3)
    public static let gentle = timed(0.45)

    public static func perform(_ animation: Animation = OCMotion.smooth, reduceMotion: Bool = false, _ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(animation, updates)
        }
    }
}

public enum OCHaptics {
    public static func light() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    public static func medium() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    public static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    public static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    public static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    public static func error() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    // MARK: Designed patterns (Core Haptics)
    // Muse ships an AHAP per moment (prompt sent, each reaction). Three moments matter here.

    /// The message left: a firm tap and a soft echo.
    public static func sent() {
        play([(0.0, 0.7, 0.6), (0.07, 0.35, 0.3)], fallback: light)
    }

    /// The agent finished: two gentle rising taps.
    public static func done() {
        play([(0.0, 0.35, 0.4), (0.11, 0.6, 0.55)], fallback: success)
    }

    /// The agent needs the person (permission, question): three quick, sharper taps.
    public static func attention() {
        play([(0.0, 0.8, 0.8), (0.09, 0.6, 0.8), (0.18, 0.8, 0.8)], fallback: warning)
    }

    /// (time s, intensity 0...1, sharpness 0...1) transients.
    private static func play(_ taps: [(Double, Float, Float)], fallback: () -> Void) {
        #if canImport(CoreHaptics) && canImport(UIKit)
        guard OCHapticPlayer.shared.play(taps) else { return fallback() }
        #else
        fallback()
        #endif
    }
}

#if canImport(CoreHaptics) && canImport(UIKit)
/// Keeps one haptic engine alive and restarts it after the system stops or resets it.
final class OCHapticPlayer {
    static let shared = OCHapticPlayer()
    private var engine: CHHapticEngine?

    /// False when the device has no Core Haptics or the pattern failed (the caller falls back).
    func play(_ taps: [(Double, Float, Float)]) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }
        do {
            let engine = try runningEngine()
            let events = taps.map { time, intensity, sharpness in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ], relativeTime: time)
            }
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            self.engine = nil
            return false
        }
    }

    private func runningEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak self] in self?.engine = nil }
        engine.stoppedHandler = { [weak self] _ in self?.engine = nil }
        try engine.start()
        self.engine = engine
        return engine
    }
}
#endif

public struct OCInteractiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scale: CGFloat

    public init(scale: CGFloat = 0.97) {
        self.scale = scale
    }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(reduceMotion ? nil : OCMotion.snappy, value: configuration.isPressed)
    }
}

public struct OCSkeletonModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isLoading: Bool
    @State private var phase: CGFloat = -0.8

    public init(isLoading: Bool) {
        self.isLoading = isLoading
    }

    public func body(content: Content) -> some View {
        if isLoading {
            content
                .redacted(reason: .placeholder)
                .overlay(
                    Group {
                        if !reduceMotion {
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.14), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .offset(x: phase * 220)
                            .mask(content)
                        }
                    }
                )
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                        phase = 1.2
                    }
                }
        } else {
            content
        }
    }
}

/// Complete visual state taxonomy required across primary surfaces (Section 13).
public enum OCVisualStateKind: String, Sendable {
    case empty
    case loading
    case ready
    case running
    case offline
    case error
    case retry
    case permissionRequired
    case cancelled
    case completed

    public var symbol: String {
        switch self {
        case .empty: return "sparkles.rectangle.stack"
        case .loading: return "hourglass"
        case .ready: return "checkmark.circle.fill"
        case .running: return "bolt.horizontal.circle.fill"
        case .offline: return "wifi.slash"
        case .error, .retry: return "exclamationmark.triangle.fill"
        case .permissionRequired: return "hand.raised.fill"
        case .cancelled: return "stop.circle.fill"
        case .completed: return "checkmark.seal.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .empty: return IysThemePreferences.active.accent
        case .loading, .running: return OCColor.info
        case .ready, .completed: return OCColor.success
        case .offline, .permissionRequired: return OCColor.warning
        case .error, .retry: return OCColor.danger
        case .cancelled: return OCColor.textSecondary
        }
    }
}

/// Human-friendly state card with optional action CTA and collapsible technical diagnostics.
public struct OCUnifiedStateCard: View {
    let kind: OCVisualStateKind
    let title: String
    let message: String
    let technicalDetail: String?
    let actionTitle: String?
    let actionSymbol: String?
    let action: (() -> Void)?
    @State private var showTechnical = false

    public init(
        kind: OCVisualStateKind,
        title: String,
        message: String,
        technicalDetail: String? = nil,
        actionTitle: String? = nil,
        actionSymbol: String? = "arrow.clockwise",
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.technicalDetail = technicalDetail
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack(alignment: .top, spacing: OCSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: OCRadius.r10)
                        .fill(kind.tint.opacity(0.14))
                        .frame(width: 40, height: 40)
                    if kind == .loading || kind == .running {
                        ProgressView()
                            .tint(kind.tint)
                    } else {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(kind.tint)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(message)
                        .font(.system(size: 13.5))
                        .foregroundColor(OCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let actionTitle, let action {
                Button {
                    OCHaptics.light()
                    action()
                } label: {
                    HStack(spacing: 6) {
                        if let actionSymbol {
                            Image(systemName: actionSymbol)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(actionTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(kind.tint.gradient)
                    .clipShape(Capsule())
                }
                .buttonStyle(OCInteractiveButtonStyle())
            }

            if let technicalDetail, !technicalDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("Ver detalles técnicos", isExpanded: $showTechnical) {
                    Text(technicalDetail)
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textFaint)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(OCSpacing.sm)
                        .background(OCColor.bgDeep)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r8))
                        .padding(.top, 4)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(OCColor.textSecondary)
            }
        }
        .padding(OCSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCard(radius: OCRadius.r14, border: kind.tint.opacity(0.28), background: OCColor.bgBase)
    }
}
