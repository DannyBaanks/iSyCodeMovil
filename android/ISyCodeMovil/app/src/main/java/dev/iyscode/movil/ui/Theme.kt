package dev.iyscode.movil.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import dev.iyscode.movil.assistant.Appearance

/** One set of colors. Night matches the iOS app (Sources/UI/DesignSystem.swift, theme ISyCode). */
data class IysPalette(
    val dark: Boolean,
    val accent: Color,
    val accentSoft: Color,
    val violet: Color,
    val bgDeep: Color,
    val bgBase: Color,
    val surface: Color,
    val surfaceHigh: Color,
    val border: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textFaint: Color,
    val onAccent: Color,
    val green: Color,
    val yellow: Color,
    val red: Color,
    val orange: Color,
    val blue: Color,
)

val NightPalette = IysPalette(
    dark = true,
    accent = Color(0xFFE94560), accentSoft = Color(0x29E94560), violet = Color(0xFF9B5DE5),
    bgDeep = Color(0xFF12121C), bgBase = Color(0xFF1A1A2E), surface = Color(0xFF242433), surfaceHigh = Color(0xFF2C2C42),
    border = Color(0x479AA3AD), textPrimary = Color(0xFFE0E0E0), textSecondary = Color(0xFF9AA3AD), textFaint = Color(0xFF7A8490),
    onAccent = Color(0xFFF7F4EF), green = Color(0xFF4ADE80), yellow = Color(0xFFFBBF24), red = Color(0xFFF87171),
    orange = Color(0xFFFB923C), blue = Color(0xFF22D3EE),
)

/** Day: same coral and violet, deepened so text on white keeps AA contrast. */
val DayPalette = IysPalette(
    dark = false,
    accent = Color(0xFFD12F4E), accentSoft = Color(0x1FD12F4E), violet = Color(0xFF7A3FC7),
    bgDeep = Color(0xFFF6F5FA), bgBase = Color(0xFFFFFFFF), surface = Color(0xFFEFEDF5), surfaceHigh = Color(0xFFE6E3EF),
    border = Color(0x33505A6B), textPrimary = Color(0xFF1B1B28), textSecondary = Color(0xFF545C6B), textFaint = Color(0xFF6E7684),
    onAccent = Color(0xFFFFFFFF), green = Color(0xFF15803D), yellow = Color(0xFFA16207), red = Color(0xFFC62828),
    orange = Color(0xFFC2410C), blue = Color(0xFF0E7490),
)

/**
 * Palette tokens. [palette] is set once per activity by [IysTheme]; changing
 * the appearance recreates the activity, so every screen redraws with it.
 */
object Iys {
    var palette: IysPalette = NightPalette
    val dark get() = palette.dark
    val accent get() = palette.accent
    val accentSoft get() = palette.accentSoft
    val violet get() = palette.violet
    val bgDeep get() = palette.bgDeep
    val bgBase get() = palette.bgBase
    val surface get() = palette.surface
    val surfaceHigh get() = palette.surfaceHigh
    val border get() = palette.border
    val textPrimary get() = palette.textPrimary
    val textSecondary get() = palette.textSecondary
    val textFaint get() = palette.textFaint
    val onAccent get() = palette.onAccent
    val green get() = palette.green
    val yellow get() = palette.yellow
    val red get() = palette.red
    val orange get() = palette.orange
    val purple get() = palette.violet
    val blue get() = palette.blue
}

private val typography = Typography(
    headlineSmall = TextStyle(fontWeight = FontWeight.Bold, fontSize = 24.sp, lineHeight = 30.sp, letterSpacing = (-0.3).sp),
    titleLarge = TextStyle(fontWeight = FontWeight.ExtraBold, fontSize = 22.sp, letterSpacing = 1.2.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 16.sp),
    bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 13.sp),
    labelMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 12.sp),
    labelSmall = TextStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 10.sp),
)

@Composable
fun IysTheme(appearance: Appearance = Appearance.AUTO, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        Appearance.DARK -> true
        Appearance.LIGHT -> false
        Appearance.AUTO -> isSystemInDarkTheme()
    }
    val p = if (dark) NightPalette else DayPalette
    Iys.palette = p
    val scheme = if (dark) {
        darkColorScheme(
            primary = p.accent, onPrimary = p.onAccent, secondary = p.violet, background = p.bgDeep, onBackground = p.textPrimary,
            surface = p.bgBase, onSurface = p.textPrimary, surfaceVariant = p.surface, onSurfaceVariant = p.textSecondary,
            surfaceContainer = p.bgBase, surfaceContainerHigh = p.surface, outline = p.border, error = p.red,
        )
    } else {
        lightColorScheme(
            primary = p.accent, onPrimary = p.onAccent, secondary = p.violet, background = p.bgDeep, onBackground = p.textPrimary,
            surface = p.bgBase, onSurface = p.textPrimary, surfaceVariant = p.surface, onSurfaceVariant = p.textSecondary,
            surfaceContainer = p.bgBase, surfaceContainerHigh = p.surface, outline = p.border, error = p.red,
        )
    }
    MaterialTheme(colorScheme = scheme, typography = typography, content = content)
}
