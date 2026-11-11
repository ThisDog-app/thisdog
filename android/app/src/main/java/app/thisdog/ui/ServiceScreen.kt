package app.thisdog.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.gassi.*
import app.thisdog.i18n.L
import app.thisdog.model.LatLng
import app.thisdog.model.Track
import app.thisdog.model.WalkText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Der Reiter „Adressen“ auf Gassi (wie ServiceViews.swift): Tierärzte, Hundefriseure, Tierbedarf … aus OpenStreetMap.
 * Bleibt über Reiterwechsel und Drehen erhalten, wie [GassiUi]; Liste und Karte lesen beide von hier.
 */
class ServiceUi {
    var near by mutableStateOf<List<Service>>(emptyList())
    /** Treffer der Namenssuche beim Server (ab drei Zeichen), zusätzlich zu den Adressen in der Nähe. */
    var found by mutableStateOf<List<Service>>(emptyList())
    var sponsor by mutableStateOf<Service?>(null)
    var covered by mutableStateOf(true)
    var loaded by mutableStateOf(false)
    var loading by mutableStateOf(false)
    var failed by mutableStateOf(false)
    var retry by mutableStateOf(0)
    /** Wo zuletzt geladen wurde; ab 250 m weiter wird neu geladen. */
    var center: LatLng? = null
    /** Der gewählte Chip; null ist „Alle“. */
    var kind by mutableStateOf<String?>(null)
    var query by mutableStateOf("")
    var shown by mutableStateOf(ServiceFinder.PAGE)
    var selected by mutableStateOf<Service?>(null)

    fun all(here: LatLng?) = ServiceFilter.merge(near, found, sponsor, here)
    fun chips(here: LatLng?) = ServiceFilter.chips(all(here), sponsor)
    /** Verschwindet die Art des gewählten Chips (neu geladen), gilt wieder „Alle“. */
    fun kindShown(here: LatLng?) = kind?.takeIf { k -> chips(here).any { it.key == k } }
    fun list(here: LatLng?) = ServiceFilter.list(all(here), kindShown(here), query)
    fun shownSponsor(here: LatLng?) = ServiceFilter.sponsor(sponsor, kindShown(here), query)

    /** Für die Karte: der gesponserte Eintrag und die 40 nächsten gefilterten Adressen, dazu die gewählte. */
    fun onMap(here: LatLng?): List<Service> {
        val spots = listOfNotNull(shownSponsor(here)) + list(here).take(ServiceFinder.ON_MAP)
        return selected?.takeIf { s -> spots.none { it.id == s.id } }?.let { spots + it } ?: spots
    }
}

val serviceUi = ServiceUi()

/** Lädt die Adressen beim ersten Öffnen des Reiters und nach 250 m Bewegung neu (wie die Ziele bei Wohin). */
@Composable
private fun LoadServices(s: ServiceUi, here: LatLng?) {
    val center = s.center.takeIf { c -> here == null || c != null && Track.distance(c, here) < ServiceFinder.REFRESH_METERS } ?: here
    LaunchedEffect(center, s.retry) {
        if (here == null || center == null) return@LaunchedEffect
        if (center == s.center && s.loaded && !s.failed) return@LaunchedEffect
        s.center = center
        s.loading = true; s.failed = false
        val got = if (GassiDemo.adressen) app.thisdog.Beispiel.services(here) else runCatching { ServiceFinder.near(Graph.account.api, here) }.getOrNull()
        if (got != null) { s.near = got.list; s.sponsor = got.sponsor; s.covered = got.covered; s.loaded = true } else s.failed = true
        s.loading = false
    }
    // Ab drei Zeichen fragt die Suche auch den Server (weiterer Umkreis), entprellt.
    LaunchedEffect(s.query, here != null) {
        val q = s.query.trim()
        if (q.length < ServiceFinder.SEARCH_MIN || here == null) { s.found = emptyList(); return@LaunchedEffect }
        delay(ServiceFinder.DEBOUNCE_MS)
        if (GassiDemo.adressen) return@LaunchedEffect
        runCatching { ServiceFinder.near(Graph.account.api, here, q).list }.getOrNull()?.let { s.found = it }
    }
}

/** Der Inhalt des Reiters: Suche, Chips, der gesponserte Eintrag, die Liste nach Entfernung. */
@Composable
fun ServicesPanel(onLocate: () -> Unit) {
    val s = serviceUi
    val p = LocalPalette.current
    val here = WalkRecorder.here
    LoadServices(s, here)
    var explains by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (here == null) {
            OutlinedButton(onLocate, shape = RoundedCornerShape(50), border = androidx.compose.foundation.BorderStroke(1.dp, p.line)) {
                LineIcon(Sym.MY_LOCATION, p.accent, 20.dp); Spacer(Modifier.width(8.dp)); Text(L.t("Standort freigeben"), color = p.accent, fontWeight = FontWeight.SemiBold)
            }
            return@Column
        }
        SearchField(s.query, { s.query = it; s.shown = ServiceFinder.PAGE })
        val chips = s.chips(here)
        val kind = s.kindShown(here)
        if (chips.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip(L.t("Alle"), kind == null) { s.kind = null; s.shown = ServiceFinder.PAGE }
            chips.forEach { k -> Chip(k.chip, kind == k.key) { s.kind = k.key; s.shown = ServiceFinder.PAGE } }
        }
        val list = s.list(here)
        val sponsor = s.shownSponsor(here)
        when {
            s.failed && !s.loaded -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(L.t("Adressen konnten nicht geladen werden."), fontSize = 15.sp, color = p.ink2)
                OutlinedButton({ s.retry++ }, shape = RoundedCornerShape(50), border = androidx.compose.foundation.BorderStroke(1.dp, p.line)) {
                    Text(L.t("Nochmal"), color = p.accent, fontWeight = FontWeight.SemiBold)
                }
            }
            !s.loaded -> Text(L.t("Adressen werden gesucht …"), fontSize = 15.sp, color = p.ink3, modifier = Modifier.padding(vertical = 12.dp))
            list.isEmpty() && sponsor == null -> Text(
                if (!s.covered || s.query.isBlank() && s.all(here).isEmpty() && s.sponsor == null) L.t("Hier sind noch keine Adressen verzeichnet.") else L.t("Nichts gefunden."),
                fontSize = 15.sp, color = p.ink3, modifier = Modifier.padding(vertical = 12.dp))
            else -> Column {
                sponsor?.let { ad ->
                    Column(Modifier.padding(bottom = 6.dp).fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.surface).clickable { s.selected = ad }
                        .padding(start = 12.dp, end = 12.dp, top = 2.dp, bottom = 12.dp)) {
                        ServiceRow(ad, here, showsAd = true)
                        ad.ad?.text?.takeIf { it.isNotBlank() }?.let { Text(it, fontSize = 14.sp, color = p.ink, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 50.dp)) }
                    }
                }
                val shown = list.take(s.shown)
                shown.forEachIndexed { i, sv ->
                    Box(Modifier.clickable { s.selected = sv }) { ServiceRow(sv, here) }
                    if (i < shown.size - 1) HorizontalDivider(Modifier.padding(start = 50.dp), color = p.line)
                }
                if (list.size > s.shown) TextButton({ s.shown += ServiceFinder.PAGE }, Modifier.padding(top = 4.dp)) {
                    Text(L.t("Mehr zeigen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
                }
            }
        }
        if (s.failed && s.loaded) Text(L.t("Adressen konnten nicht geladen werden."), fontSize = 13.sp, color = p.ink3)
        Footer { explains = true }
    }
    if (explains) AlertDialog(onDismissRequest = { explains = false }, containerColor = p.paper,
        title = { Text(L.t("Warum steht oben eine Anzeige?")) },
        text = { Text(L.t("Betriebe können je Gegend einen Platz oben in den Adressen kaufen. Er ist immer als Anzeige gekennzeichnet. Die übrige Liste ist nach Entfernung sortiert und nicht käuflich, Bewertungen und Daten bleiben unberührt.")) },
        confirmButton = { TextButton({ explains = false }) { Text(L.t("Verstanden"), color = p.accent) } })
}

/** Klein ganz unten: woher die Daten sind und warum oben eine Anzeige stehen kann. Kein Wort über den Kauf. */
@Composable
private fun Footer(onExplain: () -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current
    Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        // Ein Satz zum Übersetzen; der Link darin ist hervorgehoben.
        val link = "openstreetmap.org"
        val line = L.t("Daten: OpenStreetMap. Fehlt etwas? Auf %1\$s eintragen.", link)
        val at = line.indexOf(link)
        Text(buildAnnotatedString {
            append(line)
            if (at >= 0) addStyle(SpanStyle(color = p.accent, fontWeight = FontWeight.SemiBold), at, at + link.length)
        }, fontSize = 12.sp, color = p.ink3, modifier = Modifier.clickable { open(context, Intent(Intent.ACTION_VIEW, Uri.parse("https://www.openstreetmap.org"))) })
        Text(L.t("Warum steht oben eine Anzeige?"), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = p.accent, modifier = Modifier.clickable(onClick = onExplain))
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.surface).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        LineIcon(Sym.SEARCH, p.ink3, 20.dp)
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text(L.t("Name oder Art suchen"), fontSize = 17.sp, color = p.ink3, maxLines = 1)
            BasicTextField(query, onChange, textStyle = TextStyle(fontSize = 17.sp, color = p.ink), cursorBrush = SolidColor(p.accent), singleLine = true, modifier = Modifier.fillMaxWidth())
        }
        if (query.isNotEmpty()) LineIcon(Sym.CLEAR, p.ink3, 20.dp, Modifier.clickable { onChange("") }.semantics { contentDescription = L.t("Leeren") })
    }
}

/** Gut lesbar „Anzeige“: halbfett, mit feiner Kontur – kein Kleinstdruck. */
@Composable
fun AdTag(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Text(L.t("Anzeige"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2, maxLines = 1,
        modifier = modifier.border(1.dp, p.line, RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 2.dp))
}

/** Kleines Etikett für Tierärzte mit Notdienst. */
@Composable
private fun EmergencyTag() {
    val p = LocalPalette.current
    Text(L.t("Notdienst"), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = p.health, maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(p.health.copy(alpha = .12f)).padding(horizontal = 7.dp, vertical = 1.dp))
}

/** Eine Zeile wie bei „Wohin“: Icon im Kreis, Name, darunter Art und Straße, rechts die Entfernung. */
@Composable
private fun ServiceRow(sv: Service, here: LatLng, modifier: Modifier = Modifier, showsAd: Boolean = false) {
    val p = LocalPalette.current
    Row(modifier.fillMaxWidth().padding(vertical = 10.dp).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(38.dp).clip(CircleShape).background(p.soft), contentAlignment = Alignment.Center) { LineIcon(sv.icon, p.accent, 22.dp) }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(sv.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (sv.emergency) EmergencyTag()
            }
            Text(sv.subtitle, fontSize = 14.sp, color = p.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        // Beim gesponserten Eintrag steht „Anzeige“ oben rechts, über der Entfernung.
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (showsAd) AdTag()
            Text(WalkText.distance(Track.distance(here, sv.coordinate)), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = p.ink)
        }
    }
}

/** Die Detailansicht im Panel, mit Zurück zu „Adressen“. Beim gesponserten Eintrag zählt ein Antippen je Öffnen. */
@Composable
fun ServiceContent(sv: Service, onClose: () -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var tapped by remember(sv.id) { mutableStateOf(false) }
    fun tap() {
        val ad = sv.ad ?: return
        if (tapped || GassiDemo.adressen) return
        tapped = true
        scope.launch { ServiceFinder.tap(Graph.account.api, ad.id) }
    }
    LaunchedEffect(sv.id) { tap() }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 32.dp)) {
        Breadcrumb(L.t("Adressen"), sv.label, Modifier.padding(bottom = 6.dp), onClose)
        Text(sv.name, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 31.sp, color = p.ink)
        Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(sv.label, fontSize = 14.sp, color = p.ink2)
            if (sv.ad != null) AdTag()
        }
        sv.ad?.let { ad ->
            ad.text?.takeIf { it.isNotBlank() }?.let { Text(it, fontSize = 16.sp, color = p.ink, modifier = Modifier.padding(top = 12.dp)) }
            Text(L.t("Bezahlte Platzierung von %1\$s.", ad.advertiser?.takeIf { it.isNotBlank() } ?: sv.name), fontSize = 13.sp, color = p.ink2, modifier = Modifier.padding(top = 6.dp))
        }
        if (sv.emergency) Box(Modifier.padding(top = 12.dp)) { EmergencyTag() }

        // Anrufen, Website, Route – was es gibt.
        Row(Modifier.padding(top = 18.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            sv.phone?.takeIf { it.isNotBlank() }?.let { phone ->
                ActionButton(L.t("Anrufen"), Modifier.weight(1f)) { tap(); open(context, Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", phone, null))) }
            }
            sv.websiteURL?.let { url ->
                ActionButton(L.t("Website"), Modifier.weight(1f)) { tap(); open(context, Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            }
            ActionButton(L.t("Route"), Modifier.weight(1f)) {
                open(context, Intent(Intent.ACTION_VIEW, Uri.parse("geo:${sv.lat},${sv.lon}?q=${sv.lat},${sv.lon}(${Uri.encode(sv.name)})")))
            }
        }

        val address = listOfNotNull(sv.street, sv.city).filter { it.isNotBlank() }
        if (address.isNotEmpty()) Section(L.t("Adresse"), address.joinToString("\n"))
        sv.hoursText?.takeIf { it.isNotBlank() }?.let { Section(L.t("Öffnungszeiten"), it) }
        Text(L.t("Aus OpenStreetMap"), fontSize = 12.sp, color = p.ink3, modifier = Modifier.padding(top = 22.dp))
    }
}

@Composable
private fun Section(title: String, body: String) {
    val p = LocalPalette.current
    Column(Modifier.padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
        Text(body, fontSize = 16.sp, color = p.ink)
    }
}

@Composable
private fun ActionButton(title: String, modifier: Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    OutlinedButton(onClick, modifier.height(48.dp), shape = RoundedCornerShape(50), contentPadding = PaddingValues(horizontal = 8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, p.line), colors = ButtonDefaults.outlinedButtonColors(containerColor = p.surface, contentColor = p.accent)) {
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Öffnet Telefon, Browser oder Karten-App; gibt es keine passende App, passiert nichts. */
private fun open(context: android.content.Context, intent: Intent) {
    runCatching { context.startActivity(intent) }
}
