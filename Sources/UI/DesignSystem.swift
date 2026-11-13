import SwiftUI
#if canImport(UIKit)
import UIKit
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
        case .console: return .iys(dark: "E94560", light: "D12F4E")
        case .premium: return .iys(dark: "9B5DE5", light: "7A3FC7")
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
    /// Ink that sits on a filled accent. Coral and violet both need light text.
    public static let onAccent     = Color(hex: "F7F4EF")

    // Agent / Mode colors
    public static var agentBuild: Color { theme.accent }
    public static let agentPlan    = Color(hex: "F799C6")
    public static let agentExplore = Color(hex: "F3DA9B")
    public static let agentReview  = Color(hex: "96E3A6")
    public static let agentCustom  = Color(hex: "9E99F7")

    public static var agentBuildSoft: Color { theme.accent.opacity(0.10) }
    public static let agentPlanSoft    = Color(hex: "F799C6", opacity: 0.08)
    public static let agentExploreSoft = Color(hex: "F3DA9B", opacity: 0.08)
    public static let agentReviewSoft  = Color(hex: "96E3A6", opacity: 0.08)
    public static let agentCustomSoft  = Color(hex: "9E99F7", opacity: 0.08)

    public static var agentBuildBorder: Color { theme.accent.opacity(0.28) }
    public static let agentPlanBorder    = Color(hex: "F799C6", opacity: 0.30)
    public static let agentExploreBorder = Color(hex: "F3DA9B", opacity: 0.30)
    public static let agentReviewBorder  = Color(hex: "96E3A6", opacity: 0.30)
    public static let agentCustomBorder  = Color(hex: "9E99F7", opacity: 0.30)

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
    // Font families
    public static let ui = Font.system(.body, design: .default)
    public static let mono = Font.system(.body, design: .monospaced)
    private static var bodyDesign: Font.Design { IysThemePreferences.active.usesMonospacedBody ? .monospaced : .default }

    // Style definitions
    public static var navTitle: Font { Font.system(size: 15, weight: .semibold, design: bodyDesign) }
    public static let navSubtitle    = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static var body: Font { Font.system(size: 15, weight: .regular, design: IysThemePreferences.active.usesMonospacedBody ? .monospaced : .default) }
    public static var bodyStrong: Font { Font.system(size: 15, weight: .semibold, design: bodyDesign) }
    public static var userPrompt: Font { Font.system(size: 15, weight: .medium, design: IysThemePreferences.active.usesMonospacedBody ? .monospaced : .default) }
    public static let meta           = Font.system(size: 11, weight: .regular, design: .default)
    public static let metaMono       = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static var control: Font { Font.system(size: 12, weight: .medium, design: bodyDesign) }
    public static let controlMono    = Font.system(size: 11, weight: .medium, design: .monospaced)
    public static let code           = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let codeSmall      = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let sectionLabel   = Font.system(size: 11, weight: .semibold, design: .default)
    public static var rowPrimary: Font { Font.system(size: 14.5, weight: .semibold, design: bodyDesign) }
    public static let rowSecondary   = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let pillLabel      = Font.system(size: 11, weight: .medium, design: .monospaced)
    public static let modelPillLabel = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let toolLabel      = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let toolDetail     = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let diffHeader     = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let diffLineNum    = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let diffCode       = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let fileRow        = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let permissionTitle = Font.system(size: 14, weight: .semibold, design: .default)
    public static let permissionBody  = Font.system(size: 12.5, weight: .regular, design: .default)
    public static let questionChoice  = Font.system(size: 14, weight: .regular, design: .default)
    public static let todoText        = Font.system(size: 12.5, weight: .regular, design: .default)
    public static let todoMeta        = Font.system(size: 10.5, weight: .regular, design: .monospaced)
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

    public var displayName: String { rawValue }

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
}
