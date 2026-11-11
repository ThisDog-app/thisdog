package app.thisdog.ui

import app.thisdog.i18n.L
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Account
import app.thisdog.data.Graph
import app.thisdog.gassi.*
import app.thisdog.model.Avatar
import app.thisdog.model.LatLng
import app.thisdog.model.Track
import app.thisdog.model.WalkText
import kotlinx.coroutines.launch
import java.util.Locale

/** Eincheckt: Datensatz im Rudel, Paket an die Hundefreunde; gibt die Meldung zurück (Besuch oder neues Abzeichen). */
fun checkIn(p: Place): Pair<String, String> {
    val store = Graph.store
    val before = Revier(store.checkIns).badges
    val c = CheckIn.of(p)
    store.upsert(app.thisdog.data.Kinds.checkIn, c)
    Graph.account.friends.checkedIn(c)
    val n = CheckIns.visits(p, store.checkIns).size
    val fresh = Revier(store.checkIns).badges.firstOrNull { it !in before }
    val dog = store.profile.name.ifEmpty { L.t("Dein Hund") }
    return (if (n == 1) L.t("Erster Besuch") else L.t("%1\$s. Besuch", n)) to (fresh?.let { L.t("Neues Abzeichen: %1\$s", it.title) } ?: L.t("%1\$s in %2\$s", dog, p.name))
}

/** Ein Ort: was es dort gibt, welche Hunde man trifft, einchecken, bewerten, melden (wie PlaceScreen.swift). */
@Composable
fun PlaceContent(initial: Place, showsMap: Boolean, onClose: () -> Unit, onChange: (Place) -> Unit, onPack: () -> Unit, onNotice: (Pair<String, String>) -> Unit, parent: String? = null) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var place by remember(initial.id) { mutableStateOf(initial) }
    var rating by remember { mutableStateOf(false) }
    var myRating by remember(initial.id) { mutableStateOf<PlaceService.Mine?>(null) }
    var reporting by remember { mutableStateOf(false) }
    var reported by remember { mutableStateOf(false) }
    var scout by remember { mutableStateOf(GassiDemo.erkunder) }
    var checking by remember { mutableStateOf(false) }
    val signedIn = Graph.account.signedIn
    val store = Graph.store
    val here = WalkRecorder.here
    val dog = store.profile.name.ifEmpty { L.t("Dein Hund") }

    // Den Standort frisch holen: Sonst ist er (vor allem vor der Runde) veraltet und Einchecken gilt als „zu weit weg“.
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(initial.id) { if (WalkRecorder.hasPermission(context)) WalkRecorder.locateOnce(context) }

    var reload by remember { mutableStateOf(0) }
    LaunchedEffect(place.serverID, reload) {
        if (GassiDemo.bewertet) myRating = PlaceService.Mine(mapOf("off_leash" to 1, "water" to 1, "grass" to 0), PlaceService.Sizes(small = true, medium = true))
        if (GassiDemo.orte) return@LaunchedEffect
        val id = place.serverID ?: return@LaunchedEffect
        runCatching { PlaceService.summary(Graph.account.api, id) }.getOrNull()?.let {
            place = place.copy(votes = it.votes, voters = it.voters, sizes = it.sizes, photos = it.photos, checkedAt = it.checkedAt ?: place.checkedAt, facts = place.facts + it.facts)
            scout = it.scout
            myRating = it.mine
        }
    }

    Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
        if (showsMap) {
            WalkMap(Modifier.fillMaxWidth().height(190.dp).clip(RoundedCornerShape(24.dp)), here = here, places = listOf(place),
                selected = place.id, focus = place.coordinate, focusZoom = 16.0)
            Spacer(Modifier.height(18.dp))
        }
        // Im Panel neben der Karte: „‹ Wohin heute? › Ort“ statt eines Schließen-Kreuzes.
        parent?.let { Breadcrumb(it, place.label, Modifier.padding(bottom = 6.dp), onClose) }
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(place.name, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 31.sp, color = p.ink)
                val meta = listOfNotNull(place.label, here?.let { L.t("%1\$s entfernt", WalkText.distance(Track.distance(it, place.coordinate))) },
                    place.area?.let { String.format(app.thisdog.i18n.L.locale, L.t("%,d m²"), it) })
                Text(meta.joinToString(", "), fontSize = 14.sp, color = p.ink2, modifier = Modifier.padding(top = 4.dp))
            }
            if (parent == null) RoundButton(Sym.CLOSE, L.t("Schließen"), 44.dp, p.ink2, onClose)
        }

        place.checkedAt?.let { Box(Modifier.padding(top = 14.dp)) { CheckedBadge(it) } }
        // Einchecken (vor Ort) und Bewerten
        val recent = CheckIns.recent(place, store.checkIns)
        val near = CheckIns.inReach(place, here)
        Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (recent != null) {
                Box(Modifier.weight(1f).height(50.dp).clip(RoundedCornerShape(50)).background(p.soft), contentAlignment = Alignment.Center) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        LineIcon(Sym.CHECK, p.accent, 20.dp)
                        Text(L.t("Eingecheckt um %d:%02d").format(recent.date.hour, recent.date.minute), color = p.accent, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    }
                }
            } else if (near) {
                Button({ onNotice(checkIn(place)) }, Modifier.weight(1f).height(50.dp), shape = RoundedCornerShape(50),
                    colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) {
                    Icon(Sym.PIN, Color.White, 18.sp); Spacer(Modifier.width(6.dp)); Text(L.t("Einchecken"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            // Bewerten steht hier nur, wenn es schon Stimmen gibt; sonst lädt die Einladung weiter unten dazu ein.
            if (place.enoughVotes && myRating?.isRated != true) {
            val prominent = recent == null && !near
            Button({ if (!signedIn) onPack() else rating = true }, Modifier.weight(1f).height(50.dp), shape = RoundedCornerShape(50),
                colors = ButtonDefaults.buttonColors(containerColor = if (prominent) p.accent else p.soft, contentColor = if (prominent) Color.White else p.accent)) {
                Icon(Sym.RATE, if (prominent) Color.White else p.accent, 18.sp); Spacer(Modifier.width(6.dp))
                Text(if (place.voters > 0) L.t("Bewerten") else L.t("Ort bewerten"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            }
        }

        // Noch nicht da: zu Fuß hinführen lassen (Karten-App des Telefons).
        if (recent == null && !near) {
            OutlinedButton({ guide(context, place) }, Modifier.padding(top = 10.dp).fillMaxWidth().height(50.dp), shape = RoundedCornerShape(50),
                border = androidx.compose.foundation.BorderStroke(1.dp, p.line), colors = ButtonDefaults.outlinedButtonColors(containerColor = p.surface, contentColor = p.ink)) {
                LineIcon(Sym.COMPASS, p.ink, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("Hinführen"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }

        if (scout && place.serverID != null) Row(Modifier.padding(top = 10.dp).clip(RoundedCornerShape(50)).clickable { checking = true }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Sym.SHIELD, p.accent, 18.sp); Text(L.t("Vor Ort prüfen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
        }
        // Besuche des eigenen Hundes und Freunde, die hier eingecheckt haben
        val mine = CheckIns.visits(place, store.checkIns)
        if (mine.isNotEmpty()) {
            Row(Modifier.padding(top = 16.dp).fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.surface).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                AvatarView(store.avatars.firstOrNull { it.id == Avatar.DOG }?.jpeg, dog, 40.dp, isDog = true)
                Column(Modifier.weight(1f)) {
                    Text(if (mine.size == 1) L.t("%1\$s war einmal hier", dog) else L.t("%1\$s war %2\$s-mal hier", dog, mine.size), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
                    Text(L.t("zuletzt %1\$s", CheckIns.whenText(mine[0])), fontSize = 14.sp, color = p.ink2)
                }
                if (mine.size >= 10) Icon(Sym.BADGE, p.accent, 22.sp)
            }
        }
        Graph.account.friends.visits(place).forEach { v ->
            val f = Graph.account.friends.list.firstOrNull { it.pack == v.pack }
            val minutes = ((System.currentTimeMillis() - v.time) / 60_000).coerceAtLeast(1)
            Row(Modifier.padding(top = 10.dp, start = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                AvatarView(f?.photoJpeg, f?.name ?: "", 28.dp, isDog = f?.photoJpeg == null)
                Text(L.t("%1\$s ist seit %2\$s hier", f?.name ?: L.t("Ein Freund"), if (minutes < 60) L.t("%1\$d Minuten", minutes) else L.t("%1\$d Stunden", minutes / 60)), fontSize = 14.sp, color = p.ink2)
            }
        }

        if (place.hasNoDogsArea) Row(Modifier.padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Sym.WARNING, p.health, 18.sp); Text(L.t("In Teilen des Parks gilt Hundeverbot (laut Stadt Wien)."), fontSize = 14.sp, color = p.health)
        }

        Text(L.t("Wie es hier ist"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink, modifier = Modifier.padding(top = 24.dp, bottom = 4.dp))
        if (place.enoughVotes) VotedFeatures(place) else KnownFeatures(place)
        val rated = myRating?.takeIf { it.isRated }
        if (rated != null) MyRating(place, rated) { rating = true }
        else if (!place.enoughVotes) Invite(place) { if (!signedIn) onPack() else rating = true }
        if (place.enoughVotes && place.sizes.sum() > 0) Sizes(place.sizes)

        Box(Modifier.padding(top = 24.dp)) { PhotosSection(place) { reload++ } }
        Text(place.sourceNote, fontSize = 12.sp, color = p.ink3, modifier = Modifier.padding(top = 22.dp))
        if (place.serverID != null) Text(if (reported) L.t("Danke, wir sehen es uns an.") else L.t("Stimmt etwas nicht?"), fontSize = 12.sp,
            color = if (reported) p.ink3 else p.accent, modifier = Modifier.padding(top = 6.dp).clickable(enabled = !reported && signedIn) { reporting = true })
    }

    if (checking) CheckSheet(place, onDismiss = { checking = false }) { onNotice(L.t("Vor Ort geprüft") to it) }
    if (rating) RateSheet(place, onDismiss = { rating = false }) { s ->
        place = place.copy(votes = s.votes, voters = s.voters, sizes = s.sizes); myRating = s.mine; onChange(place)
    }
    if (reporting) AlertDialog(onDismissRequest = { reporting = false }, containerColor = p.paper,
        title = { Text(L.t("Was stimmt nicht?")) },
        text = {
            Column {
                listOf("gibt_es_nicht" to L.t("Den Ort gibt es nicht"), "falscher_ort" to L.t("Er liegt woanders"), "hunde_verboten" to L.t("Hunde sind hier verboten"),
                    "falscher_name" to L.t("Der Name stimmt nicht"), "anderes" to L.t("Etwas anderes")).forEach { (key, title) ->
                    Text(title, fontSize = 16.sp, color = p.ink, modifier = Modifier.fillMaxWidth().clickable {
                        scope.launch { runCatching { PlaceService.report(Graph.account.api, place.serverID ?: "", key) }; reported = true }
                        reporting = false
                    }.padding(vertical = 12.dp))
                }
            }
        },
        confirmButton = { TextButton({ reporting = false }) { Text(L.t("Abbrechen"), color = p.ink) } })
}

private enum class ChipStyle { YES, UNSURE, NO, KNOWN }

@Composable
private fun FeatureGroup(title: String, content: @Composable () -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2, modifier = Modifier.width(96.dp).padding(top = 6.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
    }
    HorizontalDivider(color = p.line)
}

@Composable
private fun FeatureChip(title: String, sym: String, style: ChipStyle, count: String? = null) {
    val p = LocalPalette.current
    val green = Color(0xFF1F6F4A)
    val mod = when (style) {
        ChipStyle.YES -> Modifier.clip(RoundedCornerShape(50)).background(Color(0xFFE3F3EA))
        ChipStyle.UNSURE -> Modifier.clip(RoundedCornerShape(50)).background(p.surface).border(1.dp, p.line, RoundedCornerShape(50))
        ChipStyle.KNOWN -> Modifier.clip(RoundedCornerShape(50)).background(p.surface).dashedBorder(p.ink3)
        ChipStyle.NO -> Modifier
    }
    Row(mod.padding(horizontal = if (style == ChipStyle.NO) 4.dp else 11.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        LineIcon(if (style == ChipStyle.YES) Sym.CHECK else sym, if (style == ChipStyle.YES) green else if (style == ChipStyle.NO) p.ink3 else p.ink, 16.dp)
        Text(title, fontSize = 14.sp, fontWeight = if (style == ChipStyle.YES) FontWeight.SemiBold else FontWeight.Normal,
            color = if (style == ChipStyle.YES) green else if (style == ChipStyle.NO) p.ink3 else p.ink,
            textDecoration = if (style == ChipStyle.NO) TextDecoration.LineThrough else null)
        count?.let { Text(it, fontSize = 12.sp, color = p.ink3) }
    }
}

private fun Modifier.dashedBorder(color: Color) = this.drawWithContent {
    drawContent()
    drawRoundRect(color, cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2),
        style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f))))
}

/** Genug Bewertungen: gibt es, uneinig (mit Zählung), gibt es nicht. */
@Composable
private fun VotedFeatures(place: Place) {
    val p = LocalPalette.current
    val all = place.features.mapNotNull { f -> place.verdict(f)?.let { f to it } }
    FeatureGroup(L.t("Gibt es")) {
        all.filter { it.second is PlaceVerdict.Yes }.forEach { FeatureChip(it.first.short, it.first.sym, ChipStyle.YES) }
        place.extras.forEach { FeatureChip(it.second, it.first, ChipStyle.YES) }
    }
    val unsure = all.filter { it.second is PlaceVerdict.Unsure }
    if (unsure.isNotEmpty()) FeatureGroup(L.t("Uneinig")) {
        unsure.forEach { (f, v) -> v as PlaceVerdict.Unsure; FeatureChip(f.short, f.sym, ChipStyle.UNSURE, L.t("%1\$s von %2\$s", v.yes, v.of)) }
    }
    val no = all.filter { it.second is PlaceVerdict.No }
    if (no.isNotEmpty()) FeatureGroup(L.t("Gibt es nicht")) { no.forEach { FeatureChip(it.first.short, it.first.sym, ChipStyle.NO) } }
    Text(if (place.voters == 1) L.t("1 Mensch hat bewertet") else L.t("%1\$s Menschen haben bewertet", place.voters), fontSize = 12.sp, color = p.ink3, modifier = Modifier.padding(top = 8.dp))
}

/** Zu wenig Bewertungen: was die Daten sagen, gestrichelt, mit Quelle. */
@Composable
private fun KnownFeatures(place: Place) {
    val known = place.features.mapNotNull { f -> place.verdict(f)?.let { f to it } }
    val yes = known.filter { it.second is PlaceVerdict.Yes }
    val partly = known.filter { it.second is PlaceVerdict.Partly }
    val no = known.filter { it.second is PlaceVerdict.No }
    val label = if (place.facts.values.any { it.src == "wien" }) L.t("Laut Stadt Wien und Karte") else sourceLabel(place.facts.values.firstOrNull()?.src)
    if (yes.isNotEmpty() || partly.isNotEmpty() || place.extras.isNotEmpty()) FeatureGroup(label) {
        yes.forEach { FeatureChip(it.first.short, it.first.sym, ChipStyle.KNOWN) }
        partly.forEach { FeatureChip(L.t("teilweise %1\$s", it.first.short.lowercase()), it.first.sym, ChipStyle.KNOWN) }
        place.extras.forEach { FeatureChip(it.second, it.first, ChipStyle.KNOWN) }
    }
    if (no.isNotEmpty()) FeatureGroup(L.t("Gibt es nicht")) { no.forEach { FeatureChip(it.first.short, it.first.sym, ChipStyle.NO) } }
}

@Composable
private fun MyRating(place: Place, m: PlaceService.Mine, onChange: () -> Unit) {
    val p = LocalPalette.current
    val answered = place.features.mapNotNull { f -> m.votes[f.key]?.let { f to it } }
    val dogs = listOfNotNull(
        L.t("Kleine").takeIf { m.sizes?.small == true },
        L.t("Mittlere").takeIf { m.sizes?.medium == true },
        L.t("Große").takeIf { m.sizes?.large == true },
    )
    Column(Modifier.padding(top = 18.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Text(L.t("Deine Bewertung"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 19.sp, color = p.ink)
            Text(L.t("Ändern"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onChange).padding(horizontal = 8.dp, vertical = 8.dp))
        }
        if (answered.isNotEmpty()) FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            answered.forEach { (f, v) -> FeatureChip(f.short, f.sym, if (v == 1) ChipStyle.YES else ChipStyle.NO) }
        }
        if (dogs.isNotEmpty()) Text(L.t("Hunde hier: %1\$s", dogs.joinToString(", ")), fontSize = 14.sp, color = p.ink2)
        if (!place.enoughVotes) Text(L.t("Für alle sichtbar, sobald mehr Menschen bewertet haben."), fontSize = 12.sp, color = p.ink3)
    }
}

@Composable
private fun Invite(place: Place, onRate: () -> Unit) {
    val p = LocalPalette.current
    Column(Modifier.padding(top = 14.dp).fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(p.soft).padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Sym.PAW, p.accent, 24.sp)
        Text(L.t("Noch kaum bewertet"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 19.sp, color = p.ink)
        Text(L.t("Warst du schon mit deinem Hund hier? In einer halben Minute sagst du, ob man frei laufen kann und ob es Wasser und Schatten gibt. Alle, die mit Hund herkommen, sehen es dann."),
            fontSize = 14.sp, color = p.ink2)
        Button(onRate, Modifier.fillMaxWidth().height(48.dp).padding(top = 4.dp), shape = RoundedCornerShape(50),
            colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) { Text(L.t("Ort bewerten"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
        Text(when (place.voters) { 0 -> L.t("Noch niemand hat bewertet"); 1 -> L.t("1 Mensch hat bisher bewertet"); else -> L.t("%1\$s Menschen haben bisher bewertet", place.voters) },
            fontSize = 12.sp, color = p.ink2, modifier = Modifier.fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
private fun Sizes(s: List<Int>) {
    val p = LocalPalette.current
    val total = s.sum().coerceAtLeast(1)
    Column(Modifier.padding(top = 18.dp).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(L.t("Hunde hier meist"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
        Row(Modifier.fillMaxWidth().height(10.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            s.forEachIndexed { i, n -> if (n > 0) Box(Modifier.weight(n.toFloat() / total).fillMaxHeight().clip(RoundedCornerShape(50)).background(p.accent.copy(alpha = listOf(1f, .55f, .25f)[i]))) }
        }
        Row(Modifier.fillMaxWidth()) {
            listOf(L.t("Kleine"), L.t("Mittlere"), L.t("Große")).forEachIndexed { i, t ->
                Text(t, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink); Text(" ${s[i]}", fontSize = 13.sp, color = p.ink2)
                if (i < 2) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** Bewerten: je Merkmal Ja, Nein oder Weiß nicht, dazu welche Hunde man dort meist trifft. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RateSheet(place: Place, onDismiss: () -> Unit, onSaved: (PlaceService.Summary) -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val answers = remember { mutableStateMapOf<PlaceFeature, Int>() }
    var sizes by remember { mutableStateOf(PlaceService.Sizes()) }
    var failed by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val id = place.serverID ?: return@LaunchedEffect
        runCatching { PlaceService.summary(Graph.account.api, id) }.getOrNull()?.mine?.let { m ->
            m.votes.forEach { (k, v) -> place.features.firstOrNull { it.key == k }?.let { answers[it] = v } }
            m.sizes?.let { sizes = it }
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onDismiss) { Text(L.t("Abbrechen"), color = p.ink2) }
                Text(place.name, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 1, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton({
                    val id = place.serverID ?: return@TextButton onDismiss()
                    saving = true; failed = false
                    scope.launch {
                        val votes = place.features.associate { it.key to answers[it] }
                        runCatching { PlaceService.vote(Graph.account.api, id, votes, sizes) }
                            .onSuccess { onSaved(it); onDismiss() }.onFailure { failed = true }
                        saving = false
                    }
                }, enabled = !saving) { Text(L.t("Sichern"), color = p.accent, fontWeight = FontWeight.SemiBold) }
            }
            Text(L.t("Was stimmt hier? Du kannst es später ändern."), fontSize = 14.sp, color = p.ink2, modifier = Modifier.padding(top = 10.dp, bottom = 6.dp))
            place.features.forEach { f ->
                Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(f.sym, p.ink2, 18.sp); Spacer(Modifier.width(10.dp))
                    Text(f.title, fontSize = 15.sp, color = p.ink, modifier = Modifier.weight(1f))
                    SingleChoiceSegmentedButtonRow {
                        listOf(1 to L.t("Ja"), 0 to L.t("Nein"), -1 to "?").forEachIndexed { i, (v, t) ->
                            SegmentedButton(selected = (answers[f] ?: -1) == v, onClick = { if (v < 0) answers.remove(f) else answers[f] = v },
                                shape = SegmentedButtonDefaults.itemShape(i, 3), icon = {},
                                colors = SegmentedButtonDefaults.colors(activeContainerColor = p.soft, activeContentColor = p.accent)) { Text(t, fontSize = 13.sp) }
                        }
                    }
                }
                HorizontalDivider(color = p.line)
            }
            Text(L.t("Welche Hunde triffst du hier meist?"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.padding(top = 18.dp, bottom = 8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Pill(L.t("Kleine"), sizes.small) { sizes = sizes.copy(small = !sizes.small) }
                Pill(L.t("Mittlere"), sizes.medium) { sizes = sizes.copy(medium = !sizes.medium) }
                Pill(L.t("Große"), sizes.large) { sizes = sizes.copy(large = !sizes.large) }
            }
            if (failed) Text(L.t("Nicht gesichert. Prüfe die Verbindung und versuche es noch einmal."), fontSize = 14.sp, color = p.health, modifier = Modifier.padding(top = 12.dp))
        }
    }
}

@Composable
private fun Pill(title: String, on: Boolean, sym: String? = null, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.clip(RoundedCornerShape(50)).background(if (on) p.soft else p.surface).border(1.dp, if (on) Color.Transparent else p.line, RoundedCornerShape(50))
        .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        sym?.let { LineIcon(it, if (on) p.accent else p.ink2, 18.dp) }
        Text(title, fontSize = 15.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) p.accent else p.ink2)
    }
}

/** Einen Ort eintragen: Karte verschieben, bis der Punkt stimmt, dann Name, Art und was es dort gibt. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddPlaceSheet(start: LatLng, onDismiss: () -> Unit, onAdded: (Place) -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var center by remember { mutableStateOf(start) }
    var name by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf("dog_park") }
    val features = remember { mutableStateListOf<PlaceFeature>() }
    var message by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onDismiss) { Text(L.t("Abbrechen"), color = p.ink2) }
                Text(L.t("Ort eintragen"), fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton({
                    saving = true; message = null
                    scope.launch {
                        runCatching { PlaceService.add(Graph.account.api, name.trim(), kind, center, features.filter { it in PlaceFeature.forPlace(kind == "dog_park") }.associate { it.key to 1 }) }
                            .onSuccess { onAdded(it); onDismiss() }
                            .onFailure { e ->
                                message = when ((e as? app.thisdog.data.Api.Failure.Server)?.code) {
                                    "rate_limited" -> L.t("Für heute hast du schon fünf Orte eingetragen. Morgen geht es weiter.")
                                    else -> if (e is app.thisdog.data.Api.Failure.NotSignedIn) L.t("Melde dich im Rudel an, dann kannst du Orte eintragen.") else L.t("Nicht eingetragen. Prüfe die Verbindung und versuche es noch einmal.")
                                }
                            }
                        saving = false
                    }
                }, enabled = !saving && name.isNotBlank()) { Text(L.t("Eintragen"), color = if (!saving && name.isNotBlank()) p.accent else p.ink3, fontWeight = FontWeight.SemiBold) }
            }
            Box(Modifier.padding(top = 8.dp).fillMaxWidth().height(260.dp).clip(RoundedCornerShape(24.dp))) {
                WalkMap(Modifier.fillMaxSize(), focus = start, focusZoom = 16.5, onCenter = { center = it })
                Box(Modifier.align(Alignment.Center).padding(bottom = 30.dp)) { Icon(Sym.PLACE, p.accent, 36.sp) }
            }
            Text(L.t("Karte verschieben, bis der Punkt stimmt."), fontSize = 13.sp, color = p.ink2, modifier = Modifier.padding(top = 8.dp))
            Text(L.t("Name"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2, modifier = Modifier.padding(top = 18.dp, bottom = 6.dp))
            OutlinedTextField(name, { if (it.length <= 60) name = it }, Modifier.fillMaxWidth(), placeholder = { Text(L.t("z. B. Wiese am Schützenhaus")) }, singleLine = true, shape = RoundedCornerShape(14.dp))
            Text(L.t("Was ist das?"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2, modifier = Modifier.padding(top = 18.dp, bottom = 8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("dog_park" to L.t("Hundezone"), "park" to L.t("Park"), "meadow" to L.t("Wiese"), "forest" to L.t("Wald")).forEach { (k, t) -> Pill(t, kind == k) { kind = k } }
            }
            Text(L.t("Was es dort gibt"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2, modifier = Modifier.padding(top = 18.dp, bottom = 8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PlaceFeature.forPlace(kind == "dog_park").forEach { f -> Pill(f.short, f in features, f.sym) { if (f in features) features.remove(f) else features.add(f) } }
            }
            message?.let { Text(it, fontSize = 14.sp, color = p.health, modifier = Modifier.padding(top = 12.dp)) }
            Text(L.t("Andere sehen den Ort sofort. Dein Name steht nicht dabei."), fontSize = 12.sp, color = p.ink3, modifier = Modifier.padding(top = 16.dp))
        }
    }
}

/**
 * Das Revier im Panel über der Karte: Zahlen, Abzeichen und die letzten Check-ins als Leine (wie RevierPanel in RevierScreen.swift).
 * Die Orte selbst liegen auf der großen Karte.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun RevierPanel() {
    val p = LocalPalette.current
    val store = Graph.store
    val r = Revier(store.checkIns)
    Column {
        Text(CheckIns.revierTitle(store.profile.name), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 28.sp, color = p.ink)
        Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Bottom) {
            Stat(r.spots.size, if (r.spots.size == 1) L.t("Ort") else L.t("Orte")); Stat(r.total, if (r.total == 1) L.t("Besuch") else L.t("Besuche"))
        }
        if (r.badges.isNotEmpty() || r.next != null) Row(Modifier.padding(top = 16.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            r.badges.forEach { Badge(it, true) }; r.next?.let { Badge(it, false) }
        }
        Text(L.t("Zuletzt"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink, modifier = Modifier.padding(top = 26.dp, bottom = 10.dp))
        if (r.recent.isEmpty()) Text(L.t("Noch leer. Wer beim Gassi an einem Ort eincheckt, sammelt ihn hier."), fontSize = 15.sp, color = p.ink2)
        val list = r.recent.take(12)
        list.forEachIndexed { i, c ->
            var menu by remember { mutableStateOf(false) }
            Box {
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).combinedClickable(onClick = {}, onLongClick = { menu = true })) {
                    Column(Modifier.width(14.dp).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.padding(top = 4.dp).size(12.dp).clip(CircleShape).background(if (i == 0) p.accent else p.paper).border(2.dp, p.accent, CircleShape))
                        if (i < list.size - 1) Box(Modifier.width(1.4.dp).weight(1f).background(p.line))
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.padding(bottom = 14.dp)) {
                        Text(CheckIns.whenText(c).replaceFirstChar { it.uppercase() }, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                        Text(c.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
                        Graph.account.name(store.changer(app.thisdog.gassi.CheckIn.KIND, c.id))?.let { Text(L.t("mit %1\$s", it), fontSize = 14.sp, color = p.ink2) }
                    }
                }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text(L.t("Check-in löschen"), color = p.health) }, { menu = false; store.remove(app.thisdog.data.Kinds.checkIn, c.id) }, leadingIcon = { LineIcon(Sym.DELETE, p.health, 20.dp) })
                }
            }
        }
    }
}

@Composable
private fun Stat(n: Int, label: String) {
    val p = LocalPalette.current
    Row(verticalAlignment = Alignment.Bottom) {
        Text("$n ", fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 22.sp, color = p.accent)
        Text(label, fontSize = 16.sp, color = p.ink2, modifier = Modifier.padding(bottom = 2.dp))
    }
}

@Composable
private fun Badge(b: Revier.Badge, earned: Boolean) {
    val p = LocalPalette.current
    Column(Modifier.width(154.dp).clip(RoundedCornerShape(18.dp)).background(if (earned) p.surface else p.paper)
        .then(if (earned) Modifier else Modifier.border(BorderStroke(1.dp, p.line), RoundedCornerShape(18.dp))).padding(12.dp)
        .semantics(mergeDescendants = true) { contentDescription = (if (earned) L.t("Abzeichen ") else L.t("Nächstes Abzeichen ")) + "${b.title}, ${b.detail}" },
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        LineIcon(b.sym, if (earned) p.accent else p.ink3, 30.dp)
        Text(b.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = if (earned) p.ink else p.ink2)
        Text(b.detail, fontSize = 12.sp, color = p.ink2, maxLines = 2)
    }
}

/** Öffnet den Fußweg in Google Maps; ohne Google Maps irgendeine Karten-App mit dem Ort. */
private fun guide(context: android.content.Context, place: Place) {
    val nav = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("google.navigation:q=${place.lat},${place.lon}&mode=w"))
    val geo = android.content.Intent(android.content.Intent.ACTION_VIEW,
        android.net.Uri.parse("geo:${place.lat},${place.lon}?q=${place.lat},${place.lon}(${android.net.Uri.encode(place.name)})"))
    runCatching { context.startActivity(nav) }.recoverCatching { context.startActivity(geo) }
}
