package dev.iyscode.movil.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Night palette shared with the iOS app (Sources/UI/DesignSystem.swift, theme ISyCode). */
object Iys {
    val accent = Color(0xFFE94560)
    val accentSoft = Color(0x29E94560)
    val violet = Color(0xFF9B5DE5)
    val bgDeep = Color(0xFF12121C)
    val bgBase = Color(0xFF1A1A2E)
    val surface = Color(0xFF242433)
    val surfaceHigh = Color(0xFF2C2C42)
    val border = Color(0x479AA3AD)
    val textPrimary = Color(0xFFE0E0E0)
    val textSecondary = Color(0xFF9AA3AD)
    val textFaint = Color(0xFF7A8490)
    val onAccent = Color(0xFFF7F4EF)
    val green = Color(0xFF4ADE80)
    val yellow = Color(0xFFFBBF24)
    val red = Color(0xFFF87171)
    val orange = Color(0xFFFB923C)
    val purple = Color(0xFF9B5DE5)
    val blue = Color(0xFF22D3EE)
}

private val typography = Typography(
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
fun IysTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Iys.accent,
            onPrimary = Iys.onAccent,
            secondary = Iys.accent,
            background = Iys.bgDeep,
            onBackground = Iys.textPrimary,
            surface = Iys.bgBase,
            onSurface = Iys.textPrimary,
            surfaceVariant = Iys.surface,
            onSurfaceVariant = Iys.textSecondary,
            surfaceContainer = Iys.bgBase,
            surfaceContainerHigh = Iys.surface,
            outline = Iys.border,
            error = Iys.red,
        ),
        typography = typography,
        content = content,
    )
}
