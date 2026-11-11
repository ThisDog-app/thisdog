package app.thisdog.ui

import app.thisdog.i18n.L
import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.R
import app.thisdog.model.Day
import java.util.Base64
import kotlin.math.cos
import kotlin.math.sin

/** Die Icons im Strich des Logos; die Werte sind ihre Namen aus der iOS-Fassung. Füllung und Umriss werden nie gemischt. */
object Sym {
    const val HOME = "heute"; const val CALENDAR = "kalender"; const val ROUTE = "gassi"; const val PAW = "hund"; const val BOOK = "wissen"
    const val BELL = "glocke"; const val GROUP = "rudel"; const val ADD = "plus"; const val EDIT = "stift"; const val HEART = "herz"
    const val SEARCH = "lupe"; const val CLOSE = "kreuz"; const val CLEAR = "kreuz-kreis"; const val LEFT = "chevron-links"; const val RIGHT = "chevron-rechts"
    const val CAMERA = "kamera"; const val GALLERY = "foto"; const val VACCINE = "spritze"; const val PILL = "tablette"; const val MED = "flaeschchen"
    const val EMERGENCY = "notfall"; const val SHARE = "teilen"; const val CHECK = "haken"; const val CHECK_CIRCLE = "haken-kreis"; const val KEY = "schluessel"
    const val PERSON_ADD = "person-plus"; const val PERSON_REMOVE = "person-minus"; const val MAP = "karte"; const val DELETE = "muell"; const val MY_LOCATION = "ort"
    const val PLACE = "pin"; const val PIN = "pin"; const val PARK = "park"; const val TREE = "park"; const val FENCE = "zaun"; const val WATER = "tropfen"
    const val SPARKLE = "sauber"; const val GRASS = "blatt"; const val CHAIR = "bank"; const val DRINK = "napf"; const val BAG = "beutel"; const val BULB = "lampe"; const val SPLIT = "teilung"
    const val WARNING = "warnung"; const val ALERT = "ausruf"; const val BADGE = "abzeichen"; const val SUN = "sonne"; const val RATE = "schreiben"; const val FLAG = "melden"
    const val SHIELD = "pruefung"; const val SETTINGS = "einstellungen"; const val COPY = "kopieren"; const val PRINT = "drucker"; const val COMPASS = "kompass"; const val OFFLINE = "offline"
}

/** Ein Icon im Stil des Logos: eine durchgehende, runde Linie. Die Farbe kommt beim Zeichnen dazu. */
@Composable
fun LineIcon(name: String, tint: Color, size: Dp = 24.dp, modifier: Modifier = Modifier) =
    Image(painterResource(lineIconRes(name)), null, modifier.size(size), colorFilter = ColorFilter.tint(tint))

/** Dasselbe mit der Größe in sp, wo ein Icon neben Text steht. Unter 20 wird der Strich dünner als das Logo und verliert dessen Wirkung. */
@Composable
fun Icon(sym: String, color: Color, size: TextUnit = 24.sp, modifier: Modifier = Modifier) = LineIcon(sym, color, size.value.coerceAtLeast(20f).dp, modifier)

/** Stella als Logo aus einer Linie. Sie wippt leicht und freut sich über jeden Schritt; bei ausgeschalteten Animationen bleibt sie still. */
@Composable
fun StellaMark(wiggle: Int, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val still = remember { android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    val breath by rememberInfiniteTransition(label = "atem").animateFloat(-1.5f, 1.5f, infiniteRepeatable(tween(1600, easing = EaseInOut), RepeatMode.Reverse), label = "atem")
    val kick = remember { Animatable(0f) }
    var first by remember { mutableStateOf(true) }
    LaunchedEffect(wiggle) {
        if (first || still) { first = false; return@LaunchedEffect }
        kick.animateTo(-5f, tween(100)); kick.animateTo(4f, tween(140)); kick.animateTo(0f, tween(200))
    }
    Image(painterResource(R.drawable.stella_mark), null, modifier.graphicsLayer {
        rotationZ = (if (still) 0f else breath) + kick.value
        transformOrigin = TransformOrigin(.5f, 1f)
    }, contentScale = ContentScale.Fit, colorFilter = ColorFilter.tint(p.accent))
}

/** Text in einer Zeile, der lieber kleiner wird, als abgeschnitten zu werden. */
@Composable
fun FitText(text: String, style: TextStyle, modifier: Modifier = Modifier, minSize: TextUnit = 12.sp) =
    BasicText(text, modifier, style = style, maxLines = 1, softWrap = false, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, autoSize = TextAutoSize.StepBased(minSize, style.fontSize, 1.sp))

/** Wenig Höhe, viel Breite: das Telefon quer. Wie `verticalSizeClass == .compact` auf iOS. */
@Composable
fun isQuer(): Boolean = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp < 480

/** Wie viel Platz die Leiste braucht: unten über der Navigationsleiste, oder rechts, wenn sie quer senkrecht steht. */
data class DockSpace(val bottom: Dp = 0.dp, val end: Dp = 0.dp)
val LocalDock = androidx.compose.runtime.staticCompositionLocalOf { DockSpace() }

/** So viel Abstand braucht eine Seite unten, damit ihr Ende nicht hinter der Leiste liegt. */
@Composable
fun dockClearance(extra: Dp = 24.dp): Dp {
    val nav = with(androidx.compose.ui.platform.LocalDensity.current) { WindowInsets.navigationBars.getBottom(this).toDp() }
    return LocalDock.current.bottom + nav + extra
}

/** Ein bildschirmfüllendes Fenster hat eigene Systemleisten: dunkle Zeichen auf hellem Grund, quer ohne Statusleiste. */
@Composable
fun DialogBars() {
    val view = androidx.compose.ui.platform.LocalView.current
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val quer = isQuer()
    LaunchedEffect(quer, dark) {
        (view.parent as? androidx.compose.ui.window.DialogWindowProvider)?.window?.let { w ->
            val c = androidx.core.view.WindowCompat.getInsetsController(w, view)
            c.isAppearanceLightStatusBars = !dark; c.isAppearanceLightNavigationBars = !dark
            c.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (quer) c.hide(androidx.core.view.WindowInsetsCompat.Type.statusBars())
        }
    }
}

/** Der Hauptknopf: voll Mandarine, eine Kapsel. */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val p = LocalPalette.current
    Button(onClick, modifier.fillMaxWidth().height(52.dp), enabled = enabled, shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) {
        Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Ein Textfeld ohne Rahmen auf weißer Fläche. */
@Composable
fun SoftField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, textStyle: TextStyle? = null, singleLine: Boolean = true, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default) {
    val p = LocalPalette.current
    val style = (textStyle ?: TextStyle(fontSize = 17.sp)).copy(color = p.ink)
    androidx.compose.foundation.text.BasicTextField(value, onChange, modifier.fillMaxWidth(), textStyle = style, singleLine = singleLine, keyboardOptions = keyboard,
        cursorBrush = androidx.compose.ui.graphics.SolidColor(p.accent), decorationBox = { inner ->
            Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.surface).padding(14.dp)) {
                if (value.isEmpty()) Text(placeholder, style = style.copy(color = p.ink3))
                inner()
            }
        })
}

/** Ein Reiter: gleich auf Gassi und beim Hund. */
/** Die Markierung des gewählten Eintrags – gleich in der Leiste unten, bei Food-Check/Ratgeber und den Reitern (wie SelectionPill). */
@Composable
fun Modifier.selectionPill(on: Boolean): Modifier {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(50)
    return clip(shape).then(if (on) Modifier.background(p.soft).border(1.dp, p.accent.copy(alpha = .35f), shape) else Modifier)
}

@Composable
fun <T> ReiterLeiste(items: List<Pair<T, String>>, selected: T, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    val p = LocalPalette.current
    val many = items.size > 4
    BoxWithConstraints(modifier.fillMaxWidth()) {
    // Fünf Reiter (Gassi) passen auch auf schmalen Telefonen: weniger Rand und, wenn nötig, für alle dieselbe kleinere
    // Schrift – nie umbrechen, nicht jeder Reiter anders groß.
    val pad = if (many) 3.dp else 6.dp
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val density = androidx.compose.ui.platform.LocalDensity.current
    val size = if (!many) 15f else {
        val room = with(density) { ((maxWidth - 6.dp - 2.dp * (items.size - 1)) / items.size - pad * 2).toPx() }
        val widest = items.maxOf { measurer.measure(it.second, TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), maxLines = 1, softWrap = false).size.width }
        (15f * minOf(1f, room / widest.coerceAtLeast(1))).let { kotlin.math.floor(it * 2) / 2 }.coerceAtLeast(10f)
    }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(p.surface).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        items.forEach { (value, title) ->
            val on = value == selected
            Box(Modifier.weight(1f).heightIn(min = 38.dp).selectionPill(on)
                .clickable(role = Role.Tab) { onSelect(value) }.semantics { this.selected = on }, contentAlignment = Alignment.Center) {
                FitText(title, TextStyle(fontSize = size.sp, fontWeight = FontWeight.SemiBold, color = if (on) p.accent else p.ink),
                    Modifier.padding(horizontal = pad), if (many) 10.sp else 12.sp)
            }
        }
    }
    }
}

/** Wo man gerade ist und wie man zurückkommt: „‹ Wohin heute? › Hundezone“. */
@Composable
fun Breadcrumb(parent: String, current: String, modifier: Modifier = Modifier, onBack: () -> Unit) {
    val p = LocalPalette.current
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onBack).heightIn(min = 44.dp).padding(end = 8.dp).semantics { contentDescription = L.t("Zurück zu %1\$s", parent) },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            LineIcon(Sym.LEFT, p.accent, 16.dp); Text(parent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent, maxLines = 1)
        }
        LineIcon(Sym.RIGHT, p.ink3, 12.dp)
        Text(current, fontSize = 15.sp, color = p.ink2, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
    }
}

@Composable
fun Title(text: String, size: TextUnit = 22.sp) {
    val p = LocalPalette.current
    Text(text, fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = size, color = p.ink)
}

/** Ein Icon zum Tippen, ohne Fläche dahinter: Plus, Stift und was sonst leise bleiben soll. */
@Composable
fun RoundButton(sym: String, label: String, size: Dp = 44.dp, tint: Color? = null, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.size(size).clip(CircleShape).clickable(role = Role.Button, onClick = onClick)
        .semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        LineIcon(sym, tint ?: p.accent, (size.value * 0.52f).coerceAtLeast(22f).dp)
    }
}

/** Ein Ring wie eine Locke des Logos: fast geschlossen, am offenen Ende ein Punkt (wie CurlRing.swift). */
@Composable
fun CurlRing(color: Color, modifier: Modifier = Modifier, lineWidth: Dp = 1.6.dp) {
    Canvas(modifier) {
        val w = lineWidth.toPx()
        val r = minOf(size.width, size.height) / 2 - w
        val start = -60f
        drawArc(color, start, 310f, false, topLeft = Offset(center.x - r, center.y - r), size = androidx.compose.ui.geometry.Size(2 * r, 2 * r), style = Stroke(w, cap = StrokeCap.Round))
        val a = Math.toRadians(start.toDouble())
        drawCircle(color, w * 1.6f, Offset(center.x + r * cos(a).toFloat(), center.y + r * sin(a).toFloat()))
    }
}

/** Ein rundes Bild – oder der Anfangsbuchstabe (Person) bzw. eine Pfote (Hund). */
@Composable
fun AvatarView(jpegBase64: String?, name: String = "", size: Dp = 42.dp, isDog: Boolean = false) {
    val p = LocalPalette.current
    val bitmap: ImageBitmap? = remember(jpegBase64) {
        jpegBase64?.let { runCatching { val b = Base64.getDecoder().decode(it); BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() }.getOrNull() }
    }
    Box(Modifier.size(size).clip(CircleShape).background(p.soft), contentAlignment = Alignment.Center) {
        if (bitmap != null) Image(bitmap, null, Modifier.size(size), contentScale = ContentScale.Crop)
        else if (isDog || name.isEmpty()) LineIcon(Sym.PAW, p.accent, (size.value * 0.56f).dp)
        else Text(name.take(1).uppercase(), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.45).sp, color = p.accent)
    }
}

/** „in 4 Mon.“, „in 12 Tagen“, „überfällig“. */
fun dueShort(due: Day, today: Day = Day.today()): String {
    val n = today.daysUntil(due)
    return when {
        n < 0 -> L.t("überfällig"); n == 0 -> "heute"; n == 1 -> "morgen"
        n < 45 -> L.t("in %1\$s Tagen", n); n < 365 -> L.t("in %1\$s Mon.", n / 30)
        else -> if (n / 365 == 1) L.t("in 1 Jahr") else L.t("in %1\$d Jahren", n / 365)
    }
}

@Composable
fun DueChip(due: Day) {
    val p = LocalPalette.current
    val today = Day.today()
    val overdue = due < today
    val soon = !overdue && today.daysUntil(due) <= 30
    Text(dueShort(due), fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        color = if (overdue) p.health else if (soon) p.accent else p.ink2,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(if (overdue) p.health.copy(alpha = .12f) else if (soon) p.soft else p.line.copy(alpha = .6f))
            .padding(horizontal = 10.dp, vertical = 4.dp))
}

/** Die Bereiche der App, in der Reihenfolge der Leiste. */
enum class AppTab(val title: String, val sym: String) {
    HEUTE(L.t("Heute"), Sym.HOME), KALENDER(L.t("Kalender"), Sym.CALENDAR), GASSI(L.t("Gassi"), Sym.ROUTE), HUND(L.t("Hund"), Sym.PAW), WISSEN(L.t("Wissen"), Sym.BOOK)
}

/** Die schwebende Leiste: Icons im Strich des Logos, nur der aktive Bereich zeigt seinen Namen (wie TabDock.swift). Quer steht sie senkrecht. */
@Composable
fun TabDock(tab: AppTab, onSelect: (AppTab) -> Unit, modifier: Modifier = Modifier, vertical: Boolean = false) {
    val p = LocalPalette.current
    val outer = modifier.shadow(18.dp, RoundedCornerShape(50), ambientColor = Color.Black.copy(.25f), spotColor = Color.Black.copy(.25f))
        .clip(RoundedCornerShape(50)).background(p.surface.copy(alpha = .94f)).border(1.dp, p.line, RoundedCornerShape(50)).padding(5.dp)
    val button: @Composable (AppTab) -> Unit = { t ->
        val on = t == tab
        Row(Modifier.height(46.dp).selectionPill(on)
            .clickable(remember { MutableInteractionSource() }, null, role = Role.Tab) { onSelect(t) }
            .semantics { contentDescription = t.title; selected = on }
            .then(if (vertical) Modifier.width(46.dp) else Modifier.padding(horizontal = if (on) 16.dp else 14.dp).animateContentSize(spring(0.8f, 500f))),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = if (vertical) Arrangement.Center else Arrangement.spacedBy(7.dp)) {
            LineIcon(t.sym, if (on) p.accent else p.ink, 24.dp)
            if (!vertical) AnimatedVisibility(on, enter = fadeIn() + scaleIn(initialScale = .7f), exit = fadeOut() + scaleOut(targetScale = .7f)) {
                Text(t.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent, maxLines = 1)
            }
        }
    }
    if (vertical) Column(outer, verticalArrangement = Arrangement.spacedBy(4.dp)) { AppTab.entries.forEach { button(it) } }
    else Row(outer, horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) { AppTab.entries.forEach { button(it) } }
}

/** Die Leine als glatte Linie durch Punkte (Catmull-Rom, wie LeashShape.swift). */
fun leashCurve(p: List<Offset>): androidx.compose.ui.graphics.Path {
    val path = androidx.compose.ui.graphics.Path()
    if (p.isEmpty()) return path
    path.moveTo(p[0].x, p[0].y)
    for (i in 0 until p.size - 1) {
        val p0 = p.getOrElse(i - 1) { p[i] }; val p1 = p[i]; val p2 = p[i + 1]; val p3 = p.getOrElse(i + 2) { p2 }
        path.cubicTo(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6, p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6, p2.x, p2.y)
    }
    return path
}

/** Eine Schlinge um `c`: Die Leine läuft nach unten hinein, kreuzt sich und läuft weiter. */
fun leashLoop(c: Offset, r: Float, side: Float): List<Offset> {
    val drift = r * 0.42f
    return (0..16).map { m ->
        val w = (-Math.PI + m / 16.0 * 2 * Math.PI).toFloat()
        val along = drift * w - r * kotlin.math.sin(w); val off = r * (1 + kotlin.math.cos(w)) * side
        Offset(c.x - off, c.y + along)
    }
}

/**
 * Eine eigene Ansicht statt eines Blatts. Breit und quer zwei Spalten: links Inhalt, rechts Bearbeiten (wie TwoPane.swift);
 * schmal untereinander, mit `rightFirst` zuerst die rechte Spalte, wenn dort das Wichtigste steht.
 */
@Composable
fun OwnView(parent: String, title: String, onClose: () -> Unit, rightFirst: Boolean = false, left: @Composable ColumnScope.() -> Unit, right: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    val config = androidx.compose.ui.platform.LocalConfiguration.current
    val wide = config.screenWidthDp >= 600
    androidx.compose.ui.window.Dialog(onClose, androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        DialogBars()
        Column(Modifier.fillMaxSize().background(p.paper).windowInsetsPadding(WindowInsets.safeDrawing)) {
            Breadcrumb(parent, title, Modifier.padding(horizontal = 16.dp), onClose)
            val gap = Arrangement.spacedBy(24.dp)
            if (wide) Row(Modifier.fillMaxSize()) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 24.dp), verticalArrangement = gap, content = left)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 24.dp), verticalArrangement = gap, content = right)
            } else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
                if (rightFirst) { Text(title, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 38.sp, color = p.ink); right(); left() } else { left(); right() }
            }
        }
    }
}

/** „Erledigt“ neben einer Fälligkeit (Impfung, Entwurmung). */
@Composable
fun DoneChip(onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.clip(RoundedCornerShape(50)).background(p.soft).clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 6.dp)) {
        Text(L.t("Erledigt"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
    }
}
