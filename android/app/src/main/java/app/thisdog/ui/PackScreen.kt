package app.thisdog.ui

import app.thisdog.i18n.L
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.Image
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Account
import app.thisdog.data.Emergency
import app.thisdog.data.EmergencySnapshot
import app.thisdog.data.EmergencyStatus
import app.thisdog.data.Graph
import app.thisdog.model.Avatar
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.launch

fun openPage(context: android.content.Context, url: String) = CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))

fun share(context: android.content.Context, text: String, subject: String) =
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text).putExtra(Intent.EXTRA_SUBJECT, subject), null))

@Composable
fun LegalLinks() {
    val p = LocalPalette.current; val c = LocalContext.current
    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        Text(L.t("Datenschutz"), fontSize = 13.sp, color = p.ink2, modifier = Modifier.clickable { openPage(c, "https://thisdog.app/datenschutz") })
        Text(L.t("Impressum"), fontSize = 13.sp, color = p.ink2, modifier = Modifier.clickable { openPage(c, "https://thisdog.app/impressum") })
    }
}

/** Einstellungen: Konto, Support, Datenschutz und Impressum (wie SettingsScreen.swift). */
@Composable
fun SettingsScreen(onDismiss: () -> Unit) {
    val p = LocalPalette.current; val a = Graph.account; val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    androidx.compose.ui.window.Dialog(onDismiss, androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        DialogBars()
        Column(Modifier.fillMaxSize().background(p.paper).windowInsetsPadding(WindowInsets.safeDrawing)) {
            Text(L.t("Fertig"), color = p.accent, fontWeight = FontWeight.SemiBold, modifier = Modifier.align(Alignment.End).padding(8.dp).clip(RoundedCornerShape(50)).clickable(onClick = onDismiss).padding(horizontal = 12.dp, vertical = 10.dp))
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Column(Modifier.widthIn(max = 560.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(28.dp)) {
                    Text(L.t("Einstellungen"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 44.sp, color = p.ink)
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Title(L.t("Konto"), 20.sp)
                        when (val s = a.state) {
                            Account.State.Unknown -> CircularProgressIndicator(color = p.accent)
                            is Account.State.SignedIn -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(p.surface).padding(14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    if (s.email != null) {
                                        Text(L.t("Angemeldet als"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                                        androidx.compose.foundation.text.selection.SelectionContainer { Text(s.email, color = p.ink) }
                                    } else Text(L.t("Angemeldet auf diesem Telefon"), color = p.ink)
                                }
                                // Ohne Adresse käme man nach dem Abmelden nie wieder hinein: Dann gibt es nur „E-Mail hinzufügen“.
                                if (s.email == null) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Title(L.t("E-Mail hinzufügen (freiwillig)"), 17.sp)
                                    SignInForm(L.t("Damit kommst du auch von einem neuen Telefon wieder an dein Konto."))
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                                    if (s.email != null) Text(L.t("Abmelden"), color = p.ink2, fontSize = 15.sp, modifier = Modifier.clickable { scope.launch { a.signOut() } })
                                    Text(L.t("Konto löschen"), color = p.health, fontSize = 15.sp, modifier = Modifier.clickable { confirmDelete = true })
                                }
                            }
                            else -> SignInForm(L.t("Mit einem Konto gleicht ThisDog mit dem Rudel ab, und du kannst Orte bewerten und Fotos hochladen."))
                        }
                        message?.let { Text(it, fontSize = 15.sp, color = p.health) }
                    }
                    HelpSection()
                    LegalLinks()
                }
            }
        }
        if (confirmDelete) AlertDialog({ confirmDelete = false }, title = { Text(L.t("Konto löschen?")) },
            text = { Text(L.t("Deine E-Mail-Adresse und deine Anmeldungen verschwinden vom Server, ebenso Rudel, in denen sonst niemand ist, mit allen Daten, Notfallpass und Freundschaften. Die anderen in einem gemeinsamen Rudel behalten die gemeinsamen Daten. Auf diesem Gerät bleibt alles.")) },
            confirmButton = { TextButton({ confirmDelete = false; message = null; scope.launch { try { a.deleteAccount() } catch (e: Exception) { message = Account.message(e) } } }) { Text(L.t("Konto löschen"), color = p.health) } }, dismissButton = { TextButton({ confirmDelete = false }) { Text(L.t("Abbrechen")) } })
    }
}

/**
 * Das Rudel: Mitglieder, einladen (QR-Code oder Link), Einladung scannen, eigener Name, verlassen (wie PackScreen.swift).
 * Ein Konto braucht es dafür nicht vorher: Einladen oder Beitreten legt eins für dieses Telefon an.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PackScreen(onDismiss: () -> Unit) {
    val p = LocalPalette.current; val a = Graph.account; val scope = rememberCoroutineScope(); val context = LocalContext.current
    var email by remember { mutableStateOf("") }; var code by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }; var working by remember { mutableStateOf(false) }
    var confirmLeave by remember { mutableStateOf(false) }
    var confirmRevoke by remember { mutableStateOf(false) }
    fun run(work: suspend () -> Unit) { working = true; message = null; scope.launch { try { work() } catch (e: Exception) { message = Account.message(e) }; working = false } }

    var recoveryInput by remember { mutableStateOf("") }; var recovery by remember { mutableStateOf<String?>(null) }
    val saved = remember { context.getSharedPreferences("start", android.content.Context.MODE_PRIVATE) }
    var recoverySaved by remember(a.currentPack?.id) { mutableStateOf(saved.getBoolean("schluessel-${a.currentPack?.id}", false)) }
    fun markSaved() { saved.edit().putBoolean("schluessel-${a.currentPack?.id}", true).apply(); recoverySaved = true }
    var inviteUrl by remember { mutableStateOf<String?>(null) }
    var inviteRole by remember { mutableStateOf("sitter") }
    var choosesRole by remember { mutableStateOf(false) }
    var shownMember by remember { mutableStateOf<Int?>(null) }
    var withEmail by remember { mutableStateOf(false) }
    val scan = rememberInviteScanner({ link -> if (!a.open(link)) message = L.t("Das ist keine Einladung von ThisDog.") }, { message = it })
    // Erst fragen, als was jemand dazukommt; dann die Einladung mit dieser Rolle.
    val invite: () -> Unit = { choosesRole = true }
    fun makeInvite(role: String) {
        choosesRole = false; inviteRole = role
        run {
            a.ensureOwnPack()
            val inv = a.invite(role)
            inviteUrl = inv.url
            // Gemerkt (ohne Schlüssel – der liegt im Schlüsselspeicher), damit der Link wieder da ist, solange er gilt.
            a.currentPack?.id?.let { pack ->
                saved.edit().putInt("einladung-rudel", pack).putString("einladung-link", inv.url.substringBefore('#'))
                    .putString("einladung-rolle", role).putLong("einladung-bis", inv.expiresAt.toLong()).apply()
            }
        }
    }
    fun forgetInvite() { inviteUrl = null; saved.edit().remove("einladung-link").apply() }
    /** Nach „Einladungslinks ungültig machen“: Der gemerkte Link gilt nicht mehr, also ganz vergessen. */
    fun forgetSavedInvite() {
        inviteUrl = null
        saved.edit().remove("einladung-rudel").remove("einladung-link").remove("einladung-rolle").remove("einladung-bis").apply()
    }
    // Die Einladung von vorhin ist wieder da, solange sie noch mindestens eine Stunde gilt.
    LaunchedEffect(a.currentPack?.id) {
        val pack = a.currentPack?.id ?: return@LaunchedEffect
        val link = saved.getString("einladung-link", null) ?: return@LaunchedEffect
        if (inviteUrl != null || !a.isOwner || saved.getInt("einladung-rudel", -1) != pack) return@LaunchedEffect
        if (saved.getLong("einladung-bis", 0) - System.currentTimeMillis() < 3_600_000) return@LaunchedEffect
        a.withKey(link, pack)?.let { inviteUrl = it; inviteRole = saved.getString("einladung-rolle", "sitter") ?: "sitter" }
    }
    @Composable fun InviteButton() = Button(invite, Modifier.fillMaxWidth().height(52.dp), enabled = !working, shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = androidx.compose.ui.graphics.Color.White)) {
        LineIcon(Sym.PERSON_ADD, androidx.compose.ui.graphics.Color.White, 20.dp); Spacer(Modifier.width(8.dp)); Text(L.t("Rudelmitglied einladen"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
    @Composable fun ScanButton() = OutlinedButton(scan, Modifier.fillMaxWidth().height(50.dp), enabled = !working && !a.joining, shape = RoundedCornerShape(50)) {
        LineIcon(Sym.CAMERA, p.accent, 20.dp); Spacer(Modifier.width(8.dp)); Text(L.t("Einladung scannen"), color = p.accent, fontWeight = FontWeight.SemiBold)
    }
    OwnView(Graph.store.profile.name.ifEmpty { "ThisDog" }, L.t("Rudel"), onDismiss, left = {
        Text(L.t("Rudel"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 44.sp, color = p.ink)
        when (a.state) {
            Account.State.Unknown -> CircularProgressIndicator()
            is Account.State.SignedIn -> a.currentPack?.let { pack ->
                        Column {
                            pack.members.forEach { m ->
                                // Antippen: Rolle und Mitteilungen. Das eigene Mitglied immer, andere nur als Besitzer.
                                val opens = m.id == a.me || a.isOwner
                                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(enabled = opens) { shownMember = m.id }.padding(vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    if (m.id == a.me) AvatarPicker(Avatar.member(m.id), m.name, 46.dp, false, L.t("Dein Bild im Rudel"))
                                    else AvatarView(Graph.store.avatars.firstOrNull { it.id == Avatar.member(m.id) }?.jpeg, m.name, 46.dp)
                                    Column(Modifier.weight(1f)) { Text(m.name, fontWeight = FontWeight.SemiBold, color = p.ink); Text(memberLine(m, a.me), fontSize = 14.sp, color = p.ink2) }
                                    if (opens) {
                                        if (m.notifies.isEmpty()) Text(L.t("keine Mitteilungen"), fontSize = 12.sp, color = p.ink3)
                                        Text("›", fontSize = 22.sp, color = p.ink3)
                                    }
                                }
                            }
                        }
                Text(when { a.syncing -> L.t("Wird abgeglichen …"); a.lastError != null -> a.lastError!!; a.lastSync != null -> L.t("Abgeglichen"); else -> L.t("Noch nicht abgeglichen") }, fontSize = 13.sp, color = p.ink3)
            }
            else -> Text(L.t("Im Rudel habt ihr dieselben Termine und Gesundheitsdaten. Was einer einträgt, haben alle."), color = p.ink2)
        }
    }, right = {
        when (val s = a.state) {
            is Account.State.SignedIn -> {
                if (a.keyMissing) Column(Modifier.clip(RoundedCornerShape(18.dp)).background(p.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { LineIcon(Sym.KEY, p.ink, 22.dp); Text(L.t("Schlüssel fehlt"), fontWeight = FontWeight.SemiBold, color = p.ink) }
                    Text(L.t("Die Daten des Rudels sind verschlüsselt, und der Schlüssel liegt nur auf euren Geräten. Tippe auf einem Gerät, das schon dabei ist, auf „Rudelmitglied einladen“ und öffne den Link hier, oder gib euren Wiederherstellungsschlüssel ein."), fontSize = 14.sp, color = p.ink2)
                    OutlinedTextField(recoveryInput, { recoveryInput = it }, label = { Text(L.t("Wiederherstellungsschlüssel")) }, modifier = Modifier.fillMaxWidth(), textStyle = androidx.compose.ui.text.TextStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace))
                    Button({ run { a.restore(recoveryInput); recoveryInput = ""; markSaved() } }, enabled = !working && recoveryInput.isNotBlank()) { Text(L.t("Daten wiederherstellen")) }
                }
                if (a.joining) JoiningNote()
                a.currentPack?.let { pack ->
                        val mine = pack.members.firstOrNull { it.id == a.me }?.name ?: ""
                        var name by remember(pack.id) { mutableStateOf(if (mine == "Rudelmitglied") "" else mine) }
                        // Beim Schließen sichern, nicht nur mit „Sichern“: Wer tippt und geht, hat seinen Namen trotzdem.
                        val latest by rememberUpdatedState(name)
                        DisposableEffect(pack.id) { onDispose { a.saveNameLater(latest) } }
                        // Frisch dazugekommen: Erst der Name, damit die anderen sehen, wer unterwegs war.
                        if (mine == "Rudelmitglied") Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Title(L.t("Wie heißt du?"), 22.sp)
                            Text(L.t("Damit die anderen sehen, wer mit %1\$s unterwegs war.", Graph.store.profile.name.ifEmpty { L.t("dem Hund") }), fontSize = 15.sp, color = p.ink2)
                            OutlinedTextField(name, { name = it }, label = { Text(L.t("Dein Name")) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Words, imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { scope.launch { a.setName(name) } }))
                            PrimaryButton(L.t("Sichern"), enabled = name.isNotBlank()) { scope.launch { a.setName(name) } }
                        }
                        when {
                            inviteUrl != null -> InviteCard(inviteUrl!!, inviteRole) { forgetInvite() }
                            a.isOwner -> InviteButton()
                            else -> Text(L.t("Neue Mitglieder laden die Besitzer ein."), fontSize = 15.sp, color = p.ink2)
                        }
                        // Ein Link ging an die falsche Person oder liegt noch irgendwo herum: alle offenen auf einmal sperren.
                        if (a.isOwner && pack.openInvites > 0) Text(L.t("Einladungslinks ungültig machen"), color = p.health, fontSize = 15.sp,
                            modifier = Modifier.clickable(enabled = !working) { confirmRevoke = true })
                        if (mine != "Rudelmitglied") OutlinedTextField(name, { name = it }, label = { Text(L.t("Dein Name im Rudel")) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                            trailingIcon = { TextButton({ scope.launch { a.setName(name) } }) { Text(L.t("Sichern")) } })
                    a.recoveryCode()?.let { code ->
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(L.t("Falls alle Telefone weg sind"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                            Text(if (recoverySaved) L.t("Du hast den Wiederherstellungsschlüssel schon gesichert.") else L.t("Sichere den Wiederherstellungsschlüssel. Ohne ihn sind die Daten deines Hundes dann verloren, auch wir kommen nicht heran."), fontSize = 15.sp, color = if (recoverySaved) p.ink2 else p.ink)
                            Text(if (recoverySaved) L.t("Noch einmal ansehen") else L.t("Schlüssel sichern"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent, modifier = Modifier.clickable { recovery = code })
                        }
                    }
                }
                Text(L.t("Einladung scannen"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable(enabled = !a.joining, onClick = scan))
                if ((a.currentPack?.members?.size ?: 0) > 1) Text(L.t("Rudel verlassen"), color = p.health, fontSize = 15.sp, modifier = Modifier.clickable { confirmLeave = true })
            }
            Account.State.Unknown -> {}
            else -> {
                // Kein Formular vorweg: Einladen oder Beitreten legt das Konto für dieses Telefon selbst an.
                if (a.joining) JoiningNote()
                InviteButton()
                ScanButton()
                Text(L.t("Oder öffne den Einladungslink, den du bekommen hast."), fontSize = 14.sp, color = p.ink2)
                if (withEmail || a.state is Account.State.LinkSent) SignInForm(L.t("Schon ein Konto mit E-Mail, etwa von einem anderen Telefon? Du bekommst einen Code, ein Passwort brauchst du nicht."))
                else Text(L.t("Mit E-Mail anmelden"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable { withEmail = true })
            }
        }
            (message ?: a.joinMessage)?.let { Text(it, fontSize = 14.sp, color = p.health) }
    })
    recovery?.let { code -> RecoveryDialog(code, onSaved = { markSaved() }) { recovery = null } }
    if (choosesRole) RoleChoiceDialog({ choosesRole = false }) { makeInvite(it) }
    shownMember?.let { id -> MemberDialog(id) { shownMember = null } }
    if (confirmRevoke) AlertDialog({ confirmRevoke = false }, title = { Text(L.t("Einladungslinks ungültig machen?")) },
        text = { Text(L.t("Alle Einladungen, die noch nicht benutzt wurden, funktionieren dann nicht mehr – auch verschickte Links und QR-Codes. Wer schon im Rudel ist, bleibt.")) },
        confirmButton = { TextButton({ confirmRevoke = false; run { a.revokeInvites(); forgetSavedInvite() } }) { Text(L.t("Ungültig machen"), color = p.health) } },
        dismissButton = { TextButton({ confirmRevoke = false }) { Text(L.t("Abbrechen")) } })
    if (confirmLeave) AlertDialog({ confirmLeave = false }, title = { Text(L.t("Rudel verlassen?")) }, text = { Text(L.t("Die gemeinsamen Termine verschwinden von diesem Gerät. Die anderen behalten sie.")) },
        confirmButton = { TextButton({ confirmLeave = false; run { a.leave() } }) { Text(L.t("Verlassen"), color = p.health) } }, dismissButton = { TextButton({ confirmLeave = false }) { Text(L.t("Abbrechen")) } })
}

/** Während eine Einladung eingelöst wird. */
@Composable
fun JoiningNote() {
    val p = LocalPalette.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator(Modifier.size(22.dp), color = p.accent, strokeWidth = 2.5.dp)
        Text(L.t("Du kommst ins Rudel …"), color = p.ink)
    }
}

fun qrBitmap(text: String, size: Int = 600): Bitmap {
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(com.google.zxing.EncodeHintType.MARGIN to 1))
    return Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).apply { for (x in 0 until size) for (y in 0 until size) setPixel(x, y, if (m[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()) }
}

/** Der Notfallpass: der QR-Code zuerst, dann was der Finder sieht (wie EmergencyPassScreen.swift). */
@Composable
fun EmergencyScreen(onDismiss: () -> Unit, onSignIn: () -> Unit, demo: Boolean = false) {
    val p = LocalPalette.current; val scope = rememberCoroutineScope(); val context = LocalContext.current
    val e = remember { Emergency(Graph.account) }
    var status by remember { mutableStateOf<EmergencyStatus?>(if (demo) EmergencyStatus(true, "https://thisdog.app/notfall/Beispiel4Dv25Q20hzybK", views = 0) else null) }
    var message by remember { mutableStateOf<String?>(null) }; var confirm by remember { mutableStateOf(false) }
    val signedIn = demo || Graph.account.signedIn
    val s = EmergencySnapshot.from(Graph.store)
    LaunchedEffect(Unit) { if (!demo && signedIn) status = runCatching { e.status() }.getOrElse { message = L.t("Der Stand des Passes ließ sich nicht laden. Prüf die Verbindung."); EmergencyStatus(false) } }
    // Direkt bearbeiten: Änderungen werden kurz nach dem letzten Tippen gesichert.
    // `base`: der Stand, von dem `draft` ausging. Gesichert wird nur, was hier geändert wurde – sonst schriebe ein offener
    // Pass einen veralteten Namen zurück, wenn inzwischen das Profil des Rudels angekommen ist.
    var draft by remember { mutableStateOf(Graph.store.profile) }
    var base by remember { mutableStateOf(Graph.store.profile) }
    fun saveDraft() {
        val merged = Graph.store.profile.applying(draft, base)
        if (merged != Graph.store.profile) Graph.store.save(merged)
        base = merged; draft = merged
    }
    // Kommt ein neuer Stand an und hier wurde nichts geändert, zeigt der Pass ihn.
    val current = Graph.store.profile
    LaunchedEffect(current) { if (draft == base) { draft = current; base = current } }
    LaunchedEffect(draft) { kotlinx.coroutines.delay(700); if (draft != base) saveDraft() }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { if (draft != base) saveDraft() } }
    var reportsLost by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    // Entlaufen und wieder da: sofort sichern und die Seite neu veröffentlichen (bei Bedarf mit neuem Konto).
    val republish: () -> Unit = {
        scope.launch {
            working = true
            runCatching { if (!Graph.account.signedIn) Graph.account.ensureOwnPack(); status = e.publish() }.onFailure { message = Account.message(it) }
            working = false
        }
    }
    OwnView(Graph.store.profile.name.ifEmpty { "ThisDog" }, L.t("Notfallpass"), onDismiss, rightFirst = true, left = {
            // Vorschau: Das Wichtigste auf dieser Seite ist der QR-Code in der anderen Spalte.
            Text(L.t("Ich heiße %1\$s.", s.name), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 40.sp, lineHeight = 44.sp, color = p.ink)
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Title(L.t("So sieht es der Finder"), 20.sp)
                if (s.ownerPhone.isNotEmpty()) Text("${if (s.ownerName.isEmpty()) L.t("Anrufen") else L.t("%1\$s anrufen", s.ownerName)}  ${s.ownerPhone}", color = androidx.compose.ui.graphics.Color.White, fontWeight = FontWeight.SemiBold,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(p.accent).padding(vertical = 15.dp))
                if (s.important.isNotEmpty() || s.meds.isNotEmpty()) Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(p.health.copy(alpha = .12f)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (s.important.isNotEmpty()) Finder(L.t("Wichtig"), s.important, true); if (s.meds.isNotEmpty()) Finder(L.t("Medikamente"), s.meds, true)
                }
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(p.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Finder(L.t("Chipnummer"), s.chip.ifEmpty { L.t("nicht eingetragen") }); Finder(L.t("Tierarzt"), listOf(s.vetName, s.vetPhone).filter(String::isNotEmpty).joinToString("\n").ifEmpty { L.t("nicht eingetragen") })
                }
            }
    }, right = {
            val st = status
            LostSection(draft, st?.url?.takeIf { st.active }, working, onReport = { reportsLost = true },
                onShare = { st?.url?.let { share(context, app.thisdog.model.LostDog.flyer(EmergencySnapshot.from(Graph.store), it), L.t("%1\$s wird vermisst", draft.name)) } },
                onFound = { draft = draft.copy(lostSince = "", lostWhere = "", lostNote = ""); saveDraft(); republish() })
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(p.surface).padding(18.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                when {
                    !signedIn -> {
                        Text(L.t("Damit ein Finder die Seite öffnen kann, liegt sie auf thisdog.app. Dafür legt ThisDog ein Konto für dieses Telefon an, ohne E-Mail und ohne Passwort."), fontSize = 15.sp, color = p.ink2)
                        Button({ scope.launch { runCatching { Graph.account.ensureOwnPack(); status = e.status() }.onFailure { message = Account.message(it) } } }, shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent)) { Text(L.t("Weiter")) }
                    }
                    st == null -> CircularProgressIndicator(color = p.accent)
                    st.active && st.url != null -> {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                            val bmp = remember(st.url) { qrBitmap(st.url).asImageBitmap() }
                            Image(bmp, L.t("QR-Code zum Notfallpass"), Modifier.size(168.dp).clip(RoundedCornerShape(16.dp)).background(androidx.compose.ui.graphics.Color.White).padding(10.dp), filterQuality = FilterQuality.None)
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { Text(L.t("Freigegeben"), fontWeight = FontWeight.SemiBold, color = p.ink); Text(if ((st.views ?: 0) > 0) L.t("%1\$s-mal geöffnet.", st.views) else L.t("Noch nicht geöffnet."), fontSize = 15.sp, color = p.ink2) }
                        }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button({ share(context, st.url, L.t("Notfallpass von %1\$s", s.name)) }, shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = androidx.compose.ui.graphics.Color.White)) { LineIcon(Sym.SHARE, androidx.compose.ui.graphics.Color.White, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("QR-Code teilen"), maxLines = 1) }
                            OutlinedButton({ openPage(context, st.url) }, shape = RoundedCornerShape(50)) { LineIcon(Sym.COMPASS, p.accent, 20.dp); Spacer(Modifier.width(6.dp)); Text(L.t("Seite ansehen"), color = p.accent, maxLines = 1) }
                        }
                        Text(L.t("Sperren"), color = p.health, fontSize = 15.sp, modifier = Modifier.clickable { confirm = true })
                    }
                    else -> {
                        Text(L.t("Mit einem QR-Code am Halsband sieht jeder, der %1\$s findet, wen er anrufen soll – ohne App, ohne Anmeldung. Wenn jemand den Pass öffnet, bekommt das Rudel eine Mitteilung.", s.name), fontSize = 15.sp, color = p.ink2)
                        PrimaryButton(L.t("Notfallpass freigeben"), enabled = s.ownerPhone.isNotEmpty()) { scope.launch { status = runCatching { e.publish() }.getOrElse { message = Account.message(it); st } } }
                        if (s.ownerPhone.isEmpty()) Text(L.t("Trag zuerst eine Telefonnummer ein, sonst kann dich niemand anrufen."), fontSize = 13.sp, color = p.ink3)
                    }
                }
            }
            message?.let { Text(it, color = p.health, fontSize = 15.sp) }
            Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Title(L.t("Was der Finder sieht"), 20.sp)
                PassGroup(L.t("Wen anrufen?")) {
                    SoftField(draft.ownerName, { draft = draft.copy(ownerName = it) }, L.t("Dein Name"))
                    SoftField(draft.ownerPhone, { draft = draft.copy(ownerPhone = it) }, L.t("Telefon"), keyboard = KeyboardOptions(keyboardType = KeyboardType.Phone))
                }
                PassGroup(L.t("Wichtig")) { SoftField(draft.allergies, { draft = draft.copy(allergies = it) }, L.t("Allergien, Unverträglichkeiten")) }
                PassGroup(L.t("Chip")) { SoftField(draft.chip, { draft = draft.copy(chip = it) }, L.t("Chipnummer"), keyboard = KeyboardOptions(keyboardType = KeyboardType.Number)) }
                PassGroup(L.t("Tierarzt")) {
                    SoftField(draft.vetName, { draft = draft.copy(vetName = it) }, L.t("Praxis"))
                    SoftField(draft.vetPhone, { draft = draft.copy(vetPhone = it) }, L.t("Telefon"), keyboard = KeyboardOptions(keyboardType = KeyboardType.Phone))
                }
            }
            Text(L.t("Ändert sich etwas, aktualisiert ThisDog die Seite. Der QR-Code bleibt gleich."), fontSize = 13.sp, color = p.ink3)
    })
    if (reportsLost) LostDogSheet(draft, { reportsLost = false }) { whereSeen, note, phone ->
        draft = draft.copy(ownerPhone = draft.ownerPhone.ifEmpty { phone }, lostSince = app.thisdog.model.LostDog.stamp(), lostWhere = whereSeen, lostNote = note)
        saveDraft(); republish()
    }
    if (confirm) AlertDialog({ confirm = false }, title = { Text(L.t("Notfallpass sperren?")) }, text = { Text(L.t("Gedruckte QR-Codes führen dann ins Leere. Gibst du den Pass wieder frei, bekommt er einen neuen Code.")) },
        confirmButton = { TextButton({ confirm = false; scope.launch { runCatching { e.revoke() }; status = EmergencyStatus(false) } }) { Text(L.t("Sperren"), color = p.health) } }, dismissButton = { TextButton({ confirm = false }) { Text(L.t("Abbrechen")) } })
}

@Composable
private fun PassGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = LocalPalette.current.ink2)
        content()
    }
}

@Composable private fun Finder(label: String, value: String, alarm: Boolean = false) {
    val p = LocalPalette.current
    Column { Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = if (alarm) p.health else p.ink2); Text(value, fontWeight = FontWeight.SemiBold, color = p.ink) }
}
