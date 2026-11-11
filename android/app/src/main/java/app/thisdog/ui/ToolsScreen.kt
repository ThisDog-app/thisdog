package app.thisdog.ui

import app.thisdog.i18n.L
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.model.Calc
import kotlin.math.roundToInt

private fun n0(v: Double) = String.format(L.locale, "%,d", v.roundToInt())
private fun n1(v: Double) = if (v % 1.0 == 0.0) "${v.toInt()}" else String.format(L.locale, "%.2f", v).trimEnd('0').trimEnd(',', '.')
private fun fmt(v: Double) = if (v % 1.0 == 0.0) "${v.toInt()}" else String.format(L.locale, "%.1f", v)

/** Was der Hund am Tag braucht: Futter, Leckerli, Wasser. Rechnet mit dem Profil (wie FeedingSection in ToolsScreen.swift). */
@Composable
fun FeedingSection() {
    val p = LocalPalette.current
    val s = Graph.store
    val pr = s.profile
    if (pr.weightKg == null) {
        Text(L.t("Futter und Wasser rechnet ThisDog aus dem Gewicht. Trag es zuerst ein."), fontSize = 15.sp, color = p.ink2)
        return
    }
    val set = s.settings
    val useTarget = set.feedBasis == "target" && pr.targetWeightKg != null && pr.targetWeightKg != pr.weightKg
    val e = Calc.energy(pr, useTarget)
    val grams = e?.let { Calc.grams(it.kcal, set.kcalPer100g) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(36.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Title(L.t("Futtermenge"))
            Column {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(grams?.let(::n0) ?: "–", fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 96.sp, lineHeight = 96.sp, color = p.accent)
                    Text(L.t("g am Tag"), fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 22.sp, color = p.ink, modifier = Modifier.padding(bottom = 14.dp))
                }
                if (grams != null && set.meals > 1) Text("${set.meals} × ${n0(grams / set.meals)} g", fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 28.sp, color = p.ink)
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Label(L.t("Futter"))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Calc.FOOD_KINDS.forEach { (name, kcal) -> Chip(name, set.kcalPer100g == kcal) { s.save(set.copy(kcalPer100g = kcal)) } } }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(L.t("Energie je 100 g"), color = p.ink, modifier = Modifier.weight(1f)); Text(L.t("%1\$s kcal", n0(set.kcalPer100g)), color = p.ink)
                    Spacer(Modifier.width(10.dp))
                    Step("−", L.t("Weniger")) { s.save(set.copy(kcalPer100g = (set.kcalPer100g - 5).coerceAtLeast(30.0))) }
                    Spacer(Modifier.width(6.dp))
                    Step("+", L.t("Mehr")) { s.save(set.copy(kcalPer100g = (set.kcalPer100g + 5).coerceAtMost(600.0))) }
                }
                Text(L.t("Steht auf der Verpackung, oft als „umsetzbare Energie“."), fontSize = 12.sp, color = p.ink3)
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Label(L.t("Mahlzeiten am Tag"))
                ReiterLeiste((1..4).map { it to "$it" }, set.meals) { m -> s.save(set.copy(meals = m)) }
            }
            if (pr.targetWeightKg != null && pr.targetWeightKg != pr.weightKg) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Label(L.t("Rechnen mit"))
                ReiterLeiste(listOf("current" to L.t("Gewicht %1\$s kg", fmt(pr.weightKg)), "target" to L.t("Wunsch %1\$s kg", fmt(pr.targetWeightKg))), if (useTarget) "target" else "current") { b -> s.save(set.copy(feedBasis = b)) }
                if (useTarget) Text(L.t("Abnehmen gehört tierärztlich begleitet: Zu schnell schadet."), fontSize = 12.sp, color = p.ink3)
            }
            e?.let { Text(L.t("Grundumsatz %1\$s kcal × Faktor %2\$s (%3\$s) = %4\$s kcal, gerechnet auf %5\$s kg.", n0(it.rer), n1(it.factor.value), it.factor.note, n0(it.kcal), fmt(it.kg)), fontSize = 13.sp, color = p.ink2) }
        }
        e?.let { en ->
            val (kcal, g) = Calc.treats(en.kcal)
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Title(L.t("Leckerli"))
                Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) { Big(n0(kcal), L.t("kcal am Tag")); Big(n0(g), L.t("g Trockenleckerli")) }
                // Der Tag als Streifen: neun Teile Hauptfutter, ein Teil Leckerli.
                Row(Modifier.fillMaxWidth().height(10.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Box(Modifier.weight(9f).fillMaxHeight().clip(RoundedCornerShape(50)).background(p.line))
                    Box(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(50)).background(p.accent))
                }
                Text(L.t("Höchstens ein Zehntel der Tagesenergie, sonst kippt die Nährstoffbilanz des Hauptfutters."), fontSize = 13.sp, color = p.ink2)
            }
        }
        val w = Calc.water(pr.weightKg)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Title(L.t("Wasser")); Big(L.t("%1\$s bis %2\$s", n0(w.start), n0(w.endInclusive)), L.t("ml am Tag"))
            Text(L.t("Bei Hitze, Sport oder Trockenfutter mehr. Deutlich mehr Trinken über Tage gehört in der Praxis abgeklärt."), fontSize = 13.sp, color = p.ink2)
        }
        Text(L.t("Richtwerte für gesunde Hunde. Bei Krankheit, Trächtigkeit oder Diät gilt die Empfehlung der Tierarztpraxis."), fontSize = 12.sp, color = p.ink3)
    }
}

/**
 * Wie heiß der Belag gerade ist: die Frage vor dem Rausgehen (wie AsphaltSection). Nur mit echtem Wetter – eine
 * geschätzte Zahl ohne Sonne und Wolken stimmt im Herbst nicht, deshalb gibt es ohne Wetter keine.
 */
@Composable
fun AsphaltSection() {
    val p = LocalPalette.current
    // Die Sonne wandert: alle paar Minuten neu rechnen.
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(300_000); now = System.currentTimeMillis() } }
    val air = app.thisdog.gassi.Heat.current ?: return
    val c = app.thisdog.gassi.Heat.conditions ?: return
    val surface = app.thisdog.gassi.Heat.surface(now) ?: return
    val paws = Calc.paws(surface)
    val color = when (paws) { Calc.Paws.OK -> p.seasonal; Calc.Paws.WARN -> p.warning; Calc.Paws.BAD -> p.health }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Title(L.t("Asphalt"), 20.sp)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("${n0(surface)} °C", fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 36.sp, lineHeight = 38.sp, color = color)
            Column { Text(paws.label, fontWeight = FontWeight.SemiBold, color = color); Text(L.t("Belag jetzt bei %1\$s °C Luft, %2\$s", air.roundToInt(), app.thisdog.model.Asphalt.reason(c, now)), fontSize = 15.sp, color = p.ink2) }
        }
        AsphaltLine(surface, color)
        Text(Calc.advice(paws), fontSize = 13.sp, color = p.ink2)
        WeatherCredit()
    }
}

/** Der Hinweis vor dem Losgehen, nur wenn es für die Pfoten knapp wird. */
@Composable
fun HeatBanner(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val paws = app.thisdog.gassi.Heat.warning ?: return
    val air = app.thisdog.gassi.Heat.air ?: return
    val surface = app.thisdog.gassi.Heat.surface() ?: return
    val color = if (paws == Calc.Paws.BAD) p.health else p.warning
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(color.copy(alpha = .12f)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LineIcon(Sym.SUN, color, 20.dp)
            Text(L.t("%1\$s °C – Asphalt etwa %2\$s °C", air.roundToInt(), surface.roundToInt()), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
        }
        Text(Calc.advice(paws), fontSize = 13.sp, color = p.ink2)
        WeatherCredit()
    }
}

/** Quellenangabe, die MET Norway für seine Daten verlangt. */
@Composable
fun WeatherCredit() {
    Text(L.t("Wetterdaten: MET Norway"), fontSize = 11.sp, color = LocalPalette.current.ink3)
}

/** Die Temperatur des Belags auf einer Linie von 20 bis 80 °C, mit den Grenzen 43 und 52 °C. */
@Composable
private fun AsphaltLine(surface: Double, color: Color) {
    val p = LocalPalette.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(36.dp)) {
        val w = maxWidth
        fun x(t: Double) = w * (((minOf(80.0, maxOf(20.0, t)) - 20) / 60).toFloat())
        Canvas(Modifier.fillMaxWidth().height(20.dp)) {
            val y = size.height / 2
            drawLine(p.line, Offset(0f, y), Offset(size.width, y), 4.dp.toPx(), StrokeCap.Round)
            listOf(43.0, 52.0).forEach { t -> val xx = x(t).toPx(); drawLine(p.ink3, Offset(xx, y - 7.dp.toPx()), Offset(xx, y + 7.dp.toPx()), 1.5.dp.toPx()) }
            val c = Offset(x(surface).toPx(), y)
            drawCircle(Color.White, 8.dp.toPx(), c); drawCircle(color, 5.dp.toPx(), c)
        }
        listOf(43, 52).forEach { t -> Text("$t°", fontSize = 11.sp, color = p.ink3, modifier = Modifier.offset(x = x(t.toDouble()) - 8.dp, y = 19.dp)) }
    }
}

@Composable private fun Label(t: String) = Text(t, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = LocalPalette.current.ink2)

/** Das Plus und Minus neben einer Zahl: als Zeichen, leise. */
@Composable
private fun Step(sign: String, label: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.size(38.dp).clip(RoundedCornerShape(50)).background(p.surface).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(sign, fontSize = 22.sp, color = p.accent, modifier = Modifier.padding(bottom = 2.dp).semantics { contentDescription = label })
    }
}

@Composable private fun Big(value: String, unit: String) {
    val p = LocalPalette.current
    Column { Text(value, fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 36.sp, color = p.ink); Text(unit, fontSize = 13.sp, color = p.ink2) }
}

@Composable
fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (selected) p.accent else p.ink,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(if (selected) p.soft else p.surface)
            .border(1.dp, if (selected) p.accent.copy(alpha = .4f) else p.line, RoundedCornerShape(50)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp))
}
