package app.thisdog.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.i18n.L
import app.thisdog.model.DogProfile
import app.thisdog.model.LostDog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Im Notfallpass ganz oben: nicht vermisst ein ruhiger Knopf für den Ernstfall, vermisst die rote Karte mit dem Steckbrief. */
@Composable
fun LostSection(profile: DogProfile, url: String?, working: Boolean, onReport: () -> Unit, onShare: () -> Unit, onFound: () -> Unit) {
    val p = LocalPalette.current
    val name = profile.name.ifEmpty { L.t("Hund") }
    if (profile.isLost) {
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(p.health).padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(L.t("%1\$s wird vermisst", name), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 30.sp, color = Color.White)
            Text(LostDog.since(profile), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = .9f))
            if (url != null) {
                Button(onShare, Modifier.fillMaxWidth().height(50.dp), shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = p.health)) {
                    LineIcon(Sym.SHARE, p.health, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("Steckbrief teilen"), fontWeight = FontWeight.SemiBold)
                }
                Text(L.t("Für Nachbarn, Gassi-Gruppen, Tierheim und Tierärzte in der Nähe. Der Link zeigt Foto, Chipnummer und deine Nummer – und dass %1\$s vermisst wird.", name),
                    fontSize = 13.sp, color = Color.White.copy(alpha = .85f))
            } else if (working) CircularProgressIndicator(color = Color.White)
            Text(L.t("%1\$s ist wieder da", name), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.clickable(onClick = onFound).padding(vertical = 4.dp))
        }
    } else {
        OutlinedButton(onReport, Modifier.fillMaxWidth().height(50.dp), enabled = !working, shape = RoundedCornerShape(50), border = BorderStroke(1.dp, p.health)) {
            LineIcon(Sym.EMERGENCY, p.health, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("%1\$s ist entlaufen", name), color = p.health, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Der erste Schritt im Ernstfall: wo zuletzt gesehen, was ein Finder wissen muss, unter welcher Nummer. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LostDogSheet(profile: DogProfile, onDismiss: () -> Unit, onReport: (whereSeen: String, note: String, phone: String) -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current; val scope = rememberCoroutineScope()
    val name = profile.name.ifEmpty { L.t("dein Hund") }
    var whereSeen by remember { mutableStateOf("") }
    var note by remember { mutableStateOf(profile.lostNote) }
    var phone by remember { mutableStateOf("") }
    var locating by remember { mutableStateOf(false) }
    val canReport = profile.ownerPhone.isNotEmpty() || phone.isNotBlank()
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(L.t("%1\$s ist entlaufen", name), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 30.sp, lineHeight = 34.sp, color = p.ink)
            Text(L.t("Der Notfallpass wird zum Steckbrief: Wer den QR-Code am Halsband scannt oder den Link bekommt, sieht sofort, dass %1\$s vermisst wird. Dein Rudel sieht es auch.", name), fontSize = 15.sp, color = p.ink2)
            OutlinedTextField(whereSeen, { whereSeen = it }, label = { Text(L.t("Wo zuletzt gesehen?")) }, placeholder = { Text(L.t("z. B. Augarten, beim Spielplatz")) }, modifier = Modifier.fillMaxWidth())
            TextButton({
                scope.launch {
                    locating = true
                    lastPlaceName(context)?.let { whereSeen = it }
                    locating = false
                }
            }, enabled = !locating) { LineIcon(Sym.COMPASS, p.accent, 20.dp); Spacer(Modifier.width(6.dp)); Text(if (locating) L.t("Ort wird gesucht …") else L.t("Mein Standort"), color = p.accent) }
            OutlinedTextField(note, { note = it }, label = { Text(L.t("Was ein Finder wissen sollte")) }, placeholder = { Text(L.t("z. B. Ängstlich, nicht rufen. Rotes Halsband.")) }, minLines = 2, modifier = Modifier.fillMaxWidth())
            if (profile.ownerPhone.isEmpty()) {
                OutlinedTextField(phone, { phone = it }, label = { Text(L.t("Unter welcher Nummer?")) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))
                Text(L.t("Ohne Nummer kann dich niemand anrufen."), fontSize = 13.sp, color = p.ink3)
            }
            Row { Spacer(Modifier.weight(1f)); TextButton(onDismiss) { Text(L.t("Abbrechen")) }
                Button({ onReport(whereSeen.trim(), note.trim(), phone.trim()); onDismiss() }, enabled = canReport, colors = ButtonDefaults.buttonColors(containerColor = p.health)) { Text(L.t("Melden")) } }
        }
    }
}

/** Der aktuelle oder zuletzt bekannte Ort als Adresse („Obere Augartenstraße 1, Wien“), über den Geocoder des Telefons. */
@Suppress("DEPRECATION")
private suspend fun lastPlaceName(context: android.content.Context): String? {
    val rec = app.thisdog.gassi.WalkRecorder
    if (rec.hasPermission(context)) rec.locateOnce(context)
    kotlinx.coroutines.delay(1000)
    val c = rec.here ?: Graph.store.walks.maxByOrNull { it.start }?.coordinates?.lastOrNull() ?: return null
    if (!android.location.Geocoder.isPresent()) return null
    return withContext(Dispatchers.IO) {
        runCatching {
            android.location.Geocoder(context, app.thisdog.i18n.L.locale).getFromLocation(c.lat, c.lng, 1)?.firstOrNull()?.let { a ->
                listOfNotNull(listOfNotNull(a.thoroughfare, a.subThoroughfare).joinToString(" ").ifEmpty { null }, a.locality).joinToString(", ").ifEmpty { a.getAddressLine(0) }
            }
        }.getOrNull()
    }
}

/** Auf „Heute“ ganz oben, für alle im Rudel, solange der Hund vermisst wird. */
@Composable
fun LostDogBanner(onOpen: () -> Unit) {
    val p = LocalPalette.current; val pr = Graph.store.profile
    if (!pr.isLost) return
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(p.health).clickable(onClick = onOpen).padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(L.t("%1\$s wird vermisst", pr.name), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 24.sp, lineHeight = 28.sp, color = Color.White)
        Text(LostDog.since(pr), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = .9f))
        Text(L.t("Steckbrief teilen"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, textDecoration = TextDecoration.Underline)
    }
}
