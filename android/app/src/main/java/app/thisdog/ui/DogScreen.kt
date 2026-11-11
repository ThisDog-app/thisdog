package app.thisdog.ui

import app.thisdog.i18n.L
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.zIndex
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.data.Kinds
import app.thisdog.model.*
import java.io.ByteArrayOutputStream
import java.util.Base64
import kotlin.math.max
import kotlin.math.min

/** Ein Foto quadratisch (Mitte), 320 px, JPEG – höchstens 60 000 Zeichen Base64, wie Avatar.prepare in Swift. */
object AvatarImage {
    fun prepare(bytes: ByteArray): String? = Pictures.load(bytes, 1200)?.let(::prepare)

    /** Aus der Galerie, auch HEIC (über [Pictures], aufrecht gedreht). */
    fun prepare(context: android.content.Context, uri: android.net.Uri): String? = runCatching { Pictures.load(context, uri, 1200)?.let(::prepare) }.getOrNull()

    fun prepare(src: Bitmap): String? {
        val edge = min(src.width, src.height)
        val square = Bitmap.createBitmap(src, (src.width - edge) / 2, (src.height - edge) / 2, edge, edge)
        for (side in listOf(320, 240)) {
            val scaled = Bitmap.createScaledBitmap(square, side, side, true)
            for (q in listOf(72, 60, 45, 30)) {
                val out = ByteArrayOutputStream(); scaled.compress(Bitmap.CompressFormat.JPEG, q, out)
                val b64 = Base64.getEncoder().encodeToString(out.toByteArray())
                if (b64.length <= 60_000) return b64
            }
        }
        return null
    }
}

/** Ein Avatar, den man antippt, um ein Foto zu wählen (Android-Fotoauswahl: die App sieht nur das eine Foto). */
@Composable
fun AvatarPicker(id: String, name: String = "", size: androidx.compose.ui.unit.Dp, isDog: Boolean, label: String) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val store = Graph.store
    val jpeg = store.avatars.firstOrNull { it.id == id }?.jpeg
    var failed by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        AvatarImage.prepare(context, uri)?.let { store.upsert(Kinds.avatar, Avatar(id, it)) } ?: run { failed = true }
    }
    if (failed) AlertDialog(onDismissRequest = { failed = false }, containerColor = p.paper,
        title = { Text(L.t("Dieses Foto ließ sich nicht verwenden.")) },
        text = { Text(L.t("Versuch es mit einem anderen Foto.")) },
        confirmButton = { TextButton({ failed = false }) { Text(L.t("OK"), color = p.accent) } })
    Box(Modifier.size(size).clickable { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }.semantics { contentDescription = label }) {
        AvatarView(jpeg, name, size, isDog)
        Box(Modifier.align(Alignment.BottomEnd).size(max(20f, size.value * 0.3f).dp).clip(CircleShape).background(p.accent),
            contentAlignment = Alignment.Center) { LineIcon(if (jpeg == null) Sym.ADD else Sym.CAMERA, androidx.compose.ui.graphics.Color.White, max(14f, size.value * 0.2f).dp) }
    }
}

/** Zum Ansehen (Entwicklerfassung): `--es hundreiter futter` öffnet einen Reiter. */
object DogDemo { var reiter: String? = null }

/** Was die Seite des Hundes zum Schmunzeln sagt, getrennt von der Darstellung. */
object DogFacts {
    /** Die Zeile zum Schmunzeln: der nahe Geburtstag, sonst das Alter in Menschenjahren. */
    fun funFact(p: DogProfile, today: Day = Day.today()): String? {
        val birth = p.birthDay ?: return null
        if (birth > today) return null
        var next = birth
        while (next < today) next = next.addingYears(1)
        val days = today.daysUntil(next)
        if (birth != today && days == 0) return L.t("Heute ist Geburtstag! Alles Gute, %1\$s!", p.name)
        if (birth != today && days == 1) return L.t("Morgen ist Geburtstag. Schon was besorgt?")
        if (birth != today && days <= 60) return L.t("Noch %1\$d Tage bis zum Geburtstag.", days)
        return L.t("In Menschenjahren etwa %1\$d.", humanYears(birth.daysUntil(today) / 30.44, p.weightKg))
    }

    /** Grobe Faustregel: Das erste Jahr zählt 15, das zweite 9, danach je nach Größe 4 bis 7. */
    fun humanYears(months: Double, weightKg: Double?): Int {
        val w = weightKg ?: 15.0
        val perYear = if (w < 11) 4.0 else if (w < 26) 5.0 else 7.0
        val years = months / 12
        val human = if (years <= 1) years * 15 else if (years <= 2) 15 + (years - 1) * 9 else 24 + (years - 2) * perYear
        return Math.round(human).toInt()
    }
}

private enum class DogReiter { STELLA, GESUNDHEIT, FUTTER }

/**
 * Der Hund: wer er ist und was er erlebt hat; darunter drei Reiter für den Überblick, die Gesundheit und das Futter.
 * Breit und quer steht er fest links, rechts laufen die Reiter an ihm vorbei.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun DogScreen(wide: Boolean, onPack: () -> Unit, onEmergency: () -> Unit) {
    val store = Graph.store
    val p = LocalPalette.current
    val quer = isQuer()
    var reiter by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(DogReiter.entries.firstOrNull { it.name.equals(DogDemo.reiter, true) } ?: DogReiter.STELLA) }
    var editsProfile by remember { mutableStateOf(false) }
    var addsWeight by remember { mutableStateOf(false) }
    var health by remember { mutableStateOf<HealthEdit?>(null) }
    val bottom = dockClearance()
    val leiste: @Composable () -> Unit = {
        ReiterLeiste(listOf(DogReiter.STELLA to store.profile.name, DogReiter.GESUNDHEIT to L.t("Gesundheit"), DogReiter.FUTTER to L.t("Futter")), reiter) { reiter = it }
    }
    val content: @Composable () -> Unit = {
        when (reiter) {
            DogReiter.STELLA -> Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(36.dp)) {
                DueRings(); Weight(sideBySide = quer) { addsWeight = true }
            }
            DogReiter.GESUNDHEIT -> Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(36.dp)) {
                HealthList { health = it }; HealthDiarySection()
            }
            DogReiter.FUTTER -> FeedingSection()
        }
    }
    val hero: @Composable () -> Unit = { Hero(quer) { editsProfile = true } }
    val extras: @Composable () -> Unit = { Extras(onEmergency, onPack) }
    when {
        !store.hasProfile -> Column(Modifier.fillMaxSize().background(p.paper).padding(28.dp), verticalArrangement = Arrangement.Center) {
            Text(L.t("Wer ist dein Hund?"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 44.sp, lineHeight = 48.sp, color = p.ink)
            Spacer(Modifier.height(16.dp))
            Text(L.t("Name, Geburtstag und Gewicht genügen für den Anfang. Daraus entstehen Alter, Geburtstag im Kalender und die Futtermenge."), color = p.ink2)
            Spacer(Modifier.height(16.dp))
            PrimaryButton(L.t("Hund anlegen")) { editsProfile = true }
        }
        quer -> Row(Modifier.fillMaxSize().background(p.paper).padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Column(Modifier.width(320.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) { hero(); extras() }
            Column(Modifier.weight(1f).fillMaxHeight().padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                leiste()
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 10.dp, bottom = 24.dp)) { content() }
            }
        }
        // Links, wer der Hund ist; rechts die Reiter.
        wide -> Row(Modifier.fillMaxSize().background(p.paper).statusBarsPadding()) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 32.dp).padding(top = 24.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(18.dp)) { hero(); extras() }
            Column(Modifier.weight(1f).fillMaxHeight().padding(horizontal = 32.dp).padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                leiste()
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 8.dp, bottom = bottom)) { content() }
            }
        }
        else -> androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxSize().background(p.paper).statusBarsPadding(), contentPadding = PaddingValues(bottom = bottom)) {
            item { Box(Modifier.padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 12.dp)) { hero() } }
            stickyHeader { Box(Modifier.fillMaxWidth().background(p.paper).padding(horizontal = 20.dp, vertical = 6.dp)) { leiste() } }
            item {
                Column(Modifier.padding(horizontal = 20.dp).padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(36.dp)) {
                    content()
                    if (reiter == DogReiter.STELLA) extras()
                }
            }
        }
    }
    if (editsProfile) ProfileEditor { editsProfile = false }
    if (addsWeight) WeightEditor { addsWeight = false }
    health?.let { HealthEditor(it) { health = null } }
}

/** Wer der Hund ist, und an der Leine, die an seinem Foto hängt, was er schon erlebt hat. */
@Composable
private fun Hero(quer: Boolean, onEdit: () -> Unit) {
    val p = LocalPalette.current
    val store = Graph.store
    val pr = store.profile
    val who = listOfNotNull(pr.breed.ifEmpty { null }, pr.sexLabel).joinToString(", ")
    val age = listOfNotNull(pr.age(), pr.stage()?.lowercase()).joinToString(", ")
    // Der Spruch ist eine Randnotiz: gleiche Schrift und gleiche Kante wie Rasse und Alter.
    val facts = listOfNotNull(who.ifEmpty { null }, age.ifEmpty { null }, DogFacts.funFact(pr))
    val photo = if (quer) 92.dp else 112.dp
    Column {
        Box(Modifier.zIndex(1f)) {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                AvatarPicker(Avatar.DOG, size = photo, isDog = true, label = L.t("Foto von %1\$s", pr.name))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    // Nur der Name weicht dem Stift aus; darunter steht die volle Breite zur Verfügung.
                    FitText(pr.name, androidx.compose.ui.text.TextStyle(fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = if (quer) 32.sp else 40.sp, color = p.ink), Modifier.padding(end = 44.dp), 20.sp)
                    if (facts.isNotEmpty()) Text(facts.joinToString("\n"), fontSize = 15.sp, lineHeight = 20.sp, color = p.ink2)
                }
            }
            Box(Modifier.align(Alignment.TopEnd)) { RoundButton(Sym.EDIT, L.t("Profil bearbeiten"), 44.dp, p.accent, onEdit) }
        }
        LeashTally(photo, listOf(store.walks.size to L.t("Runden"), Math.round(store.walks.sumOf { it.meters } / 1000).toInt() to L.t("Kilometer"), app.thisdog.gassi.Revier(store.checkIns).spots.size to L.t("Orte")))
    }
}

/**
 * Die Bilanz an einer Leine: Sie hängt am Foto und läuft durch alles, was der Hund schon erlebt hat.
 * Die Zahlen stehen frei auf der Linie und folgen ihrem Auf und Ab. Sie darf ruhig wild sein: So sind die meisten Hunde.
 */
@Composable
private fun LeashTally(photo: androidx.compose.ui.unit.Dp, items: List<Pair<Int, String>>) {
    val p = LocalPalette.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(88.dp).semantics(mergeDescendants = true) { contentDescription = items.joinToString(", ") { "${it.first} ${it.second}" } }) {
        val w = maxWidth.value
        val stops = listOf(Offset(w * .09f, 72f), Offset(w * .40f, 54f), Offset(w * .71f, 74f))
        val pts = listOf(
            // Beginnt hinter dem Foto, damit es so aussieht, als hinge die Leine am Halsband.
            Offset(photo.value * .22f, -photo.value * .2f), Offset(6f, 14f), Offset(3f, 42f),
            stops[0], Offset(w * .25f, 78f), stops[1], Offset(w * .56f, 50f), stops[2],
            // Am Ende eine Locke wie im Logo.
            Offset(w * .88f, 72f), Offset(w - 3f, 56f), Offset(w - 8f, 43f),
            Offset(w - 20f, 41f), Offset(w - 25f, 51f), Offset(w - 18f, 56f),
        )
        Canvas(Modifier.matchParentSize()) {
            val d = density
            drawPath(leashCurve(pts.map { Offset(it.x * d, it.y * d) }), p.accent, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = androidx.compose.ui.graphics.StrokeJoin.Round))
            pts.last().let { drawCircle(p.accent, 4.5.dp.toPx(), Offset(it.x * d, it.y * d)) }
            stops.forEach { drawCircle(p.accent, 5.5.dp.toPx(), Offset(it.x * d, it.y * d)) }
        }
        items.forEachIndexed { i, (n, label) ->
            Row(Modifier.offset(x = (stops[i].x - 5f).dp, y = (stops[i].y - 37f).dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("$n", fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 23.sp, lineHeight = 26.sp, color = p.ink, softWrap = false)
                Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = p.ink2, softWrap = false, modifier = Modifier.padding(bottom = 3.dp))
            }
        }
    }
}

@Composable
private fun DueRings() {
    val p = LocalPalette.current
    val today = Day.today()
    val upcoming = Graph.store.dues.filter { it.due >= today.addingDays(-60) }.take(3)
    if (upcoming.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Title(L.t("Was ansteht"))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            upcoming.forEach { due ->
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    val overdue = due.due < today
                    val color = if (overdue) p.health else p.accent
                    val progress = (due.progress() ?: if (overdue) 1.0 else 0.02).toFloat()
                    Box(Modifier.size(64.dp), contentAlignment = Alignment.Center) {
                        Canvas(Modifier.matchParentSize()) {
                            val w = 6.dp.toPx(); val inset = w / 2
                            drawArc(color.copy(alpha = .16f), 0f, 360f, false, Offset(inset, inset), androidx.compose.ui.geometry.Size(size.width - w, size.height - w), style = Stroke(w))
                            drawArc(color, -90f, 360f * progress, false, Offset(inset, inset), androidx.compose.ui.geometry.Size(size.width - w, size.height - w), style = Stroke(w, cap = StrokeCap.Round))
                        }
                        Text(dueRingText(due.due), fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 14.sp, lineHeight = 15.sp, color = p.ink, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    }
                    Column { Text(due.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 1); Text(due.kind, fontSize = 12.sp, color = p.ink2) }
                    if (Graph.store.canMarkDone(due)) DoneChip { Graph.store.markDone(due.id) }
                }
            }
            repeat(3 - upcoming.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

fun kg(v: Double) = if (v % 1.0 == 0.0) "${v.toInt()}" else String.format(app.thisdog.i18n.L.locale, "%.1f", v)

@Composable
private fun Weight(sideBySide: Boolean, onAdd: () -> Unit) {
    val p = LocalPalette.current
    val list = Graph.store.weights.sortedBy { it.d }
    val target = Graph.store.profile.targetWeightKg
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) { Title(L.t("Gewicht")); Spacer(Modifier.weight(1f)); RoundButton(Sym.ADD, L.t("Gewicht eintragen"), 44.dp, p.accent, onAdd) }
        val last = list.lastOrNull()
        if (last == null) { Text(L.t("Noch kein Gewicht eingetragen."), fontSize = 15.sp, color = p.ink3); return }
        val value: @Composable () -> Unit = {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(kg(last.kg), fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 44.sp, color = p.ink, lineHeight = 46.sp)
                Text("kg", fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 22.sp, color = p.ink2, modifier = Modifier.padding(bottom = 5.dp))
            }
        }
        val targetLine: @Composable () -> Unit = { target?.let { Text(L.t("Wunschgewicht %1\$s kg", kg(it)), fontSize = 13.sp, color = p.ink3) } }
        if (sideBySide) {
            // Quer: Zahl neben der Kurve, damit beide zugleich auf den niedrigen Bildschirm passen.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Column(Modifier.width(124.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    value(); trend(list)?.let { Text(it, fontSize = 13.sp, color = p.ink2) }; targetLine()
                }
                if (list.size > 1) WeightChart(list, target, Modifier.weight(1f).height(120.dp))
            }
        } else {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                value(); trend(list)?.let { Text(it, fontSize = 15.sp, color = p.ink2, modifier = Modifier.padding(bottom = 7.dp)) }
            }
            if (list.size > 1) WeightChart(list, target, Modifier.fillMaxWidth().height(160.dp))
            targetLine()
        }
    }
}

/** Die Kurve ohne Rahmen: Wunschgewicht als zarte Bahn, der letzte Wert als Punkt, darunter ein paar Monate. */
@Composable
private fun WeightChart(list: List<WeightEntry>, target: Double?, modifier: Modifier) {
    val p = LocalPalette.current
    val kgs = list.map { it.kg } + listOfNotNull(target)
    val lo = kgs.min() - 0.5; val hi = kgs.max() + 0.5
    val days = list.map { Day.parse(it.d)!! }
    val span = maxOf(1, days.first().daysUntil(days.last()))
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Canvas(Modifier.fillMaxWidth().weight(1f)) {
            fun y(v: Double) = (size.height * (1 - (v - lo) / (hi - lo))).toFloat()
            fun x(d: Day) = size.width * days.first().daysUntil(d) / span.toFloat()
            target?.let { drawRect(p.soft, Offset(0f, y(it * 1.03)), androidx.compose.ui.geometry.Size(size.width, y(it * 0.97) - y(it * 1.03))) }
            for (k in 0..3) { val yy = size.height * k / 3f; drawLine(p.line, Offset(0f, yy), Offset(size.width, yy), 1f) }
            drawPath(leashCurve(list.mapIndexed { i, w -> Offset(x(days[i]), y(w.kg)) }), p.accent, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round))
            drawCircle(p.accent, 4.dp.toPx(), Offset(x(days.last()), y(list.last().kg)))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            (0..3).forEach { i -> val d = days.first().addingDays(span * i / 3); Text(Day.MONTH_SHORT[d.month - 1], fontSize = 11.sp, color = p.ink3) }
        }
    }
}

private fun trend(list: List<WeightEntry>): String? {
    val last = list.lastOrNull() ?: return null
    val ref = list.dropLast(1).lastOrNull { Day.parse(it.d)!! <= Day.today().addingMonths(-1) } ?: list.firstOrNull() ?: return null
    if (ref.d == last.d) return null
    val diff = last.kg - ref.kg
    val since = Day.parse(ref.d)!!.shortText
    return if (kotlin.math.abs(diff) < 0.05) L.t("gleich seit %1\$s", since) else L.t("%1\$s%2\$s kg seit %3\$s", if (diff > 0) "+" else "−", kg(kotlin.math.abs(diff)), since)
}

sealed interface HealthEdit { data class Vac(val v: Vaccination) : HealthEdit; data class Worm(val d: Deworming) : HealthEdit; data class Med(val m: Medication) : HealthEdit }

@Composable
private fun HealthList(onOpen: (HealthEdit) -> Unit) {
    val p = LocalPalette.current
    val s = Graph.store
    var menu by remember { mutableStateOf(false) }
    data class Item(val id: String, val sym: String, val title: String, val detail: String, val due: String, val edit: HealthEdit)
    val items = (s.vaccinations.map { Item(it.id, Sym.VACCINE, it.name.ifEmpty { L.t("Impfung") }, listOfNotNull(L.t("Impfung"), if (it.next.isEmpty()) Day.parse(it.date)?.shortText else null).joinToString(", "), it.next, HealthEdit.Vac(it)) } +
        s.dewormings.map { Item(it.id, Sym.PILL, it.product.ifEmpty { L.t("Entwurmung") }, listOfNotNull(L.t("Entwurmung"), if (it.next.isEmpty()) Day.parse(it.date)?.shortText else null).joinToString(", "), it.next, HealthEdit.Worm(it)) } +
        s.meds.map { Item(it.id, Sym.MED, it.name.ifEmpty { L.t("Medikament") }, listOfNotNull(L.t("Medikament"), it.dose.ifEmpty { null }).joinToString(", "), it.to, HealthEdit.Med(it)) })
        .sortedWith(compareBy<Item>({ Day.parse(it.due) == null }, { Day.parse(it.due) }, { it.title }))
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Die Überschrift steht schon im Reiter; hier nur, was dazugehört.
            Text(L.t("Impfungen, Entwurmungen, Medikamente"), fontSize = 15.sp, color = p.ink2, modifier = Modifier.weight(1f))
            Box { RoundButton(Sym.ADD, L.t("Eintragen"), 44.dp, p.accent) { menu = true }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text(L.t("Impfung")) }, { menu = false; onOpen(HealthEdit.Vac(Vaccination(newHealthID("vaccinations")))) }, leadingIcon = { LineIcon(Sym.VACCINE, p.ink, 20.dp) })
                    DropdownMenuItem({ Text(L.t("Entwurmung")) }, { menu = false; onOpen(HealthEdit.Worm(Deworming(newHealthID("deworming")))) }, leadingIcon = { LineIcon(Sym.PILL, p.ink, 20.dp) })
                    DropdownMenuItem({ Text(L.t("Medikament")) }, { menu = false; onOpen(HealthEdit.Med(Medication(newHealthID("meds")))) }, leadingIcon = { LineIcon(Sym.MED, p.ink, 20.dp) })
                }
            }
        }
        if (items.isEmpty()) Text(L.t("Impfungen, Entwurmungen und Medikamente stehen hier, sortiert nach dem, was zuerst fällig wird."), fontSize = 15.sp, color = p.ink3)
        else Column(Modifier.clip(RoundedCornerShape(24.dp)).background(p.surface).padding(horizontal = 16.dp, vertical = 4.dp)) {
            items.forEachIndexed { i, it ->
                Row(Modifier.fillMaxWidth().clickable { onOpen(it.edit) }.padding(vertical = 11.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    LineIcon(it.sym, p.accent, 26.dp)
                    Column(Modifier.weight(1f)) { Text(it.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 1); Text(it.detail, fontSize = 14.sp, color = p.ink2, maxLines = 1) }
                    Day.parse(it.due)?.let { d -> DueChip(d) }
                }
                if (i < items.lastIndex) HorizontalDivider(color = p.line, modifier = Modifier.padding(start = 40.dp))
            }
        }
    }
}

/** Die Wege zu Notfallpass und Rudel: zwei Zeilen, keine Kacheln. */
@Composable
private fun Extras(onEmergency: () -> Unit, onPack: () -> Unit) {
    val name = Graph.store.profile.name
    val members = Graph.account.currentPack?.members.orEmpty()
    Column {
        ExtraRow(Sym.EMERGENCY, L.t("Notfallpass"), L.t("QR-Code fürs Halsband, falls jemand %1\$s findet", name), onEmergency)
        ExtraRow(Sym.GROUP, L.t("Rudel"), if (members.size > 1) members.joinToString(", ") { it.name } else L.t("Teile %1\$s mit deinen Menschen", name), onPack)
    }
}

@Composable
private fun ExtraRow(sym: String, title: String, line: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = onClick).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        LineIcon(sym, p.accent, 26.dp)
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = p.ink)
            Text(line, fontSize = 13.sp, color = p.ink2, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
    }
}

// MARK: Bearbeiten

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Sheet(title: String, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 30.sp, color = p.ink); content()
        }
    }
}

@Composable private fun Field(value: String, label: String, number: Boolean = false, onChange: (String) -> Unit) =
    OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
        keyboardOptions = KeyboardOptions(keyboardType = if (number) KeyboardType.Decimal else KeyboardType.Text))

private fun num(s: String) = s.replace(',', '.').toDoubleOrNull()

@Composable
private fun ProfileEditor(onDismiss: () -> Unit) {
    val s = Graph.store
    // Der Stand beim Öffnen: Gesichert wird nur, was hier geändert wurde – kam inzwischen etwas aus dem Rudel,
    // überschriebe das ganze Profil von damals es sonst.
    val base = remember { s.profile }
    val weightBase = remember { base.weightKg?.let(::kg) ?: "" }
    val targetBase = remember { base.targetWeightKg?.let(::kg) ?: "" }
    var pr by remember { mutableStateOf(base) }
    var weight by remember { mutableStateOf(weightBase) }
    var target by remember { mutableStateOf(targetBase) }
    Sheet(if (s.hasProfile) L.t("Profil") else L.t("Hund anlegen"), onDismiss) {
        Field(pr.name, L.t("Name")) { pr = pr.copy(name = it) }
        Field(pr.breed, L.t("Rasse")) { pr = pr.copy(breed = it) }
        Field(pr.birthdate, L.t("Geburtstag (JJJJ-MM-TT)")) { pr = pr.copy(birthdate = it) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("f" to L.t("Hündin"), "m" to L.t("Rüde"), "" to L.t("Keine Angabe")).forEach { (k, l) -> FilterChip(pr.sex == k, { pr = pr.copy(sex = k) }, { Text(l) }) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) { Field(weight, L.t("Gewicht (kg)"), true) { weight = it } }
            Box(Modifier.weight(1f)) { Field(target, L.t("Wunschgewicht"), true) { target = it } }
        }
        Row(verticalAlignment = Alignment.CenterVertically) { Text(L.t("Kastriert"), Modifier.weight(1f)); Switch(pr.neutered, { pr = pr.copy(neutered = it) }) }
        Field(pr.vetName, L.t("Tierarztpraxis")) { pr = pr.copy(vetName = it) }
        Field(pr.vetPhone, L.t("Telefon der Praxis")) { pr = pr.copy(vetPhone = it) }
        Field(pr.ownerName, L.t("Dein Name (Notfallpass)")) { pr = pr.copy(ownerName = it) }
        Field(pr.ownerPhone, L.t("Deine Nummer (Notfallpass)")) { pr = pr.copy(ownerPhone = it) }
        Field(pr.chip, L.t("Chip-Nummer")) { pr = pr.copy(chip = it) }
        Field(pr.allergies, L.t("Unverträglichkeiten, Vorerkrankungen")) { pr = pr.copy(allergies = it) }
        Row(verticalAlignment = Alignment.CenterVertically) { Text(L.t("Trägt einen Tracker"), Modifier.weight(1f)); Switch(pr.tracker, { pr = pr.copy(tracker = it) }) }
        Button({
            // Unberührte Zahlenfelder bleiben, wie sie sind (die Anzeige rundet).
            val draft = pr.copy(name = pr.name.trim(), targetWeightKg = if (target == targetBase) base.targetWeightKg else num(target),
                weightKg = if (weight == weightBase) base.weightKg else num(weight) ?: base.weightKg)
            s.save(s.profile.applying(draft, base))
            if (weight != weightBase) num(weight)?.let { if (it != s.weights.maxByOrNull { w -> w.d }?.kg) s.saveWeight(it) }
            onDismiss()
        }, Modifier.fillMaxWidth().height(50.dp), enabled = pr.name.isNotBlank()) { Text(L.t("Sichern")) }
    }
}

@Composable
private fun WeightEditor(onDismiss: () -> Unit) {
    var v by remember { mutableStateOf("") }
    Sheet(L.t("Gewicht"), onDismiss) {
        Field(v, L.t("Kilogramm"), true) { v = it }
        Button({ num(v)?.let { Graph.store.saveWeight(it) }; onDismiss() }, Modifier.fillMaxWidth().height(50.dp), enabled = num(v) != null) { Text(L.t("Eintragen")) }
    }
}

@Composable
private fun HealthEditor(edit: HealthEdit, onDismiss: () -> Unit) {
    val s = Graph.store
    when (edit) {
        is HealthEdit.Vac -> { var v by remember { mutableStateOf(edit.v) }
            Sheet(L.t("Impfung"), onDismiss) {
                Field(v.name, L.t("Impfung, z. B. Tollwut")) { v = v.copy(name = it) }; Field(v.date, L.t("Geimpft am (JJJJ-MM-TT)")) { v = v.copy(date = it) }
                Field(v.next, L.t("Nächste fällig (JJJJ-MM-TT)")) { v = v.copy(next = it) }; Field(v.notes, L.t("Notiz")) { v = v.copy(notes = it) }
                Actions(isNew = s.vaccinations.none { it.id == v.id }, onDelete = { s.remove(Kinds.vaccination, v.id); onDismiss() }) { s.save(v); onDismiss() }
            } }
        is HealthEdit.Worm -> { var d by remember { mutableStateOf(edit.d) }
            Sheet(L.t("Entwurmung"), onDismiss) {
                Field(d.product, L.t("Mittel, z. B. Milbemax")) { d = d.copy(product = it) }; Field(d.date, L.t("Gegeben am (JJJJ-MM-TT)")) { d = d.copy(date = it) }
                Field(d.next, L.t("Nächste fällig (JJJJ-MM-TT)")) { d = d.copy(next = it) }
                Actions(isNew = s.dewormings.none { it.id == d.id }, onDelete = { s.remove(Kinds.deworming, d.id); onDismiss() }) { s.save(d); onDismiss() }
            } }
        is HealthEdit.Med -> { var m by remember { mutableStateOf(edit.m) }
            Sheet(L.t("Medikament"), onDismiss) {
                Field(m.name, L.t("Medikament")) { m = m.copy(name = it) }; Field(m.dose, L.t("Dosis")) { m = m.copy(dose = it) }
                Field(m.from, L.t("Ab (JJJJ-MM-TT)")) { m = m.copy(from = it) }; Field(m.to, L.t("Bis (JJJJ-MM-TT)")) { m = m.copy(to = it) }
                Actions(isNew = s.meds.none { it.id == m.id }, onDelete = { s.remove(Kinds.medication, m.id); onDismiss() }) { s.save(m); onDismiss() }
            } }
    }
}

@Composable
private fun Actions(isNew: Boolean, onDelete: () -> Unit, onSave: () -> Unit) {
    val p = LocalPalette.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (!isNew) TextButton(onDelete) { Text(L.t("Löschen"), color = p.health) }
        Spacer(Modifier.weight(1f)); Button(onSave) { Text(L.t("Sichern")) }
    }
}

/** Der Text im Ring: „in 12“ über „Tagen“, „über-“ über „fällig“. */
private fun dueRingText(due: Day): String {
    val n = Day.today().daysUntil(due)
    return when {
        n < 0 -> L.t("über-\nfällig"); n == 0 -> L.t("heute"); n == 1 -> L.t("morgen")
        n < 45 -> L.t("in %1\$s\nTagen", n); n < 365 -> L.t("in %1\$s\nMon.", n / 30)
        else -> if (n / 365 == 1) L.t("in 1\nJahr") else L.t("in %1\$d\nJahren", n / 365)
    }
}
