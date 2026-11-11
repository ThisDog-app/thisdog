package app.thisdog.ui

import app.thisdog.i18n.L
import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import kotlin.math.abs
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.gassi.*
import app.thisdog.gassi.WalkRecorder.Phase
import app.thisdog.model.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/** Die Reiter im Panel über der Karte. */
enum class GassiReiter(val title: String) { WOHIN(L.t("Wohin")), ADRESSEN(L.t("Adressen")), RUNDEN(L.t("Runden")), FREUNDE(L.t("Freunde")), REVIER(L.t("Revier")) }

/** Wie weit das Blatt über der Karte aufgezogen ist. */
enum class StageDetent { PEEK, MIDDLE, FULL }

/**
 * Was Gassi zeigt, über Seitenwechsel und Drehen hinweg: Eine eben beendete Runde darf dabei nicht verloren gehen.
 */
class GassiUi {
    var places by mutableStateOf<List<Place>>(emptyList())
    var selected by mutableStateOf<Place?>(null)
    var adding by mutableStateOf(false)
    var checks by mutableStateOf(false)
    var scout by mutableStateOf(false)
    var notice by mutableStateOf<Pair<String, String>?>(null)
    var reiter by mutableStateOf(GassiReiter.WOHIN)
    var detent by mutableStateOf(StageDetent.MIDDLE)
    /** Die eben beendete Runde, bis sie behalten oder verworfen ist. Sie liegt auf der Karte. */
    var finished by mutableStateOf<Walk?>(null)
    /** Die Runde, die gerade auf der Karte liegt. */
    var shownWalk by mutableStateOf<Walk?>(null)
    /** Unterwegs nicht noch einmal fragen, wenn „Später“ getippt wurde. */
    val dismissed = mutableStateListOf<String>()

    fun update(p: Place) {
        places = places.map { if (it.id == p.id) p else it }
        if (selected?.id == p.id) selected = p
    }

    /** Bringt eine Runde auf die Karte (null: wieder weg) und lässt die Karte dabei sichtbar. */
    fun show(walk: Walk?) {
        shownWalk = walk
        if (walk == null) return
        selected = null; reiter = GassiReiter.RUNDEN; detent = StageDetent.MIDDLE
    }
}

val gassiUi = GassiUi()

/** Für Bildschirmfotos (Entwicklerfassung): Bewertungen, Revier, Ortsseite, Reiter, Blatt, eine Runde auf der Karte. */
object GassiDemo {
    var bewertet = false
    var rudel = false; var orte = false; var ortseite = false; var revier = false; var revierAnsicht = false; var erkunder = false
    var reiter: String? = null; var stufe: String? = null; var fertig = false; var rundekarte = false
    /** Adressen aus [app.thisdog.Beispiel] statt vom Server, mit gesponsertem Eintrag. */
    var adressen = false
}

/**
 * Gassi (wie GassiScreen.swift): Die Karte ist die Hauptsache und füllt den Bildschirm; alles andere liegt darüber.
 * Vor der Runde Reiter für Wohin, Adressen, Runden, Freunde und Revier; jeder nutzt dieselbe Karte.
 * Eine angetippte Runde oder ein Ort erscheint in derselben Karte, nicht in einem eigenen Fenster.
 */
@Composable
fun GassiScreen(onPack: () -> Unit = {}, demoFriends: Boolean = false) {
    val ui = gassiUi
    val p = LocalPalette.current
    val context = LocalContext.current
    val rec = WalkRecorder
    var places by ui::places
    var loading by remember { mutableStateOf(false) }
    var unavailable by remember { mutableStateOf(false) }
    var startAfterGrant by remember { mutableStateOf(false) }
    val store = Graph.store

    // Nach dem Standort wird erst gefragt, wenn jemand ihn freigibt oder losgeht – nicht beim Öffnen.
    val notify = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { rec.start(context) }
    fun begin() {
        if (Build.VERSION.SDK_INT >= 33 && androidx.core.content.ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED)
            notify.launch(Manifest.permission.POST_NOTIFICATIONS)
        else rec.start(context)
    }
    val locate = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.any { it }) { rec.locateOnce(context); if (startAfterGrant) begin() }
        startAfterGrant = false
    }
    fun askLocation(thenStart: Boolean) { startAfterGrant = thenStart; locate.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) }
    val start = { if (rec.hasPermission(context)) begin() else askLocation(true) }

    LaunchedEffect(Unit) { if (rec.hasPermission(context)) rec.locateOnce(context) }
    // Freunde laden und, solange es welche gibt, alle 20 Sekunden schauen, wer unterwegs ist.
    val friends = Graph.account.friends
    LaunchedEffect(Unit) {
        if (demoFriends) return@LaunchedEffect
        friends.load()
        while (true) { friends.refreshLive(); friends.refreshVisits(); delay(app.thisdog.gassi.Friends.INTERVAL_MS) }
    }
    LaunchedEffect(rec.here != null) { if (demoFriends) rec.here?.let { friends.seedDemo(it) } }
    val here = rec.here
    // Neu laden, sobald man sich weiter als PlaceFinder.REFRESH_METERS von der letzten Suche entfernt hat.
    var placesCenter by remember { mutableStateOf<LatLng?>(null) }
    val center = placesCenter.takeIf { c -> here == null || c != null && Track.distance(c, here) < PlaceFinder.REFRESH_METERS } ?: here
    LaunchedEffect(center) {
        placesCenter = center
        if (here != null) {
            loading = true
            val found = PlaceFinder.near(Graph.account.api, here)
            places = found.orEmpty().let { list -> ui.selected?.takeIf { s -> list.none { it.id == s.id } }?.let { listOf(it) + list } ?: list }
            unavailable = found == null; loading = false
            if (GassiDemo.orte) places.indexOfFirst { it.isDogZone }.takeIf { it >= 0 }?.let { i ->
                val demo = places[i].copy(votes = mapOf("off_leash" to listOf(9, 0), "fenced" to listOf(7, 1), "water" to listOf(8, 1), "clean" to listOf(5, 4),
                    "grass" to listOf(3, 4), "shade" to listOf(6, 3), "bench" to listOf(9, 0),
                    "bags" to listOf(8, 1), "split" to listOf(7, 2)), voters = 9, sizes = listOf(6, 5, 2),
                    checkedAt = System.currentTimeMillis() / 1000 - 4 * 86400)
                places = places.toMutableList().also { it[i] = demo }
                if (GassiDemo.ortseite) ui.selected = demo
            }
        }
    }

    LaunchedEffect(Unit) {
        ui.scout = ui.scout || GassiDemo.erkunder
        if (GassiDemo.revierAnsicht) ui.reiter = GassiReiter.REVIER
        GassiDemo.reiter?.let { r -> GassiReiter.entries.firstOrNull { it.name.equals(r, true) }?.let { ui.reiter = it } }
        GassiDemo.stufe?.let { s -> StageDetent.entries.firstOrNull { it.name.equals(s, true) }?.let { ui.detent = it } }
        if (GassiDemo.rundekarte) { ui.show(store.walks.maxByOrNull { it.start }); GassiDemo.rundekarte = false }
        if (GassiDemo.fertig) { ui.finished = store.walks.maxByOrNull { it.start }; GassiDemo.fertig = false }
    }
    // Prüfungen ohne Netz gehen raus; ob man Erkunder ist, sagt der Server.
    LaunchedEffect(Graph.account.signedIn) {
        if (!Graph.account.signedIn) return@LaunchedEffect
        CheckQueue.flush(context)
        runCatching { PlaceService.mine(Graph.account.api).scout }.getOrNull()?.let { ui.scout = it || GassiDemo.erkunder }
    }
    // Nur beim Wechsel zwischen „keine Runde“ und „unterwegs“, nicht bei Pause und Weiter: Eine offene Ortsseite bleibt offen.
    LaunchedEffect(rec.phase == Phase.IDLE) {
        if (rec.phase == Phase.IDLE) ui.dismissed.clear()
        else { ui.shownWalk = null; ui.selected = null }
    }
    LaunchedEffect(ui.selected?.id) {
        if (ui.selected != null) {
            ui.shownWalk = null; ui.reiter = GassiReiter.WOHIN
            if (ui.detent != StageDetent.MIDDLE) ui.detent = StageDetent.MIDDLE
            if (ui.places.none { it.id == ui.selected?.id }) ui.selected?.let { ui.places = listOf(it) + ui.places }
        }
    }
    LaunchedEffect(ui.notice) { if (ui.notice != null) { delay(3500); ui.notice = null } }

    val idle = rec.phase == Phase.IDLE
    val finished = ui.finished
    val walkOnMap = finished ?: ui.shownWalk
    val showsRevier = idle && finished == null && ui.reiter == GassiReiter.REVIER && ui.selected == null
    // Im Reiter Adressen zeigt die Karte statt der Ziele die gefilterten Adressen.
    val showsServices = idle && walkOnMap == null && ui.reiter == GassiReiter.ADRESSEN && ui.selected == null
    val service = serviceUi.selected.takeIf { showsServices }
    val lastSpot = store.walks.maxByOrNull { it.start }?.coordinates?.firstOrNull()

    BackHandler(idle && finished == null && (ui.selected != null || ui.shownWalk != null || service != null)) {
        if (ui.selected != null) ui.selected = null else if (service != null) serviceUi.selected = null else ui.shownWalk = null
    }

    Box(Modifier.fillMaxSize().background(p.paper)) {
        MapStage(ui.detent, { ui.detent = it }, fitsContent = !idle, map = { padding ->
            WalkMap(Modifier.fillMaxSize(), track = if (idle) walkOnMap?.coordinates.orEmpty() else rec.coordinates, here = rec.here,
                // Unterwegs bleiben die Orte auf der Karte: gehen, Hundeplatz, weitergehen ist eine Runde.
                places = if (!idle || walkOnMap == null && !showsRevier && !showsServices) ui.places.take(12) else emptyList(), follows = !idle, fallback = lastSpot,
                friends = friendSpots(), underStatusBar = true, onSelect = { ui.selected = it }, selected = if (showsServices) service?.id else ui.selected?.id,
                focus = if (idle) ui.selected?.coordinate ?: service?.coordinate else null, focusZoom = 15.4,
                services = if (showsServices) serviceUi.onMap(rec.here) else emptyList(), onSelectService = { serviceUi.selected = it },
                fitKey = if (showsRevier) "revier" else if (idle) walkOnMap?.id else null,
                revier = if (showsRevier) app.thisdog.gassi.Revier(store.checkIns).spots else emptyList(), padding = padding)
        }, top = { NearCard(ui) }, header = {
            when {
                finished != null -> KeepButtons(ui)
                idle -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    HeatBanner()
                    PrimaryButton(L.t("Runde starten"), onClick = start)
                    ReiterLeiste(GassiReiter.entries.map { it to it.title }, ui.reiter) { r ->
                        ui.reiter = r; ui.selected = null; ui.shownWalk = null; serviceUi.selected = null
                        if (ui.detent == StageDetent.PEEK) ui.detent = StageDetent.MIDDLE
                    }
                }
                else -> Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    LiveStats(compact = true)
                    // Abschließen heißt Behalten: Wer die Runde nicht will, bricht sie ab.
                    Controls(onDiscard = { rec.discard(context) }) { ui.selected = null; rec.finish(context)?.let { Graph.store.save(it); ui.finished = it; ui.detent = StageDetent.MIDDLE } }
                    NearbyWhileWalking(ui)
                }
            }
        }, content = {
            when {
                finished != null -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 24.dp)) { FinishedContent(finished, ui) }
                idle -> PanelContent(ui, loading, unavailable, { askLocation(false) }, onPack)
            }
        })
        ui.notice?.let { (title, body) -> NoticeBanner(title, body, Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 8.dp)) { ui.notice = null } }
    }
    // Unterwegs öffnet ein Ort als Blatt über der Runde; die Aufzeichnung läuft weiter.
    if (!idle) ui.selected?.let { sel -> WalkPlaceSheet(sel, ui, onPack) }
    if (ui.adding) rec.here?.let { h -> AddPlaceSheet(h, onDismiss = { ui.adding = false }) { added -> ui.places = listOf(added) + ui.places; ui.selected = added } }
    if (ui.checks) MyChecksSheet { ui.checks = false }
}

/**
 * Die Karte füllt den ganzen Bildschirm, alles andere liegt darüber (wie MapStage in WalkViews.swift).
 * Breit: ein schwebendes Panel an der rechten Seite, senkrecht mittig. Schmal oder hochkant: ein Blatt von unten in drei
 * Stufen; der Kopf bleibt immer sichtbar. Die Karte erfährt, was verdeckt ist, und richtet sich danach aus.
 */
@Composable
private fun MapStage(detent: StageDetent, onDetent: (StageDetent) -> Unit, fitsContent: Boolean, map: @Composable (List<Float>) -> Unit, top: @Composable () -> Unit, header: @Composable () -> Unit, content: @Composable () -> Unit) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val dock = LocalDock.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = maxWidth; val h = maxHeight
        val statusTop = with(density) { WindowInsets.statusBars.getTop(this).toDp() }
        val navBottom = with(density) { WindowInsets.navigationBars.getBottom(this).toDp() }
        val inset = dockClearance(0.dp)
        val endSafe = with(density) { WindowInsets.safeDrawing.getRight(this, androidx.compose.ui.platform.LocalLayoutDirection.current).toDp() }
        if (w > h && w >= 600.dp) {
            // Breit: Panel rechts. Oben und unten gleich viel Rand, gemessen am ganzen Bildschirm.
            val endEdge = dock.end + endSafe + 12.dp
            val half = w / 2
            val width = minOf(440.dp, half - endEdge)
            val margin = maxOf(statusTop, inset) + 8.dp
            map(listOf(0f, 0f, (width + endEdge + 12.dp).value, 0f))
            Box(Modifier.align(Alignment.TopStart).padding(end = width + endEdge + 12.dp).statusBarsPadding().padding(top = 8.dp).widthIn(max = 420.dp)) { top() }
            Column(Modifier.align(Alignment.CenterEnd).padding(end = endEdge).padding(vertical = margin).width(width).then(if (fitsContent) Modifier else Modifier.fillMaxHeight())
                .shadow(22.dp, RoundedCornerShape(28.dp)).clip(RoundedCornerShape(28.dp)).background(p.paper)) {
                Box(Modifier.padding(horizontal = 16.dp).padding(top = 16.dp, bottom = if (fitsContent) 16.dp else 8.dp)) { header() }
                if (!fitsContent) Box(Modifier.weight(1f).fillMaxWidth()) { content() }
            }
        } else {
            // Schmal: ein Blatt in drei Stufen über der Leiste; sein Hintergrund läuft bis zum unteren Rand.
            var headerHeight by remember { mutableStateOf(130.dp) }
            val middle = (h - inset) * .5f
            val full = h - inset - statusTop - 8.dp
            fun heightOf(d: StageDetent) = when (d) { StageDetent.PEEK -> headerHeight; StageDetent.MIDDLE -> middle; StageDetent.FULL -> full }
            var drag by remember { mutableStateOf(0.dp) }
            val rest = if (fitsContent) headerHeight else heightOf(detent)
            val target = if (fitsContent) rest else (rest - drag).coerceIn(headerHeight, full)
            val shown by animateDpAsState(target, if (drag == 0.dp) spring(.85f, 500f) else snap(), label = "blatt")
            val covered = minOf(rest, middle) + inset
            map(listOf(0f, statusTop.value, 0f, covered.value))
            Box(Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 8.dp)) { top() }
            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().then(if (fitsContent) Modifier else Modifier.height(shown + inset))
                .shadow(18.dp, RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)).clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)).background(p.paper).padding(bottom = inset)) {
                Column(Modifier.onSizeChanged { headerHeight = with(density) { it.height.toDp() } }) {
                    if (!fitsContent) Box(Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 10.dp)
                        .pointerInput(Unit) {
                            detectVerticalDragGestures(onDragEnd = {
                                val at = rest - drag
                                onDetent(StageDetent.entries.minBy { abs((heightOf(it) - at).value) })
                                drag = 0.dp
                            }, onDragCancel = { drag = 0.dp }) { _, d -> drag += with(density) { d.toDp() } }
                        }
                        .clickable(remember { MutableInteractionSource() }, null, onClickLabel = L.t("Blatt größer oder kleiner")) {
                            onDetent(when (detent) { StageDetent.PEEK -> StageDetent.MIDDLE; StageDetent.MIDDLE -> StageDetent.FULL; StageDetent.FULL -> StageDetent.PEEK })
                        }, contentAlignment = Alignment.Center) {
                        Box(Modifier.size(38.dp, 5.dp).clip(RoundedCornerShape(50)).background(p.ink3.copy(alpha = .5f)))
                    }
                    Box(Modifier.padding(horizontal = 16.dp).padding(top = if (fitsContent) 16.dp else 0.dp, bottom = if (fitsContent) 12.dp else 8.dp)) { header() }
                }
                if (!fitsContent) Box(Modifier.weight(1f).fillMaxWidth().imePadding()) { content() }
            }
        }
    }
}

/** Die Runde ist beim Abschließen schon gespeichert; hier geht es nur noch um die Notiz. */
@Composable
private fun KeepButtons(ui: GassiUi) {
    val p = LocalPalette.current
    Button({
        ui.finished?.let { w -> if (w.notes.trim() != (Graph.store.walks.firstOrNull { it.id == w.id }?.notes ?: "")) Graph.store.save(w.copy(notes = w.notes.trim())) }
        ui.finished = null
    }, Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.ink, contentColor = p.paper)) {
        Text(L.t("Fertig"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Nach der Runde: Die Strecke liegt schon auf der Karte, hier stehen die Zahlen und die Notiz. */
@Composable
private fun FinishedContent(walk: Walk, ui: GassiUi) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text(L.t("Schöne Runde."), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 28.sp, color = p.ink)
        WalkNumbers(walk)
        SoftField(walk.notes, { n -> ui.finished = ui.finished?.copy(notes = n) }, L.t("Notiz, z. B. „Erstes Mal ohne Leine“"), singleLine = false)
    }
}

@Composable
private fun WalkNumbers(walk: Walk) {
    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        Box(Modifier.weight(1f)) { WalkNumber(L.t("Strecke"), WalkText.km(walk.meters), "km") }
        Box(Modifier.weight(1f)) { WalkNumber(L.t("Zeit"), WalkText.clock(walk.seconds), null) }
        Box(Modifier.weight(1f)) { WalkNumber(L.t("Tempo"), WalkText.pace(walk.pace), "/km") }
    }
}

@Composable
private fun WalkNumber(label: String, value: String, unit: String?) {
    val p = LocalPalette.current
    Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            FitText(value, androidx.compose.ui.text.TextStyle(fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 36.sp, color = p.ink), Modifier.weight(1f, fill = false), 20.sp)
            unit?.let { Text(it, fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 16.sp, color = p.ink2, softWrap = false, modifier = Modifier.padding(bottom = 5.dp)) }
        }
    }
}

@Composable
private fun PanelContent(ui: GassiUi, loading: Boolean, unavailable: Boolean, onLocate: () -> Unit, onPack: () -> Unit) {
    val sel = ui.selected
    if (sel != null) {
        key(sel.id) { PlaceContent(sel, showsMap = false, onClose = { ui.selected = null }, onChange = ui::update, onPack = onPack, onNotice = { ui.notice = it }, parent = L.t("Wohin heute?")) }
        return
    }
    val service = serviceUi.selected
    if (ui.reiter == GassiReiter.ADRESSEN && service != null) {
        key(service.id) { ServiceContent(service) { serviceUi.selected = null } }
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 24.dp)) {
        when (ui.reiter) {
            GassiReiter.WOHIN -> WohinList(ui, loading, unavailable, onLocate, onPack)
            GassiReiter.ADRESSEN -> ServicesPanel(onLocate)
            GassiReiter.RUNDEN -> RundenList(ui)
            GassiReiter.FREUNDE -> FriendsSection(onPack)
            GassiReiter.REVIER -> RevierPanel()
        }
    }
}

/** Kurze Meldung oben, etwa „23. Besuch“ nach dem Einchecken. */
@Composable
private fun NoticeBanner(title: String, body: String, modifier: Modifier, onTap: () -> Unit) {
    val p = LocalPalette.current
    Row(modifier.padding(horizontal = 16.dp).shadow(18.dp, RoundedCornerShape(50)).clip(RoundedCornerShape(50)).background(p.surface).clickable(onClick = onTap)
        .padding(start = 16.dp, end = 18.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        LineIcon(if (body.startsWith("Neues Abzeichen")) Sym.BADGE else Sym.PIN, p.accent, 26.dp)
        Column { Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink); Text(body, fontSize = 14.sp, color = p.ink2, maxLines = 2) }
    }
}

/** Befreundete Hunde, die gerade unterwegs sind, mit Name und Bild für die Karte. */
private fun friendSpots(): List<app.thisdog.gassi.FriendSpot> {
    val f = Graph.account.friends
    return f.live.mapNotNull { s -> f.list.firstOrNull { it.pack == s.pack }?.let { app.thisdog.gassi.FriendSpot("${it.pack}", it.name, s.at, it.photo) } }
}

@Composable
private fun FriendsSection(onPack: () -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current
    val friends = Graph.account.friends
    val scope = rememberCoroutineScope()
    var inviting by remember { mutableStateOf(false) }
    var qrLink by remember { mutableStateOf<Any?>(null) }
    var removing by remember { mutableStateOf<app.thisdog.gassi.Friends.Friend?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(L.t("Hundefreunde"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink, modifier = Modifier.weight(1f))
            Row(Modifier.clip(RoundedCornerShape(50)).clickable(enabled = !inviting) {
                if (!Graph.account.signedIn) { onPack(); return@clickable }
                inviting = true
                scope.launch {
                    runCatching { friends.invite() }
                        .onSuccess { share(context, L.t("Mit diesem Link sehen sich unsere Hunde in ThisDog auf der Karte, solange wir Gassi gehen.\n%1\$s", it), L.t("Werden unsere Hunde Freunde?")) }
                        .onFailure { friends.message = app.thisdog.data.Account.message(it) }
                    inviting = false
                }
            }.padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                LineIcon(Sym.ADD, p.accent, 20.dp); Text(L.t("Einladen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
            }
        }
        // Auf der Wiese: Der andere hält die Kamera drauf, das Telefon öffnet den Einladungslink.
        OutlinedButton({
            if (!Graph.account.signedIn) { onPack(); return@OutlinedButton }
            inviting = true
            scope.launch {
                runCatching { friends.invite() }.onSuccess { qrLink = it }.onFailure { friends.message = app.thisdog.data.Account.message(it) }
                inviting = false
            }
        }, Modifier.fillMaxWidth().height(48.dp), enabled = !inviting, shape = RoundedCornerShape(50)) {
            Text(L.t("QR-Code zeigen"), color = p.accent, fontWeight = FontWeight.SemiBold)
        }
        qrLink?.let { link ->
            AlertDialog({ qrLink = null }, title = { Text(L.t("Wer spielt da mit %1\$s?", Graph.store.profile.name.ifEmpty { "deinem Hund" })) }, text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(L.t("Der andere Mensch hält einfach die Handykamera drauf. Der Code gilt für einen Hund."))
                    val bmp = remember(link) { qrBitmap(link.toString(), 720).asImageBitmap() }
                    androidx.compose.foundation.Image(bmp, L.t("QR-Code zum Freundewerden"), Modifier.size(260.dp).background(Color.White).padding(12.dp), filterQuality = androidx.compose.ui.graphics.FilterQuality.None)
                }
            }, confirmButton = { TextButton({ qrLink = null }) { Text(L.t("Fertig")) } })
        }
        friends.message?.let { Text(it, fontSize = 14.sp, color = p.health) }
        if (friends.list.isEmpty()) Text(L.t("Befreundete Hunde seht ihr auf der Karte, solange ihr beide gerade Gassi geht."), fontSize = 15.sp, color = p.ink2)
        friends.list.forEach { f ->
            val spot = friends.live.firstOrNull { it.pack == f.pack }
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { removing = f }.padding(vertical = 6.dp).semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box {
                    AvatarView(f.photoJpeg, f.name, 40.dp, isDog = f.photoJpeg == null)
                    if (spot != null) Box(Modifier.align(Alignment.BottomEnd).size(12.dp).clip(CircleShape).background(p.paper).padding(2.dp).clip(CircleShape).background(p.ok))
                }
                Column(Modifier.weight(1f)) {
                    Text(f.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
                    val here = WalkRecorder.here
                    Text(when { spot == null -> L.t("Gerade nicht unterwegs"); here == null -> L.t("Gerade unterwegs")
                        else -> L.t("Gerade unterwegs, %1\$s entfernt", WalkText.distance(Track.distance(here, spot.at))) },
                        fontSize = 14.sp, color = if (spot == null) p.ink3 else p.ink2)
                }
            }
        }
    }
    removing?.let { f ->
        AlertDialog(onDismissRequest = { removing = null }, containerColor = p.paper,
            title = { Text(L.t("Freundschaft mit %1\$s beenden?", f.name)) },
            text = { Text(L.t("Ihr seht euch dann nicht mehr auf der Karte. Für eine neue Freundschaft braucht es eine neue Einladung.")) },
            confirmButton = { TextButton({ scope.launch { friends.remove(f) }; removing = null }) { Text(L.t("Beenden"), color = p.health) } },
            dismissButton = { TextButton({ removing = null }) { Text(L.t("Abbrechen"), color = p.ink) } })
    }
}

@Composable
private fun WohinList(ui: GassiUi, loading: Boolean, unavailable: Boolean, onLocate: () -> Unit, onPack: () -> Unit) {
    val places = ui.places
    val p = LocalPalette.current
    Column {
        Text(L.t("Wohin heute?"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, color = p.ink, modifier = Modifier.padding(bottom = 6.dp))
        val here = WalkRecorder.here
        if (here != null) {
            if (places.isEmpty()) Text(when { loading -> L.t("Ziele werden gesucht …"); unavailable -> L.t("Ziele lassen sich gerade nicht laden."); else -> L.t("In der Nähe ist nichts verzeichnet.") }, fontSize = 15.sp, color = p.ink3, modifier = Modifier.padding(vertical = 12.dp))
            val shown = places.sortedWith(compareBy({ Track.distance(here, it.coordinate) }, { it.rank })).take(12)
            shown.forEachIndexed { i, pl ->
                Box(Modifier.clickable { ui.selected = pl }) { PlaceRow(pl, here) }
                if (i < shown.size - 1) HorizontalDivider(Modifier.padding(start = 38.dp), color = p.line)
            }
            Row(Modifier.padding(top = 10.dp).clip(RoundedCornerShape(50)).clickable { if (!Graph.account.signedIn) onPack() else ui.adding = true }
                .padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                LineIcon(Sym.ADD, p.accent, 20.dp); Text(L.t("Ort fehlt? Eintragen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
            }
        } else {
            OutlinedButton(onLocate, shape = RoundedCornerShape(50), border = androidx.compose.foundation.BorderStroke(1.dp, p.line)) {
                LineIcon(Sym.MY_LOCATION, p.accent, 20.dp); Spacer(Modifier.width(8.dp)); Text(L.t("Standort freigeben"), color = p.accent, fontWeight = FontWeight.SemiBold)
            }
        }
        if (ui.scout) Row(Modifier.padding(top = 12.dp).clip(RoundedCornerShape(50)).clickable { ui.checks = true }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            LineIcon(Sym.SHIELD, p.accent, 20.dp); Text(L.t("Meine Prüfungen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
        }
        Box(Modifier.padding(top = 28.dp)) { AsphaltSection() }
    }
}

@Composable
private fun RundenList(ui: GassiUi) {
    val p = LocalPalette.current
    val store = Graph.store
    val walk = ui.shownWalk
    if (walk != null) { WalkDetail(walk, ui); return }
    Column {
        WeekLeash(store.walks)
        val all = store.walks.sortedByDescending { it.start }
        if (all.isEmpty()) Text(L.t("Noch keine Runden. Eure erste erscheint hier, sobald ihr unterwegs wart."), fontSize = 15.sp, color = p.ink2, modifier = Modifier.padding(top = 24.dp))
        else {
            Text(L.t("Letzte Runden"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink, modifier = Modifier.padding(top = 24.dp, bottom = 4.dp))
            all.forEachIndexed { i, w ->
                Box(Modifier.clickable { ui.show(w) }) { WalkRow(w, Graph.account.name(store.changer(Walk.KIND, w.id))) }
                if (i < all.size - 1) HorizontalDivider(Modifier.padding(start = 54.dp), color = p.line)
            }
        }
    }
}

/** Die angetippte Runde: Ihre Strecke liegt schon auf der Karte, hier stehen die Zahlen. */
@Composable
private fun WalkDetail(walk: Walk, ui: GassiUi) {
    val p = LocalPalette.current
    val at = Instant.ofEpochMilli(walk.start.toLong()).atZone(ZoneId.systemDefault())
    val short = at.format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM).withLocale(L.locale))
    val long = at.format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.LONG).withLocale(L.locale))
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Breadcrumb(L.t("Runden"), short) { ui.show(null) }
        Text("$long, ${L.t("%d:%02d Uhr").format(at.hour, at.minute)}", fontWeight = FontWeight.SemiBold, color = p.ink)
        WalkNumbers(walk)
        if (walk.notes.isNotEmpty()) Text(walk.notes, color = p.ink2)
    }
}

@Composable
private fun PlaceRow(pl: Place, here: LatLng) {
    val p = LocalPalette.current
    val round = pl.roundTrip(here)
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        LineIcon(if (pl.isDogZone) Sym.PAW else Sym.PARK, p.accent, 26.dp)
        Column(Modifier.weight(1f)) {
            Text(pl.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val good = listOf(PlaceFeature.FENCED to L.t("eingezäunt"), PlaceFeature.WATER to L.t("Wasser"), PlaceFeature.SHADE to L.t("Schatten")).filter { pl.verdict(it.first) is PlaceVerdict.Yes }.map { it.second }
            if (good.isNotEmpty()) Text((listOf(pl.label) + good).joinToString(", "), fontSize = 14.sp, color = p.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
            else Text(L.t("%1\$s etwa %2\$s, %3\$s Min.", if (pl.name == pl.label) L.t("Runde") else L.t("%1\$s, Runde", pl.label), WalkText.distance(round), Place.minutes(round)), fontSize = 14.sp, color = p.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(WalkText.distance(Track.distance(here, pl.coordinate)), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = p.ink)
    }
}

/** Die Woche als Leine: ein Punkt je Tag, je größer, desto weiter gelaufen. */
@Composable
fun WeekLeash(walks: List<Walk>, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val today = Day.today(); val monday = today.addingDays(-today.weekdayFromMonday)
    val km = (0 until 7).map { i -> walks.filter { it.day == monday.addingDays(i) }.sumOf { it.meters } / 1000 }
    val count = walks.count { it.day >= monday }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(String.format(app.thisdog.i18n.L.locale, "%.1f", km.sum()), fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 40.sp, lineHeight = 40.sp, color = p.accent)
            Text(if (count == 1) L.t("km diese Woche, eine Runde") else L.t("km diese Woche, %1\$s Runden", count), fontFamily = Display, fontSize = 17.sp, color = p.ink, modifier = Modifier.padding(bottom = 5.dp))
        }
        Box(Modifier.fillMaxWidth().height(56.dp).semantics {
            contentDescription = Day.WEEKDAY_SHORT.zip(km).joinToString { (d, k) -> if (k > 0) "$d ${WalkText.distance(k * 1000)}" else L.t("%1\$s keine Runde", d) }
        }) {
            Canvas(Modifier.fillMaxWidth().height(40.dp)) {
                val step = (size.width - 28.dp.toPx()) / 6; val y = 20.dp.toPx(); val x0 = 14.dp.toPx()
                drawLine(p.line, Offset(x0, y), Offset(size.width - x0, y), 1.4.dp.toPx(), StrokeCap.Round)
                km.forEachIndexed { i, k ->
                    val c = Offset(x0 + i * step, y)
                    if (k > 0) drawCircle(p.accent.copy(alpha = (0.35 + minOf(k, 6.0) / 10).toFloat()), (3 + minOf(k, 6.0) * 2.4).dp.toPx(), c)
                    else { drawCircle(p.paper, 3.dp.toPx(), c); drawCircle(p.ink3, 3.dp.toPx(), c, style = Stroke(1.2.dp.toPx())) }
                }
            }
            Row(Modifier.fillMaxWidth().align(Alignment.BottomCenter)) {
                Day.WEEKDAY_SHORT.forEachIndexed { i, d ->
                    Text(d, fontSize = 11.sp, color = p.ink3, modifier = Modifier.width(28.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    if (i < 6) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

/** Eine Zeile in „Letzte Runden“. */
@Composable
private fun WalkRow(w: Walk, by: String?) {
    val p = LocalPalette.current
    val time = Instant.ofEpochMilli(w.start.toLong()).atZone(ZoneId.systemDefault()).toLocalTime()
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.width(42.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("${w.day.day}", fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 19.sp, lineHeight = 20.sp, color = p.ink)
            Text(Day.MONTH_SHORT[w.day.month - 1], fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
        }
        Column(Modifier.weight(1f)) {
            Text(L.t("%1\$s in %2\$s", WalkText.distance(w.meters), WalkText.duration(w.seconds)), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
            Text(by?.let { L.t("%1\$s war unterwegs", it) } ?: L.t("%d:%02d Uhr").format(time.hour, time.minute), fontSize = 14.sp, color = p.ink2)
        }
    }
}

// Unterwegs

/** Unterwegs an einem Ort (höchstens 80 m): einchecken oder später. */
@Composable
private fun NearCard(ui: GassiUi) {
    val p = LocalPalette.current
    val here = WalkRecorder.here ?: return
    if (WalkRecorder.phase == Phase.IDLE) return
    val store = Graph.store
    val place = ui.places.firstOrNull {
        Track.distance(here, it.coordinate) <= app.thisdog.gassi.CheckIns.PROMPT && it.id !in ui.dismissed && app.thisdog.gassi.CheckIns.recent(it, store.checkIns) == null
    } ?: return
    val n = app.thisdog.gassi.CheckIns.visits(place, store.checkIns).size
    Column(Modifier.padding(horizontal = 12.dp).fillMaxWidth().shadow(18.dp, RoundedCornerShape(24.dp)).clip(RoundedCornerShape(24.dp)).background(p.surface).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LineIcon(if (place.isDogZone) Sym.PAW else Sym.PARK, p.accent, 28.dp)
            Column {
                Text(L.t("Du bist bei %1\$s", place.name), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, color = p.ink)
                Text(if (n == 0) L.t("Zum ersten Mal hier") else L.t("%1\$s war %2\$s-mal hier", store.profile.name.ifEmpty { "Dein Hund" }, n), fontSize = 14.sp, color = p.ink2)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button({ ui.notice = checkIn(place) }, Modifier.weight(1f).height(48.dp), shape = RoundedCornerShape(50),
                colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) { LineIcon(Sym.PIN, Color.White, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("Einchecken"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
            OutlinedButton({ ui.dismissed.add(place.id) }, Modifier.height(48.dp), shape = RoundedCornerShape(50), border = androidx.compose.foundation.BorderStroke(1.dp, p.line)) {
                Text(L.t("Später"), fontSize = 16.sp, color = p.ink2)
            }
        }
    }
}

/** Unterwegs unter den Knöpfen: Orte in Reichweite zum Einchecken; Antippen öffnet die Ortsseite. */
@Composable
private fun NearbyWhileWalking(ui: GassiUi) {
    val p = LocalPalette.current
    val here = WalkRecorder.here ?: return
    val store = Graph.store
    val near = ui.places.filter { app.thisdog.gassi.CheckIns.inReach(it, here) }.sortedBy { Track.distance(here, it.coordinate) }.take(3)
    if (near.isEmpty()) return
    Column {
        Text(L.t("Hier in der Nähe"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = p.ink, modifier = Modifier.padding(bottom = 2.dp))
        near.forEach { pl ->
            val recent = app.thisdog.gassi.CheckIns.recent(pl, store.checkIns)
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable { ui.selected = pl }.padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                LineIcon(if (pl.isDogZone) Sym.PAW else Sym.PARK, p.accent, 24.dp)
                Column(Modifier.weight(1f)) {
                    Text(pl.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(L.t("%1\$s, %2\$s entfernt", pl.label, WalkText.distance(Track.distance(here, pl.coordinate))), fontSize = 13.sp, color = p.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (recent != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    LineIcon(Sym.CHECK, p.accent, 20.dp); Text(L.t("Eingecheckt"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
                } else Button({ ui.notice = checkIn(pl) }, Modifier.height(40.dp), shape = RoundedCornerShape(50), contentPadding = PaddingValues(horizontal = 14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) {
                    Text(L.t("Einchecken"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

/** Ein Ort unterwegs: dieselbe Ortsseite wie vor der Runde, als Blatt über Karte und Runde. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WalkPlaceSheet(sel: Place, ui: GassiUi, onPack: () -> Unit) {
    val p = LocalPalette.current
    ModalBottomSheet(onDismissRequest = { ui.selected = null }, containerColor = p.paper) {
        key(sel.id) {
            PlaceContent(sel, showsMap = false, onClose = { ui.selected = null }, onChange = ui::update, onPack = { ui.selected = null; onPack() }, onNotice = { ui.notice = it })
        }
    }
}

@Composable
private fun Controls(onDiscard: () -> Unit, onFinish: () -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current
    val paused = WalkRecorder.phase == Phase.PAUSED
    var confirmsDiscard by remember { mutableStateOf(false) }
    if (confirmsDiscard) {
        AlertDialog(onDismissRequest = { confirmsDiscard = false }, containerColor = p.paper,
            title = { Text(L.t("Runde abbrechen?")) },
            text = { Text(L.t("Die Runde wird nicht gespeichert.")) },
            confirmButton = { TextButton({ confirmsDiscard = false; onDiscard() }) { Text(L.t("Runde verwerfen"), color = p.health) } },
            dismissButton = { TextButton({ confirmsDiscard = false }) { Text(L.t("Weiterlaufen"), color = p.ink) } })
    }
    // Klein und mit Rückfrage – Abbrechen ist die Ausnahme.
    TextButton({ confirmsDiscard = true }, Modifier.fillMaxWidth().wrapContentWidth(Alignment.End).height(36.dp)) {
        Text(L.t("Abbrechen"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton({ if (paused) WalkRecorder.resume(context) else WalkRecorder.pause(context) }, Modifier.weight(1f).height(52.dp), shape = RoundedCornerShape(50),
            border = androidx.compose.foundation.BorderStroke(1.dp, p.line), colors = ButtonDefaults.outlinedButtonColors(containerColor = p.surface, contentColor = p.ink)) {
            Text(if (paused) L.t("Weiter") else L.t("Pause"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        // Abschließen speichert die Runde sofort, ohne Rückfrage.
        Button(onFinish, Modifier.weight(1f).height(52.dp), shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.ink, contentColor = p.paper)) {
            Text(L.t("Abschließen"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Die großen Zahlen unterwegs: Zeit, Strecke, Tempo, darunter die Kilometer als Leine. */
@Composable
private fun LiveStats(compact: Boolean, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    val paused = WalkRecorder.phase == Phase.PAUSED
    Column(modifier, verticalArrangement = Arrangement.spacedBy(if (compact) 12.dp else 24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(18.dp).clip(CircleShape).background(p.soft).alpha(if (paused) .3f else 1f), contentAlignment = Alignment.Center) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(p.accent))
            }
            Text(if (paused) L.t("Pause") else L.t("Unterwegs"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
        }
        Stat(L.t("Zeit"), WalkText.clock(WalkRecorder.seconds(now)), null, if (compact) 88.sp else 112.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(40.dp)) {
            Stat(L.t("Strecke"), WalkText.km(WalkRecorder.meters), "km", if (compact) 40.sp else 52.sp)
            Stat(L.t("Tempo"), WalkText.pace(WalkRecorder.pace), "/km", if (compact) 40.sp else 52.sp)
        }
        if (!compact && WalkRecorder.splits.isNotEmpty()) Splits()
    }
}

@Composable
private fun Stat(label: String, value: String, unit: String?, size: TextUnit) {
    val p = LocalPalette.current
    Column(Modifier.semantics(mergeDescendants = true) {}) {
        Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(value, fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = size, lineHeight = size, color = p.ink,
                style = LocalTextStyle.current.copy(fontFeatureSettings = "tnum"))
            unit?.let { Text(it, fontFamily = Display, fontSize = size * 0.42f, color = p.ink2, modifier = Modifier.padding(bottom = (size.value * 0.1).dp)) }
        }
    }
}

/** Je Kilometer ein Punkt mit der Zeit für diesen Kilometer. */
@Composable
private fun Splits() {
    val p = LocalPalette.current
    val s = WalkRecorder.splits
    val times = s.mapIndexed { i, t -> t - (if (i == 0) 0.0 else s[i - 1]) }
    Row(verticalAlignment = Alignment.Top) {
        times.forEachIndexed { i, t ->
            Column(Modifier.width(56.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(p.accent))
                Text(L.t("km %1\$s", i + 1), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                Text(WalkText.clock(t), fontSize = 12.sp, color = p.ink)
            }
            if (i < times.size - 1) Box(Modifier.padding(top = 4.dp).width(30.dp).height(1.4.dp).background(p.line))
        }
    }
}
