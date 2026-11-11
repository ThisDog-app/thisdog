package app.thisdog.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.thisdog.data.Graph
import app.thisdog.i18n.L
import app.thisdog.model.Avatar
import app.thisdog.model.Day
import app.thisdog.model.HealthNote
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.LocalTime
import java.util.Base64

/** Kleines JPEG fürs Tagebuch: lange Seite höchstens 900 px (sonst 700, 520), Base64 höchstens 60 000 Zeichen. */
object NotePhoto {
    /** Aus Kamera oder Galerie, auch HEIC und sehr große Fotos (gelesen über [Pictures], aufrecht gedreht). */
    fun prepare(context: android.content.Context, uri: Uri): String? = runCatching { Pictures.load(context, uri)?.let(::prepare) }.getOrNull()

    fun prepare(src: Bitmap): String? {
        for (side in listOf(900, 700, 520)) {
            val k = minOf(1f, side.toFloat() / maxOf(src.width, src.height))
            val small = Bitmap.createScaledBitmap(src, maxOf(1, (src.width * k).toInt()), maxOf(1, (src.height * k).toInt()), true)
            for (q in listOf(70, 55, 40, 30)) {
                val out = ByteArrayOutputStream()
                small.compress(Bitmap.CompressFormat.JPEG, q, out)
                val s = Base64.getEncoder().encodeToString(out.toByteArray())
                if (s.length <= 60_000) return s
            }
        }
        return null
    }

    fun bitmap(b64: String?): ImageBitmap? = b64?.let {
        runCatching { val b = Base64.getDecoder().decode(it); BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() }.getOrNull()
    }
}

/** Das Gesundheitstagebuch im Reiter Gesundheit: neueste zuerst, mit Foto und wer es eingetragen hat. */
@Composable
fun HealthDiarySection() {
    val p = LocalPalette.current; val s = Graph.store; val context = LocalContext.current
    var editing by remember { mutableStateOf<HealthNote?>(null) }
    var all by remember { mutableStateOf(false) }
    val list = s.notes.sortedWith(compareByDescending<HealthNote> { it.d }.thenByDescending { it.time }.thenByDescending { it.u })
    val visible = if (all) list else list.take(6)
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(L.t("Tagebuch"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, color = p.ink, modifier = Modifier.weight(1f))
            RoundButton(Sym.ADD, L.t("Ins Tagebuch schreiben"), 44.dp, p.accent) { editing = HealthNote() }
        }
        if (list.isEmpty()) {
            Text(L.t("Erbrochen, humpelt, Zecke entfernt: kurz notiert, mit Datum und Foto. Beim Tierarzt hast du dann den Verlauf."), fontSize = 15.sp, color = p.ink3)
            OutlinedButton({ editing = HealthNote() }, Modifier.fillMaxWidth(), shape = RoundedCornerShape(50)) { Text(L.t("Erster Eintrag"), color = p.accent) }
        } else {
            Column(Modifier.clip(RoundedCornerShape(24.dp)).background(p.surface).padding(horizontal = 16.dp, vertical = 4.dp)) {
                visible.forEachIndexed { i, n ->
                    NoteRow(n) { editing = n }
                    if (i < visible.lastIndex) HorizontalDivider(color = p.line)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (list.size > visible.size || all) Text(if (all) L.t("Weniger zeigen") else L.t("Alle %1\$s Einträge", list.size), color = p.accent, fontSize = 15.sp,
                    fontWeight = FontWeight.Medium, modifier = Modifier.clickable { all = !all })
                Spacer(Modifier.weight(1f))
                Row(Modifier.clickable { share(context, HealthNote.vetSummary(list, s.profile.name), L.t("Gesundheitstagebuch von %1\$s", s.profile.name)) },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    LineIcon(Sym.SHARE, p.accent, 20.dp); Text(L.t("Für den Tierarzt"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
    editing?.let { HealthNoteEditor(it) { editing = null } }
}

@Composable
private fun NoteRow(n: HealthNote, onClick: () -> Unit) {
    val p = LocalPalette.current; val s = Graph.store
    val photo = remember(n.photo) { NotePhoto.bitmap(n.photo) }
    val author = s.changer(HealthNote.KIND, n.id)?.let { id -> Graph.account.name(id)?.let { it to s.avatars.firstOrNull { a -> a.id == Avatar.member(id) }?.jpeg } }
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(HealthNote.whenText(n), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
            Text(n.headline, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (n.tags.isNotEmpty() && n.text.isNotEmpty()) Text(n.text, fontSize = 14.sp, color = p.ink2, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        author?.let { (name, jpeg) -> AvatarView(jpeg, name, 22.dp) }
        photo?.let { Image(it, null, Modifier.size(52.dp).clip(RoundedCornerShape(10.dp)), contentScale = ContentScale.Crop) }
    }
}

/** Ein Eintrag: Stichworte zum Antippen, eigener Text, Tag und Uhrzeit, ein Foto. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun HealthNoteEditor(note: HealthNote, onDismiss: () -> Unit) {
    val p = LocalPalette.current; val s = Graph.store; val context = LocalContext.current
    val isNew = s.notes.none { it.id == note.id }
    var draft by remember { mutableStateOf(note) }
    var date by remember { mutableStateOf(note.d) }
    val now = remember { LocalTime.now() }
    var withTime by remember { mutableStateOf(isNew || note.time.isNotEmpty()) }
    var time by remember { mutableStateOf(if (isNew) "%02d:%02d".format(now.hour, now.minute) else note.time) }
    var failed by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<Uri?>(null) }
    val use: (Uri) -> Unit = { uri -> NotePhoto.prepare(context, uri)?.let { draft = draft.copy(photo = it); failed = false } ?: run { failed = true } }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) pending?.let(use) }
    val library = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let(use) }
    val timeOk = !withTime || Regex("^([01]?\\d|2[0-3]):[0-5]\\d$").matches(time)
    val canSave = (draft.tags.isNotEmpty() || draft.text.isNotBlank() || draft.photo != null) && Day.parse(date) != null && timeOk
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(if (isNew) L.t("Neuer Eintrag") else L.t("Eintrag"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 30.sp, color = p.ink)
            Text(L.t("Was war los?"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                (HealthNote.PRESETS + draft.tags.filter { it !in HealthNote.PRESETS }).forEach { tag ->
                    val on = tag in draft.tags
                    FilterChip(on, { draft = draft.copy(tags = if (on) draft.tags - tag else draft.tags + tag) }, { Text(tag) },
                        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = p.accent, selectedLabelColor = androidx.compose.ui.graphics.Color.White))
                }
            }
            OutlinedTextField(draft.text, { draft = draft.copy(text = it) }, placeholder = { Text(L.t("Was ist dir aufgefallen?")) }, minLines = 3, modifier = Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(date, { date = it }, label = { Text(L.t("Tag (JJJJ-MM-TT)")) }, singleLine = true, modifier = Modifier.weight(1.4f), isError = Day.parse(date) == null)
                if (withTime) OutlinedTextField(time, { time = it }, label = { Text(L.t("Uhrzeit")) }, singleLine = true, modifier = Modifier.weight(1f), isError = !timeOk)
            }
            Row(verticalAlignment = Alignment.CenterVertically) { Text(L.t("Mit Uhrzeit"), Modifier.weight(1f), color = p.ink); Switch(withTime, { withTime = it }) }
            Text(L.t("Foto"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
            val bmp = remember(draft.photo) { NotePhoto.bitmap(draft.photo) }
            if (bmp != null) {
                Image(bmp, L.t("Foto"), Modifier.fillMaxWidth().heightIn(max = 260.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Fit)
                TextButton({ draft = draft.copy(photo = null) }) { Text(L.t("Foto entfernen"), color = p.health) }
            } else Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton({
                    val dir = File(context.cacheDir, "fotos").apply { mkdirs() }
                    val uri = FileProvider.getUriForFile(context, "app.thisdog.fotos", File(dir, "tagebuch-${System.currentTimeMillis()}.jpg"))
                    pending = uri; camera.launch(uri)
                }, shape = RoundedCornerShape(50)) { LineIcon(Sym.CAMERA, p.accent, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("Foto aufnehmen"), color = p.accent) }
                OutlinedButton({ library.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, shape = RoundedCornerShape(50)) {
                    LineIcon(Sym.GALLERY, p.accent, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("Galerie"), color = p.accent)
                }
            }
            if (failed) Text(L.t("Dieses Foto ließ sich nicht verwenden."), color = p.health, fontSize = 14.sp)
            Text(L.t("Ausschlag, Wunde, Häufchen: Ein Foto sagt dem Tierarzt oft mehr. Es wird verschlüsselt mit dem Rudel geteilt."), fontSize = 13.sp, color = p.ink3)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!isNew) TextButton({ confirmDelete = true }) { Text(L.t("Löschen"), color = p.health) }
                Spacer(Modifier.weight(1f))
                Button({
                    val t = if (withTime) time.split(":").let { "%02d:%02d".format(it[0].toInt(), it[1].toInt()) } else ""
                    s.save(draft.copy(text = draft.text.trim(), d = date.trim(), time = t)); onDismiss()
                }, enabled = canSave) { Text(L.t("Sichern")) }
            }
        }
    }
    if (confirmDelete) AlertDialog({ confirmDelete = false }, title = { Text(L.t("Eintrag löschen?")) },
        confirmButton = { TextButton({ confirmDelete = false; s.deleteNote(note.id); onDismiss() }) { Text(L.t("Löschen"), color = p.health) } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text(L.t("Abbrechen")) } })
}
