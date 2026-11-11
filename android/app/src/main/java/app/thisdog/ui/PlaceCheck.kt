package app.thisdog.ui

import app.thisdog.i18n.L
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import app.thisdog.data.Api
import app.thisdog.data.Graph
import app.thisdog.gassi.*
import app.thisdog.model.LatLng
import app.thisdog.model.Track
import app.thisdog.model.WalkText
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Ein Bild aus dem Netz, im Speicher gehalten. */
private val imageCache = mutableMapOf<String, ImageBitmap>()

@Composable
fun RemoteImage(url: String, modifier: Modifier, scale: ContentScale = ContentScale.Crop) {
    val p = LocalPalette.current
    val img by produceState(imageCache[url], url) {
        if (value == null) value = Graph.account.api.bytes(url)?.let { b -> BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() }?.also { imageCache[url] = it }
    }
    Box(modifier.background(p.surface)) { img?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = scale) } }
}

/** Fotos eines Ortes nebeneinander; Antippen zeigt sie groß. */
@Composable
fun PlacePhotos(all: List<Place.Photo>) {
    var shown by remember { mutableStateOf<Place.Photo?>(null) }
    val reported = remember { mutableStateListOf<Int>() }
    val photos = all.filter { it.id !in reported }
    val scope = rememberCoroutineScope()
    var reasons by remember { mutableStateOf(false) }
    if (photos.isEmpty()) return
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        photos.forEach { ph ->
            RemoteImage(ph.thumb, Modifier.size(120.dp, 90.dp).clip(RoundedCornerShape(14.dp)).clickable { shown = ph }.semantics { contentDescription = L.t("Foto") })
        }
    }
    shown?.let { ph ->
        Dialog({ shown = null }, DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().background(Color.Black).clickable { shown = null }) {
                RemoteImage(ph.url, Modifier.fillMaxSize(), ContentScale.Fit)
                Box(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(20.dp)) {
                    Text(L.t("Melden"), color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = .18f)).clickable { reasons = true }.padding(horizontal = 14.dp, vertical = 9.dp))
                    DropdownMenu(reasons, { reasons = false }) {
                        listOf("person" to L.t("Person erkennbar"), "unpassend" to L.t("Unpassend"), "falscher_ort" to L.t("Gehört nicht zu diesem Ort"), "anderes" to L.t("Etwas anderes")).forEach { (k, t) ->
                            DropdownMenuItem({ Text(t) }, {
                                reasons = false; reported += ph.id; shown = null
                                scope.launch { runCatching { PlaceService.reportPhoto(Graph.account.api, ph.id, k) } }
                            })
                        }
                    }
                }
            }
        }
    }
}

/** Kamera und Mediathek für ein Foto; liefert JPEG-Bytes (höchstens 2000 px, auch aus HEIC). */
class PhotoSource(private val context: Context) {
    var pending: Uri? = null
    fun cameraUri(): Uri {
        val dir = File(context.cacheDir, "fotos").apply { mkdirs() }
        val f = File(dir, "aufnahme-${System.currentTimeMillis()}.jpg")
        return FileProvider.getUriForFile(context, "app.thisdog.fotos", f).also { pending = it }
    }
    fun read(uri: Uri): ByteArray? = Pictures.jpeg(context, uri)
}

/** Lässt sich ein Foto nicht lesen, kommt [onFail] – nie stilles Nichtstun. */
@Composable
fun rememberPhotoPicker(onFail: () -> Unit = {}, onPhoto: (ByteArray) -> Unit): Pair<() -> Unit, () -> Unit> {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val src = remember { PhotoSource(context) }
    val take: (Uri) -> Unit = { uri ->
        scope.launch {
            val jpeg = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { src.read(uri) }
            if (jpeg != null) onPhoto(jpeg) else onFail()
        }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) src.pending?.let(take) }
    val library = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let(take) }
    return { camera.launch(src.cameraUri()) } to { library.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
}

/** Fotos auf der Ortsseite: was freigegeben ist, und für alle mit Konto „Foto hinzufügen“. */
@Composable
fun PhotosSection(place: Place, onUploaded: () -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var note by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var face by remember { mutableStateOf<ByteArray?>(null) }
    fun upload(jpeg: ByteArray) {
        val id = place.serverID ?: return
        note = L.t("Wird hochgeladen …")
        scope.launch {
            runCatching { PlaceService.uploadPhoto(Graph.account.api, id, jpeg) }
                .onSuccess { note = null; onUploaded() }.onFailure { note = L.t("Nicht hochgeladen. Prüfe die Verbindung und versuche es noch einmal.") }
        }
    }
    // Vor dem Hochladen: Ist ein Gesicht zu sehen, fragt die App nach.
    val (camera, library) = rememberPhotoPicker(onFail = { note = L.t("Dieses Foto ließ sich nicht laden. Versuch es mit einem anderen.") }) { jpeg ->
        note = null
        if (PlaceService.hasFace(jpeg)) face = jpeg else upload(jpeg)
    }
    face?.let { jpeg ->
        AlertDialog(onDismissRequest = { face = null }, containerColor = p.paper,
            title = { Text(L.t("Auf dem Foto ist ein Gesicht zu sehen.")) },
            text = { Text(L.t("Fotos von Orten zeigen besser keine Menschen, die man erkennen kann.")) },
            confirmButton = { TextButton({ face = null; upload(jpeg) }) { Text(L.t("Trotzdem hochladen"), color = p.accent) } },
            dismissButton = { TextButton({ face = null }) { Text(L.t("Abbrechen"), color = p.ink) } })
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(L.t("Fotos"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink, modifier = Modifier.weight(1f))
            if (Graph.account.signedIn && place.serverID != null) Box {
                Row(Modifier.clip(RoundedCornerShape(50)).clickable { menu = true }.padding(horizontal = 6.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Sym.ADD, p.accent, 18.sp); Spacer(Modifier.width(4.dp)); Text(L.t("Foto hinzufügen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
                }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text(L.t("Foto aufnehmen")) }, { menu = false; camera() }, leadingIcon = { Icon(Sym.CAMERA, p.ink, 18.sp) })
                    DropdownMenuItem({ Text(L.t("Aus der Mediathek")) }, { menu = false; library() }, leadingIcon = { Icon(Sym.GALLERY, p.ink, 18.sp) })
                }
            }
        }
        if (place.photos.isEmpty()) Text(L.t("Noch keine Fotos. Zeig anderen, wie es hier aussieht."), fontSize = 14.sp, color = p.ink2)
        PlacePhotos(place.photos)
        note?.let { Text(it, fontSize = 14.sp, color = p.ink2) }
    }
}

@Composable
fun CheckedBadge(atSeconds: Long) {
    val green = Color(0xFF1F6F4A)
    val date = SimpleDateFormat("d. MMMM yyyy", app.thisdog.i18n.L.locale).format(Date(atSeconds * 1000))
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFFE3F3EA)).padding(horizontal = 14.dp, vertical = 10.dp)
        .semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Sym.SHIELD, green, 20.sp)
        Column {
            Text(L.t("Von ThisDog geprüft"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = green)
            Text(L.t("vor Ort am %1\$s", date), fontSize = 13.sp, color = green.copy(alpha = .8f))
        }
    }
}

/** Prüfungen ohne Netz: auf dem Gerät gesichert, mit Ort und Zeit von damals. */
object CheckQueue {
    @Serializable data class Item(val place: String, val name: String, val answers: Map<String, Int>, val lat: Double, val lon: Double, val at: Long, val photos: List<String>)
    private val json = Json { ignoreUnknownKeys = true }
    private fun dir(c: Context) = File(c.filesDir, "pruefungen").apply { mkdirs() }
    fun items(c: Context): List<Item> = runCatching { json.decodeFromString(ListSerializer(Item.serializer()), File(dir(c), "warteschlange.json").readText()) }.getOrDefault(emptyList())
    private fun save(c: Context, l: List<Item>) = File(dir(c), "warteschlange.json").writeText(json.encodeToString(ListSerializer(Item.serializer()), l))

    fun add(c: Context, place: Place, answers: Map<String, Int>, at: LatLng, photos: List<ByteArray>) {
        val names = photos.map { b -> "${java.util.UUID.randomUUID()}.jpg".also { File(dir(c), it).writeBytes(b) } }
        save(c, items(c) + Item(place.serverID ?: "", place.name, answers, at.lat, at.lng, System.currentTimeMillis() / 1000, names))
    }

    /** Schickt, was wartet. Was der Server ablehnt, fällt weg; ohne Netz bleibt es. */
    suspend fun flush(c: Context) {
        val rest = mutableListOf<Item>()
        for (item in items(c)) {
            try {
                val cid = PlaceService.check(Graph.account.api, item.place, item.answers, LatLng(item.lat, item.lon), item.at)
                item.photos.forEach { n -> File(dir(c), n).takeIf { it.exists() }?.let { f -> runCatching { PlaceService.uploadPhoto(Graph.account.api, item.place, f.readBytes(), check = cid) }; f.delete() } }
            } catch (e: Api.Failure.Offline) {
                rest += item
            } catch (e: Exception) {
                item.photos.forEach { File(dir(c), it).delete() }
            }
        }
        save(c, rest)
    }
}

/** Vor Ort prüfen (nur Erkunder): jedes Merkmal Ja oder Nein, drei Fotos. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CheckSheet(place: Place, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val answers = remember { mutableStateMapOf<PlaceFeature, Int>() }
    val photos = remember { mutableStateMapOf<String, ByteArray>() }
    var slot by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val slots = listOf(L.t("Eingang"), L.t("Fläche"), L.t("Besonderes"))
    val here = WalkRecorder.here
    val distance = here?.let { Track.distance(it, place.coordinate) }
    val near = (distance ?: Double.MAX_VALUE) <= CheckIns.REACH
    // Die neueren Merkmale (Kotbeutel, getrennte Bereiche) sind beim Server freiwillig; beantworten darf man sie trotzdem.
    val complete = place.features.filter { it.requiredForCheck }.all { it in answers } && photos.size == slots.size
    var faceShot by remember { mutableStateOf<ByteArray?>(null) }
    val (camera, _) = rememberPhotoPicker(onFail = { message = L.t("Dieses Foto ließ sich nicht laden. Versuch es mit einem anderen.") }) {
        message = null
        if (PlaceService.hasFace(it)) faceShot = it else photos[slot] = it
    }
    faceShot?.let { jpeg ->
        AlertDialog(onDismissRequest = { faceShot = null }, containerColor = p.paper,
            title = { Text(L.t("Auf dem Foto ist ein Gesicht zu sehen.")) },
            text = { Text(L.t("Fotos von Orten zeigen besser keine Menschen, die man erkennen kann.")) },
            confirmButton = { TextButton({ faceShot = null; photos[slot] = jpeg }) { Text(L.t("Trotzdem verwenden"), color = p.accent) } },
            dismissButton = { TextButton({ faceShot = null; camera() }) { Text(L.t("Neues Foto"), color = p.ink) } })
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onDismiss) { Text(L.t("Abbrechen"), color = p.ink2) }
                Text(L.t("Vor Ort prüfen"), fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton({
                    val at = here ?: return@TextButton; val id = place.serverID ?: return@TextButton
                    saving = true; message = null
                    val a = answers.filterKeys { it in place.features }.mapKeys { it.key.key }
                    val jpegs = slots.mapNotNull { photos[it] }
                    scope.launch {
                        try {
                            val cid = PlaceService.check(Graph.account.api, id, a, at, System.currentTimeMillis() / 1000)
                            slots.zip(jpegs).forEach { (s, d) -> runCatching { PlaceService.uploadPhoto(Graph.account.api, id, d, s, cid) } }
                            onDone(L.t("Geprüft. Die Angaben und Fotos sind jetzt zu sehen.")); onDismiss()
                        } catch (e: Api.Failure.Offline) {
                            CheckQueue.add(context, place, a, at, jpegs)
                            onDone(L.t("Ohne Netz gesichert. Die Prüfung geht raus, sobald du wieder online bist.")); onDismiss()
                        } catch (e: Api.Failure.Server) {
                            message = if (e.code == "too_far") L.t("Zu weit vom Ort entfernt.") else L.t("Nicht gesichert. Versuche es noch einmal.")
                        } catch (e: Exception) { message = L.t("Nicht gesichert. Versuche es noch einmal.") }
                        saving = false
                    }
                }, enabled = !saving && complete && near) { Text(L.t("Sichern"), color = if (!saving && complete && near) p.accent else p.ink3, fontWeight = FontWeight.SemiBold) }
            }
            val green = Color(0xFF1F6F4A)
            Text(when { distance == null -> L.t("Standort wird gesucht …"); near -> L.t("Du bist am Ort, %1\$s entfernt", WalkText.distance(distance)); else -> L.t("Noch %1\$s bis zum Ort", WalkText.distance(distance)) },
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (near) green else p.ink2,
                modifier = Modifier.padding(top = 10.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(if (near) Color(0xFFE3F3EA) else p.surface).padding(12.dp))
            place.features.forEach { f ->
                Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(f.sym, p.ink2, 18.sp); Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(f.title, fontSize = 15.sp, color = p.ink)
                        if (!f.requiredForCheck) Text(L.t("freiwillig"), fontSize = 12.sp, color = p.ink3)
                    }
                    SingleChoiceSegmentedButtonRow {
                        listOf(1 to L.t("Ja"), 0 to L.t("Nein")).forEachIndexed { i, (v, t) ->
                            // Freiwillige Merkmale lassen sich durch erneutes Antippen wieder offen lassen.
                            SegmentedButton(selected = answers[f] == v, onClick = { if (!f.requiredForCheck && answers[f] == v) answers.remove(f) else answers[f] = v },
                                shape = SegmentedButtonDefaults.itemShape(i, 2), icon = {},
                                colors = SegmentedButtonDefaults.colors(activeContainerColor = p.soft, activeContentColor = p.accent)) { Text(t, fontSize = 13.sp) }
                        }
                    }
                }
                HorizontalDivider(color = p.line)
            }
            Text(L.t("Fotos"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.padding(top = 18.dp, bottom = 8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                slots.forEach { s ->
                    val bmp = remember(photos[s]) { photos[s]?.let { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() } }
                    Box(Modifier.weight(1f).height(84.dp).clip(RoundedCornerShape(14.dp))
                        .then(if (bmp == null) Modifier.border(1.5.dp, p.accent, RoundedCornerShape(14.dp)) else Modifier)
                        .clickable { slot = s; camera() }, contentAlignment = Alignment.Center) {
                        if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Icon(Sym.CAMERA, p.accent, 22.sp)
                        Text(s, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = if (bmp == null) p.accent else Color.White,
                            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 6.dp))
                    }
                }
            }
            message?.let { Text(it, fontSize = 14.sp, color = p.health, modifier = Modifier.padding(top = 12.dp)) }
        }
    }
}

/** Die eigenen Prüfungen: was wartet, was freigegeben ist, was ohne Netz noch auf dem Gerät liegt. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyChecksSheet(onDismiss: () -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    var checks by remember { mutableStateOf<List<PlaceService.MyCheck>>(emptyList()) }
    var waiting by remember { mutableStateOf(CheckQueue.items(context)) }
    LaunchedEffect(Unit) {
        CheckQueue.flush(context); waiting = CheckQueue.items(context)
        checks = runCatching { PlaceService.mine(Graph.account.api).checks }.getOrDefault(emptyList())
    }
    val fmt = SimpleDateFormat("d. MMM, HH:mm", app.thisdog.i18n.L.locale)
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Text(L.t("Meine Prüfungen"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 30.sp, color = p.ink)
            if (waiting.isNotEmpty()) Text(if (waiting.size == 1) L.t("1 Prüfung wartet aufs Netz") else L.t("%1\$d Prüfungen warten aufs Netz", waiting.size), fontSize = 15.sp, color = p.ink2, modifier = Modifier.padding(top = 12.dp))
            val rows = waiting.map { Triple(it.name, L.t("%1\$s, %2\$s Fotos", fmt.format(Date(it.at * 1000)), it.photos.size), L.t("Ohne Netz") to p.ink3) } +
                checks.map { c -> Triple(c.name.ifEmpty { c.place }, "${fmt.format(Date(c.at * 1000))}, ${if (c.photos == 1) L.t("1 Foto") else L.t("%1\$d Fotos", c.photos)}",
                    when (c.status) { "ok" -> L.t("Freigegeben") to p.ok; "rejected" -> L.t("Abgelehnt") to p.health; else -> L.t("Wartet auf Freigabe") to p.accent }) }
            rows.forEach { (t, sub, st) ->
                Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text(t, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink); Text(sub, fontSize = 14.sp, color = p.ink2) }
                    Text(st.first, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = st.second)
                }
                HorizontalDivider(color = p.line)
            }
        }
    }
}
