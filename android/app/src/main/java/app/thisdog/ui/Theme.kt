package app.thisdog.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import app.thisdog.R

/** Farben von ThisDog, Richtung „Mandarine“ – dieselben Werte wie Palette.swift. */
@Immutable
data class Palette(
    val paper: Color, val surface: Color, val ink: Color, val ink2: Color, val ink3: Color, val line: Color,
    val accent: Color, val soft: Color, val health: Color, val seasonal: Color, val warning: Color, val ok: Color,
)

val LightPalette = Palette(
    paper = Color(0xFFF6F6F8), surface = Color(0xFFFFFFFF), ink = Color(0xFF241E2B), ink2 = Color(0xFF69627A),
    ink3 = Color(0xFFA29CAF), line = Color(0xFFE8E6EE), accent = Color(0xFFEE6A24), soft = Color(0xFFFDEADF),
    health = Color(0xFFC8473D), seasonal = Color(0xFF6F86D6), warning = Color(0xFFEFAE3A), ok = Color(0xFF2F9E6B),
)

val DarkPalette = Palette(
    paper = Color(0xFF16141A), surface = Color(0xFF211E26), ink = Color(0xFFF1EEF4), ink2 = Color(0xFFB3ACBF),
    ink3 = Color(0xFF7F788B), line = Color(0xFF302B37), accent = Color(0xFFFF8746), soft = Color(0xFF3A2519),
    health = Color(0xFFF07A6E), seasonal = Color(0xFF8FA4EA), warning = Color(0xFFF4BE55), ok = Color(0xFF5CC995),
)

val LocalPalette = staticCompositionLocalOf { LightPalette }

/** Bricolage für Überschriften und große Zahlen, wie in der iOS-Fassung. */
val Display = FontFamily(Font(R.font.bricolage, FontWeight.Normal), Font(R.font.bricolage, FontWeight.Medium), Font(R.font.bricolage, FontWeight.SemiBold), Font(R.font.bricolage, FontWeight.Bold))

/** Die schmale Bricolage (Breite 80 %) für Zahlen in engen Ringen und Anzeigen – wie `width: 80` in der iOS-Fassung. */
@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
val DisplayNarrow = FontFamily(
    Font(R.font.bricolage, FontWeight.Bold, variationSettings = androidx.compose.ui.text.font.FontVariation.Settings(
        androidx.compose.ui.text.font.FontVariation.weight(700), androidx.compose.ui.text.font.FontVariation.width(80f))))

/** Die Systemschrift ohne die weite Laufweite von Material: dieselbe Dichte wie in der iOS-Fassung. */
private val AppTypography = Typography().run {
    copy(bodyLarge = bodyLarge.copy(letterSpacing = 0.sp), bodyMedium = bodyMedium.copy(letterSpacing = 0.sp), bodySmall = bodySmall.copy(letterSpacing = 0.sp),
        labelLarge = labelLarge.copy(letterSpacing = 0.sp), labelMedium = labelMedium.copy(letterSpacing = 0.sp), labelSmall = labelSmall.copy(letterSpacing = 0.sp),
        titleMedium = titleMedium.copy(letterSpacing = 0.sp), titleSmall = titleSmall.copy(letterSpacing = 0.sp))
}

@Composable
fun ThisDogTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val p = if (dark) DarkPalette else LightPalette
    val scheme = if (dark) darkColorScheme(primary = p.accent, background = p.paper, surface = p.surface, onSurface = p.ink, onBackground = p.ink)
                 else lightColorScheme(primary = p.accent, background = p.paper, surface = p.surface, onSurface = p.ink, onBackground = p.ink)
    androidx.compose.runtime.CompositionLocalProvider(LocalPalette provides p) {
        MaterialTheme(colorScheme = scheme, typography = AppTypography, content = content)
    }
}
