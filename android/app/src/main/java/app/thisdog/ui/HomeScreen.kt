package app.thisdog.ui

import app.thisdog.i18n.L
import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.gassi.*
import app.thisdog.gassi.WalkRecorder.Phase
import app.thisdog.model.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.cos
import kotlin.math.sin

/** Zum Ansehen (Entwicklerfassung): `--ez stupsen true` stupst jede Sekunde. */
object HomeDemo { var stupsen = false }

/** Was die Startseite entscheidet, getrennt von der Darstellung (wie HomeScreen.swift). */
object Home {
    fun salute(hour: Int = java.time.LocalTime.now().hour) = when (hour) { in 5..10 -> L.t("Guten Morgen"); in 11..17 -> L.t("Hallo"); else -> L.t("Guten Abend") }
    fun headline(walking: Boolean, walkedToday: Boolean) =
        if (walking) L.t("Ihr seid unterwegs.") else if (walkedToday) L.t("Schön, ihr wart heute schon draußen.") else L.t("Zeit für eine Runde?")
    /** Die nächsten Orte, an denen ihr noch nicht eingecheckt habt. */
    fun unvisited(places: List<Place>, checkIns: List<CheckIn>, limit: Int = 3): List<Place> {
        val seen = checkIns.map { it.place }.toSet()
        return places.filter { CheckIn.key(it) !in seen }.take(limit)
    }

    /** Der Spruch zur Lage. Bleibt über den Tag gleich und wechselt erst beim Stupsen (`seed`). */
    fun dogLine(walking: Boolean, walkedToday: Boolean, lastWalk: Day?, today: Day, hour: Int, seed: Int): String {
        val lines = when {
            walking -> listOf(L.t("Hier riecht's super!"), L.t("Nicht so schnell, ich les noch!"), L.t("Da! Ein Stock!"))
            walkedToday -> listOf(L.t("Schön war's. Jetzt Sofa?"), L.t("Ich bin wunschlos. Fast. Leckerli?"), L.t("Morgen wieder? Morgen wieder!"))
            lastWalk == null -> listOf(L.t("Unsere erste Runde! Ich bin so bereit."), L.t("Raus? Raus! Raus?!"), L.t("Ich hol schon mal die Leine."))
            lastWalk.daysUntil(today) >= 3 -> listOf(L.t("Hallo? Die Leine vermisst mich."), L.t("Die Wiese hat nach uns gefragt."), L.t("Ich hab schon alles hier beschnüffelt."))
            hour < 11 -> listOf(L.t("Aufstehen! Die Wiese wartet."), L.t("Raus? Raus! Raus?!"), L.t("Ich hol schon mal die Leine."))
            hour < 18 -> listOf(L.t("Ich hab da was gerochen. Komm mit!"), L.t("Raus? Raus! Raus?!"), L.t("Ich warte nur ganz zufällig an der Tür."))
            else -> listOf(L.t("Noch eine Schnüffelrunde?"), L.t("Einmal noch um den Block?"), L.t("Im Dunkeln riecht alles besser."))
        }
        return lines[((seed % lines.size) + lines.size) % lines.size]
    }

}

/**
 * Die Startseite: Zuerst die Frage, ob ihr heute schon draußen wart, dann was ansteht und in seinen Bereich führt,
 * darunter die Woche und Orte, an denen ihr noch nicht wart. Quer steht die Frage fest links.
 */
@Composable
fun HomeScreen(wide: Boolean, onTab: (AppTab) -> Unit, onPlace: (Place) -> Unit, onPack: () -> Unit, onSettings: () -> Unit, onEmergency: () -> Unit = {}) {
    val p = LocalPalette.current; val store = Graph.store; val context = LocalContext.current
    val rec = WalkRecorder
    val quer = isQuer()
    var places by remember { mutableStateOf<List<Place>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    // Wie oft ThisDog, das Maskottchen, auf die Nase gestupst wurde: Jedes Mal kommt ein neuer Spruch.
    var boops by remember { mutableStateOf(0) }
    // Wo das Maskottchen sitzt: Die Pfötchen fliegen über den Rand der Spalte, also liegen sie über allem.
    var markCenter by remember { mutableStateOf(Offset.Zero) }
    var screenOrigin by remember { mutableStateOf(Offset.Zero) }
    val locate = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { rec.locateOnce(context) }
    val spot = rec.here ?: store.walks.maxByOrNull { it.start }?.coordinates?.firstOrNull()
    LaunchedEffect(Unit) { if (rec.hasPermission(context)) rec.locateOnce(context) }
    // Wie in Gassi: neu suchen, wenn man sich weit genug von der letzten Suche entfernt hat.
    var placesCenter by remember { mutableStateOf<app.thisdog.model.LatLng?>(null) }
    val center = placesCenter.takeIf { c -> spot == null || c != null && app.thisdog.model.Track.distance(c, spot) < PlaceFinder.REFRESH_METERS } ?: spot
    LaunchedEffect(center) {
        placesCenter = center
        if (center != null) { loading = true; places = PlaceFinder.near(Graph.account.api, center).orEmpty(); loading = false }
    }
    LaunchedEffect(Unit) { if (HomeDemo.stupsen) while (true) { delay(1000); boops++ } }
    val dog = store.profile.name
    val today = Day.today()
    val todayWalks = store.walks.filter { it.day == today }
    val walking = rec.phase != Phase.IDLE
    val last = store.walks.maxByOrNull { it.start }

    val greeting: @Composable () -> Unit = {
        // Entlaufen: steht über allem, bei allen im Rudel.
        if (store.profile.isLost) LostDogBanner(onEmergency)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            AvatarView(store.avatars.firstOrNull { it.id == Avatar.DOG }?.jpeg, dog, 52.dp, isDog = true)
            Text(if (store.profile.ownerName.isEmpty()) Home.salute() else "${Home.salute()}, ${store.profile.ownerName}", fontFamily = Display, fontSize = 19.sp, lineHeight = 24.sp, color = p.ink2, maxLines = 2, modifier = Modifier.weight(1f))
            Row {
                RoundButton(Sym.GROUP, L.t("Rudel"), 44.dp, p.ink2, onPack)
                RoundButton(Sym.SETTINGS, L.t("Einstellungen"), 44.dp, p.ink2, onSettings)
            }
        }
    }
    val walkCard: @Composable (Modifier) -> Unit = { m ->
        Column(m.clip(RoundedCornerShape(32.dp)).background(p.soft).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(Home.headline(walking, todayWalks.isNotEmpty()), fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 27.sp, lineHeight = 32.sp, color = p.ink)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                SpeechBubble(Home.dogLine(walking, todayWalks.isNotEmpty(), last?.day, today, java.time.LocalTime.now().hour, today.date.dayOfYear + boops), Modifier.weight(1f))
                BoopableMark(boops, 108.dp, { boops++ }) { markCenter = it }
            }
            Text(when {
                walking -> L.t("%1\$s bis jetzt. Viel Spaß!", WalkText.distance(rec.meters))
                todayWalks.isNotEmpty() -> L.t("Heute %1\$s in %2\$s", WalkText.distance(todayWalks.sumOf { it.meters }), WalkText.duration(todayWalks.sumOf { it.seconds }))
                last == null -> L.t("Tipp auf Start, wenn ihr losgeht. Das Telefon kann in die Tasche.")
                else -> if (dog.isEmpty()) L.t("Eure letzte Runde: %1\$s, %2\$s.", lastWalkText(last.day, today), WalkText.distance(last.meters)) else L.t("%1\$ss letzte Runde: %2\$s, %3\$s.", dog, lastWalkText(last.day, today), WalkText.distance(last.meters))
            }, fontSize = if (quer) 15.sp else 16.sp, lineHeight = if (quer) 20.sp else 22.sp, color = p.ink2)
            // Quer füllt die Karte die Spalte: Der Knopf steht dann unten, beim Daumen.
            if (quer) Spacer(Modifier.weight(1f, fill = true))
            PrimaryButton(if (walking) L.t("Zur Runde") else if (todayWalks.isEmpty()) L.t("Runde starten") else L.t("Noch eine Runde"), Modifier.padding(top = 4.dp)) {
                if (!walking && rec.hasPermission(context)) rec.start(context)
                onTab(AppTab.GASSI)
            }
        }
    }
    val weekBlock: @Composable () -> Unit = {
        // Keine Serien und keine Strecken zum Angeben, dafür ein Spruch für den Tag (wie auf iOS).
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            WeekLeash(store.walks)
            Text(Saying.of(Day.today()), fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium, color = p.ink2)
        }
    }
    val discover: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(L.t("Hier wart ihr noch nicht"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, color = p.ink, modifier = Modifier.padding(bottom = 6.dp))
            val list = Home.unvisited(places, store.checkIns)
            when {
                list.isNotEmpty() -> list.forEach { pl ->
                    val far = spot?.let { WalkText.distance(Track.distance(it, pl.coordinate)) }
                    HomeRow(if (pl.isDogZone) Sym.PAW else Sym.PARK, pl.name, listOfNotNull(pl.label.takeIf { it != pl.name }, far?.let { L.t("%1\$s entfernt", it) }).joinToString(", ")) { onPlace(pl) }
                }
                loading -> CircularProgressIndicator(Modifier.padding(16.dp), color = p.accent)
                spot == null -> {
                    Text(L.t("Erlaube den Standort, dann zeigt dir ThisDog Parks und Hundezonen in der Nähe."), fontSize = 15.sp, color = p.ink2)
                    Row(Modifier.padding(top = 6.dp).clip(RoundedCornerShape(50)).clickable {
                        locate.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                    }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        LineIcon(Sym.MY_LOCATION, p.accent, 20.dp); Text(L.t("Standort freigeben"), color = p.accent, fontWeight = FontWeight.SemiBold)
                    }
                }
                else -> Text(L.t("Ihr kennt schon alle Orte in der Nähe. Kennst du noch einen? Trag ihn in Gassi ein."), fontSize = 15.sp, color = p.ink2)
            }
        }
    }
    val entries = CalendarBuilder.all(store.events, Graph.content.seasonal) + CalendarBuilder.dogEntries(store.profile, store.dues)
    val upcoming: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(L.t("Was sonst ansteht"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, color = p.ink, modifier = Modifier.padding(bottom = 6.dp))
            // Die nächsten zwei Termine aus dem Rudelkalender.
            NextUp.upcoming(entries, 2).forEach { e ->
                HomeRow(Sym.CALENDAR, e.plainTitle, NextUp.remaining(e)) { onTab(AppTab.KALENDER) }
            }
            store.dues.firstOrNull()?.let { d ->
                val n = today.daysUntil(d.due)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.weight(1f)) {
                        HomeRow(Sym.EMERGENCY, d.title, if (n < 0) L.t("%1\$s, seit %2\$s Tagen fällig", d.kind, -n) else if (n == 0) L.t("%1\$s, heute fällig", d.kind) else if (n == 1) L.t("%1\$s, in 1 Tag fällig", d.kind) else L.t("%1\$s, in %2\$s Tagen fällig", d.kind, n)) { onTab(AppTab.HUND) }
                    }
                    if (store.canMarkDone(d)) DoneChip { store.markDone(d.id) }
                }
            }
            HomeRow(Sym.SEARCH, L.t("Darf mein Hund das fressen?"), L.t("Im Food-Check nachsehen")) { onTab(AppTab.WISSEN) }
        }
    }
    val bottom = dockClearance()
    Box(Modifier.fillMaxSize().background(p.paper).onGloballyPositioned { screenOrigin = it.boundsInRoot().topLeft }) {
        when {
            quer -> Row(Modifier.fillMaxSize().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                // Die Frage nach der Runde steht fest links, der Knopf bleibt immer in Reichweite. Rechts läuft der Rest.
                BoxWithConstraints(Modifier.width(350.dp).fillMaxHeight()) {
                    val height = maxHeight - 20.dp
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 10.dp)) { walkCard(Modifier.fillMaxWidth().heightIn(min = height)) }
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 10.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
                    greeting(); OutsideBlock { onTab(AppTab.GASSI) }; upcoming(); weekBlock(); discover()
                }
            }
            wide -> Row(Modifier.fillMaxSize().statusBarsPadding()) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 32.dp).padding(top = 24.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(40.dp)) { greeting(); walkCard(Modifier.fillMaxWidth()); OutsideBlock { onTab(AppTab.GASSI) }; weekBlock() }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 32.dp).padding(top = 24.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(40.dp)) { upcoming(); discover() }
            }
            else -> Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(36.dp)) {
                greeting(); walkCard(Modifier.fillMaxWidth()); OutsideBlock { onTab(AppTab.GASSI) }; upcoming(); weekBlock(); discover()
            }
        }
        PawBurst(boops, markCenter - screenOrigin)
    }
}

/** Was ThisDog gerade zu sagen hat: eine weiße Blase, das Schwänzchen zeigt zum Maskottchen. */
@Composable
private fun SpeechBubble(line: String, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Box(modifier.padding(end = 10.dp)) {
        AnimatedContent(line, label = "spruch", transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(120)) }) { text ->
            Text(text, fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 19.sp, lineHeight = 24.sp, color = p.ink,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(p.surface).padding(horizontal = 16.dp, vertical = 12.dp))
        }
        Canvas(Modifier.align(Alignment.CenterEnd).offset(x = 10.dp).size(12.dp, 18.dp)) {
            drawPath(Path().apply { moveTo(0f, 0f); lineTo(size.width, size.height / 2); lineTo(0f, size.height); close() }, p.surface)
        }
    }
}

/** Stupsen erlaubt: Das Maskottchen wackelt, Pfötchen fliegen, und es kommt ein neuer Spruch. */
@Composable
private fun BoopableMark(boops: Int, side: Dp, onBoop: () -> Unit, onCenter: (Offset) -> Unit) {
    Box(Modifier.size(side).clickable(remember { MutableInteractionSource() }, null, role = Role.Button, onClick = onBoop)
        .semantics { contentDescription = L.t("ThisDog auf die Nase stupsen") }
        .onGloballyPositioned { onCenter(it.boundsInRoot().center) }) {
        StellaMark(boops, Modifier.fillMaxSize())
    }
}

/** Pfötchen, die beim Stupsen auffliegen und verblassen. */
@Composable
private fun PawBurst(trigger: Int, center: Offset) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val t = remember { Animatable(0f) }
    LaunchedEffect(trigger) {
        if (trigger == 0) return@LaunchedEffect
        launch { t.snapTo(0f); t.animateTo(1f, tween(900)); t.snapTo(0f) }
    }
    val v = t.value
    if (v <= 0f || v >= 1f) return
    (0 until 6).forEach { i ->
        val angle = i / 5.0 * Math.PI
        val size = 16 + (i % 3) * 4
        LineIcon(Sym.PAW, p.accent, size.dp, Modifier.graphicsLayer {
            val half = with(density) { size.dp.toPx() / 2 }
            translationX = center.x - half + (cos(angle) * 78 * v).toFloat() * density.density
            translationY = center.y - half + (-sin(angle) * 92 * v - 16 * v).toFloat() * density.density
            rotationZ = (cos(angle) * 30).toFloat()
            scaleX = .6f + v * .6f; scaleY = scaleX
            alpha = 1 - v * v
        })
    }
}

private fun lastWalkText(day: Day, today: Day) = when (val n = day.daysUntil(today)) { 0 -> L.t("heute"); 1 -> L.t("gestern"); in 2..6 -> L.t("vor %1\$d Tagen", n); else -> L.t("am %1\$s", day.shortText) }

@Composable
private fun HomeRow(sym: String, title: String, line: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = onClick).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        LineIcon(sym, p.accent, 26.dp)
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 2)
            if (line.isNotEmpty()) Text(line, fontSize = 15.sp, color = p.ink2)
        }
        LineIcon(Sym.RIGHT, p.ink3, 16.dp)
    }
}

/** „Draußen“: wie es jetzt ist, was die nächste Stunde bringt und wie warm der Belag ist (wie OutsideBlock). Nur mit echtem Wetter. */
@Composable
fun OutsideBlock(onOpen: () -> Unit) {
    val p = LocalPalette.current
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(300_000); now = System.currentTimeMillis() } }
    val air = app.thisdog.gassi.Heat.current ?: return
    val surface = app.thisdog.gassi.Heat.surface(now) ?: return
    val r = app.thisdog.gassi.Heat.reading
    val paws = app.thisdog.model.Calc.paws(surface)
    val color = when (paws) { app.thisdog.model.Calc.Paws.OK -> p.seasonal; app.thisdog.model.Calc.Paws.WARN -> p.warning; app.thisdog.model.Calc.Paws.BAD -> p.health }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(L.t("Draußen"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, color = p.ink)
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(p.surface).clickable(onClick = onOpen).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                LineIcon(Sym.SUN, p.accent, 30.dp)
                Column(Modifier.weight(1f)) {
                    val sky = r?.symbol?.let { app.thisdog.gassi.Heat.skyText(it) }.orEmpty()
                    Text(if (sky.isEmpty()) "${Math.round(air)} °C" else "${Math.round(air)} °C, $sky", fontWeight = FontWeight.SemiBold, color = p.ink)
                    if (r != null) Text(app.thisdog.gassi.Heat.nextHourLine(r), fontSize = 15.sp, color = p.ink2)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.size(10.dp).clip(androidx.compose.foundation.shape.CircleShape).background(color))
                Text(L.t("Asphalt etwa %1\$s °C", Math.round(surface)), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
                Text(paws.label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = color)
            }
            if (paws != app.thisdog.model.Calc.Paws.OK) Text(app.thisdog.model.Calc.advice(paws), fontSize = 13.sp, color = p.ink2)
        }
        WeatherCredit()
    }
}
