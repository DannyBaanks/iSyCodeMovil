import SwiftUI

// MARK: - App Themes

public enum IysTheme: String, CaseIterable, Identifiable {
    case console
    case premium

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .console: return "Consola"
        case .premium: return "Premium"
        }
    }

    public var subtitle: String {
        switch self {
        case .console: return "Enfoque total. Estilo terminal."
        case .premium: return "Moderno. Elegante. Listo para todo."
        }
    }

    public var accent: Color {
        switch self {
        case .console: return Color(hex: "00D7A5")
        case .premium: return Color(hex: "4B8DFF")
        }
    }

    public var userSurface: Color {
        switch self {
        case .console: return Color(hex: "00D7A5", opacity: 0.12)
        case .premium: return Color(hex: "3978F6", opacity: 0.22)
        }
    }

    public var assistantSurface: Color {
        switch self {
        case .console: return Color(hex: "0D1715")
        case .premium: return Color(hex: "242B37")
        }
    }

    public var background: Color {
        switch self {
        case .console: return Color(hex: "050807")
        case .premium: return Color(hex: "101319")
        }
    }

    public var base: Color {
        switch self {
        case .console: return Color(hex: "101412")
        case .premium: return Color(hex: "1B2029")
        }
    }

    public var layer: Color {
        switch self {
        case .console: return Color(hex: "151D1A")
        case .premium: return Color(hex: "252C38")
        }
    }

    public var secondaryLayer: Color {
        switch self {
        case .console: return Color(hex: "1B2521")
        case .premium: return Color(hex: "303847")
        }
    }

    public var border: Color {
        switch self {
        case .console: return Color(hex: "00D7A5", opacity: 0.18)
        case .premium: return Color(hex: "A9B9D4", opacity: 0.16)
        }
    }

    public var usesMonospacedBody: Bool { self == .console }
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
    public static let borderStrong = Color(hex: "FFFFFF", opacity: 0.20)
    public static let textPrimary  = Color(hex: "F2F2F2")
    public static let textSecondary = Color(hex: "AEAEAE")
    public static let textFaint    = Color(hex: "808080")
    public static let iconPrimary  = Color(hex: "DBDBDB")
    public static let iconMuted    = Color(hex: "808080")

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
    public static let diffAddFg      = Color(hex: "C4FFC0")
    public static let diffDeleteFg   = Color(hex: "EC2F14")
    public static let syntaxComment  = Color(hex: "8F8F8F")
    public static let syntaxKeyword  = Color(hex: "EDB2F1")
    public static let syntaxString   = Color(hex: "00CEB9")
    public static let syntaxPrimitive = Color(hex: "8CB0FF")
    public static let syntaxProperty = Color(hex: "FAB283")
    public static let syntaxType     = Color(hex: "FCD53A")

    public static let diffAddBg      = Color(hex: "14361D", opacity: 0.60)
    public static let diffDeleteBg   = Color(hex: "461516", opacity: 0.60)
    public static let diffContextBg  = Color(hex: "161616")
    public static var diffSelectedBg: Color { theme.accent.opacity(0.10) }

    // Semantic
    public static let success        = Color(hex: "4CD97B")
    public static let warning        = Color(hex: "F7D060")
    public static let danger         = Color(hex: "FF6B6B")
    public static let info           = Color(hex: "60C8F7")

    // Liquid Glass approximations (for Figma parity; prefer system APIs in code)
    public static let glassNavFill   = Color.white.opacity(0.06)
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
    public static var r8: CGFloat  { premium ? 8 : 4 }
    public static var r10: CGFloat { premium ? 10 : 5 }
    public static var r12: CGFloat { premium ? 12 : 6 }
    public static var r14: CGFloat { premium ? 14 : 7 }
    public static var r18: CGFloat { premium ? 18 : 8 }
    public static var r22: CGFloat { premium ? 22 : 10 }
    public static var r24: CGFloat { premium ? 24 : 10 }
    public static var r28: CGFloat { premium ? 28 : 12 }
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

    /// Nombre visible en la interfaz. `rawValue` sigue siendo el identificador
    /// que se envía al backend.
    public var title: String {
        switch self {
        case .build:   return "Construir"
        case .plan:    return "Planear"
        case .explore: return "Explorar"
        case .review:  return "Revisar"
        case .custom:  return "Personalizado"
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
        case .build:   return "Edita archivos y ejecuta herramientas"
        case .plan:    return "Solo lectura: explora y planifica"
        case .explore: return "Explora el proyecto y delega subtareas"
        case .review:  return "Revisa y comprueba los cambios"
        case .custom:  return "Agente con comportamiento personalizado"
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

    /// Nombre visible en la interfaz.
    public var title: String {
        switch self {
        case .chat:      return "Chat"
        case .files:     return "Archivos"
        case .review:    return "Cambios"
        case .terminal:  return "Terminal"
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
