package app.thisdog.ui

import app.thisdog.i18n.L
import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Api
import app.thisdog.data.Account
import app.thisdog.data.Graph
import app.thisdog.help.DeviceCode
import app.thisdog.help.Support
import kotlinx.coroutines.launch

/** In den Einstellungen: Problem melden und der Gerätecode zum Kopieren (wie HelpSection in Support.swift). */
@Composable
fun HelpSection() {
    val p = LocalPalette.current; val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    var reporting by remember { mutableStateOf(false) }
    val code = remember { DeviceCode.current(context) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(L.t("Support"), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink)
        // Eine leise Zeile: Wer etwas melden will, findet sie; alle anderen stört sie nicht.
        Row(Modifier.clip(RoundedCornerShape(50)).clickable { reporting = true }.heightIn(min = 44.dp).padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LineIcon(Sym.FLAG, p.accent, 20.dp); Text(L.t("Problem melden"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = p.accent)
        }
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(p.surface).padding(14.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(L.t("Gerätecode"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                SelectionContainer { Text(code, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, color = p.ink) }
                Text(remember { DeviceCode.description(context) }, fontSize = 12.sp, color = p.ink3)
            }
            Text(if (copied) L.t("Kopiert") else L.t("Kopieren"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable {
                    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(L.t("Gerätecode"), code)); copied = true
                }.padding(6.dp))
        }
        Text(L.t("Schreibst du an thisdog.app/support, gib den Gerätecode mit an. Er nennt Fassung, System und Gerät."), fontSize = 13.sp, color = p.ink2)
    }
    if (reporting) SupportSheet { reporting = false }
}

/** Problem melden: Worum geht es, was ist passiert, wohin die Antwort geht. Der Gerätecode geht mit. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SupportSheet(onDismiss: () -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current; val scope = rememberCoroutineScope()
    var kind by remember { mutableStateOf("problem") }
    var text by remember { mutableStateOf("") }
    var email by remember { mutableStateOf((Graph.account.state as? Account.State.SignedIn)?.email ?: "") }
    var sending by remember { mutableStateOf(false) }
    var number by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val ready = !sending && text.trim().length >= 5 && "@" in email
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (number != null) {
                Text(L.t("Danke"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 30.sp, color = p.ink)
                Text(L.t("Deine Nachricht hat die Nummer %1\$s. Die Antwort kommt per E-Mail an %2\$s, meist innerhalb von zwei Tagen.", number, email), fontSize = 16.sp, color = p.ink2)
                Button(onDismiss, shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent)) { Text(L.t("Fertig")) }
                return@Column
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onDismiss) { Text(L.t("Abbrechen"), color = p.ink2) }
                Text(L.t("Problem melden"), fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton({
                    sending = true; message = null
                    scope.launch {
                        try { number = Support.send(Graph.account.api, context, kind, email.trim(), text) }
                        catch (e: Api.Failure.Server) {
                            message = when (e.code) { "invalid_email" -> L.t("Die E-Mail-Adresse stimmt nicht."); "rate_limited" -> L.t("Gerade kamen zu viele Nachrichten. Versuch es in einer Viertelstunde noch einmal."); else -> L.t("Nicht gesendet. Versuch es noch einmal.") }
                        } catch (e: Exception) { message = L.t("Nicht gesendet. Prüfe die Verbindung und versuch es noch einmal.") }
                        sending = false
                    }
                }, enabled = ready) { Text(L.t("Senden"), color = if (ready) p.accent else p.ink3, fontWeight = FontWeight.SemiBold) }
            }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("problem" to L.t("Problem"), "frage" to L.t("Frage"), "idee" to L.t("Idee")).forEachIndexed { i, (k, t) ->
                    SegmentedButton(selected = kind == k, onClick = { kind = k }, shape = SegmentedButtonDefaults.itemShape(i, 3), icon = {},
                        colors = SegmentedButtonDefaults.colors(activeContainerColor = p.soft, activeContentColor = p.accent)) { Text(t) }
                }
            }
            OutlinedTextField(text, { if (it.length <= 5000) text = it }, Modifier.fillMaxWidth().heightIn(min = 150.dp), label = { Text(L.t("Was ist passiert?")) },
                placeholder = { Text(L.t("Was hast du gemacht, was ist passiert, was hast du erwartet?")) }, shape = RoundedCornerShape(14.dp))
            OutlinedTextField(email, { email = it }, Modifier.fillMaxWidth(), label = { Text(L.t("Antwort an")) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), shape = RoundedCornerShape(14.dp))
            Text(L.t("Mit geht der Gerätecode %1\$s: Fassung, System und Gerät. Deine Daten im Rudel bleiben, wo sie sind.", DeviceCode.current(context)), fontSize = 13.sp, color = p.ink2)
            message?.let { Text(it, fontSize = 14.sp, color = p.health) }
        }
    }
}
