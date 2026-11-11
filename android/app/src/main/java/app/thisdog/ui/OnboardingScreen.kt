package app.thisdog.ui

import app.thisdog.i18n.L
import android.Manifest
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.thisdog.data.Account
import app.thisdog.data.Graph
import app.thisdog.gassi.WalkRecorder
import app.thisdog.model.Avatar
import app.thisdog.model.Day
import app.thisdog.system.Reminders
import kotlinx.coroutines.launch
import kotlin.math.sin

private enum class Step { NAME, DETAILS, WALKS, REMINDERS, PACK, KEY, DONE }

/** Zum Ansehen (Entwicklerfassung): `--es hundname Stella` trägt den Namen schon ein. */
object OnboardingDemo { var name = "" }

/**
 * Der erste Start (wie OnboardingScreen.swift): lernt den Hund kennen und bereitet vor, was später gebraucht wird:
 * Standort, Mitteilungen, Konto, Wiederherstellungsschlüssel. Bis auf den Namen lässt sich alles überspringen.
 * Auf zarter Mandarine; Stella begleitet durch den ganzen Ablauf und tritt zurück, wo der Platz nicht reicht.
 */
@Composable
fun OnboardingScreen(startStep: Int = 0, finish: () -> Unit) {
    val p = LocalPalette.current; val store = Graph.store; val a = Graph.account; val context = LocalContext.current
    val density = LocalDensity.current
    var step by remember { mutableStateOf(Step.entries.getOrElse(startStep) { Step.NAME }) }
    var name by remember { mutableStateOf(OnboardingDemo.name) }
    var breed by remember { mutableStateOf("") }
    var sex by remember { mutableStateOf("") }
    var knowsBirth by remember { mutableStateOf(false) }
    var birth by remember { mutableStateOf(Day.today().addingYears(-2).iso) }
    var inPack by remember { mutableStateOf(false) }
    var inviteUrl by remember { mutableStateOf<String?>(null) }
    var inviteRole by remember { mutableStateOf("sitter") }
    var choosesRole by remember { mutableStateOf(false) }
    var withEmail by remember { mutableStateOf(false) }
    var packMessage by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var showKey by remember { mutableStateOf<String?>(null) }
    var keySaved by remember { mutableStateOf(false) }
    // Wie viel Platz der Inhalt braucht und wie viel da ist: Das Logo nimmt sich nur, was übrig bleibt.
    var contentHeight by remember { mutableStateOf(0.dp) }
    var regionHeight by remember { mutableStateOf(0.dp) }
    val typed = name.trim()
    val dog = typed.ifEmpty { L.t("dein Hund") }
    val dogAcc = if (typed.isEmpty()) L.t("deinen Hund") else typed

    fun save() {
        store.save(store.profile.copy(name = typed, breed = breed.trim(), sex = sex, birthdate = if (knowsBirth) birth else ""))
    }
    fun next() {
        if (step == Step.NAME || step == Step.DETAILS) save()
        var t = Step.entries.getOrElse(step.ordinal + 1) { Step.DONE }
        if (t == Step.KEY && !a.signedIn) t = Step.DONE
        step = t
    }
    suspend fun afterSignIn() {
        a.sync()
        step = when {
            // Im Rudel kommt der Hund vom Rudel: nie nach seinem Namen fragen – wer gerade „Wie heißt du?“ beantwortet hat,
            // tippt sonst den eigenen ein, und der ginge an alle. Fehlt das Profil noch, kommt es mit dem nächsten Abgleich.
            inPack -> { finish(); return }
            a.recoveryCode() != null -> Step.KEY
            else -> Step.DONE
        }
    }
    val locate = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { next() }
    val notify = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) { Reminders.setEnabled(context, true); Reminders.schedule(context) }; next()
    }
    val signedIn = a.signedIn
    // Wer schon im Rudel ist: nach dem Anmelden (E-Mail) oder Beitreten (Link, QR-Code) abgleichen, dann ist der Hund da.
    // Während eine Einladung eingelöst wird, warten – sonst ginge es vor dem Abgleich mit leerem Profil weiter.
    LaunchedEffect(signedIn, a.joining) { if (signedIn && !a.joining && a.joinMessage == null && inPack && step == Step.PACK) afterSignIn() }
    // Ein Einladungslink, der während des Onboardings ankommt, führt direkt in diesen Schritt.
    LaunchedEffect(a.linkArrived) { if (a.linkArrived > 0) { inPack = true; step = Step.PACK } }
    val scan = rememberInviteScanner({ link -> packMessage = null; if (!a.open(link)) packMessage = L.t("Das ist keine Einladung von ThisDog.") }, { packMessage = it })
    BackHandler(step != Step.NAME && step != Step.DONE) { step = Step.entries[step.ordinal - 1] }

    val wish = when (step) { Step.NAME -> 300.dp; Step.DETAILS -> 220.dp; Step.WALKS, Step.REMINDERS -> 340.dp; Step.PACK -> 200.dp; Step.KEY -> 300.dp; Step.DONE -> 240.dp }
    val logoSide = minOf(wish, regionHeight - contentHeight - 28.dp)
    val shownSide by animateDpAsState(if (logoSide >= 90.dp) logoSide else 0.dp, label = "logo")

    Column(Modifier.fillMaxSize().background(p.soft).windowInsetsPadding(WindowInsets.safeDrawing), horizontalAlignment = Alignment.CenterHorizontally) {
        ProgressLeash((step.ordinal + 1f) / Step.entries.size, Modifier.fillMaxWidth().height(52.dp).padding(top = 8.dp))
        Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { regionHeight = with(density) { it.height.toDp() } }, contentAlignment = Alignment.BottomCenter) {
            // Stella liegt hinter dem Inhalt: Sie nimmt keinen Platz weg und lässt sich nicht antippen.
            if (shownSide >= 90.dp) StellaMark(typed.length + step.ordinal * 1000, Modifier.padding(bottom = 12.dp).size(shownSide))
            AnimatedContent(step, label = L.t("Schritt"), modifier = Modifier.fillMaxSize()) { s ->
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                    Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().padding(horizontal = 24.dp).padding(top = 24.dp).onSizeChanged { if (s == step) contentHeight = with(density) { it.height.toDp() } }, verticalArrangement = Arrangement.spacedBy(18.dp)) {
                        when (s) {
                            Step.NAME -> {
                                Head(if (typed.isEmpty()) L.t("Wie heißt dein Hund?") else L.t("Hallo, %1\$s!", typed))
                                Copy(L.t("Schön, dass ihr da seid. Der Rest geht schnell, und alles andere kannst du auch später eintragen."))
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    Box(Modifier.border(1.5.dp, p.accent.copy(alpha = .35f), androidx.compose.foundation.shape.CircleShape)) { AvatarPicker(Avatar.DOG, name, 64.dp, true, L.t("Foto auswählen")) }
                                    SoftField(name, { name = it }, L.t("Name"), Modifier.weight(1f), TextStyle(fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 24.sp))
                                }
                                Text(L.t("Wir sind schon in einem Rudel"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable { inPack = true; step = Step.PACK }.padding(vertical = 6.dp))
                            }
                            Step.DETAILS -> {
                                Head(L.t("Erzähl uns von %1\$s.", dog))
                                Copy(L.t("Damit Futtermenge, Ratgeber und Erinnerungen zu %1\$s passen. Ungefähr reicht.", dogAcc))
                                SoftField(breed, { breed = it }, L.t("Rasse, zum Beispiel Schnauzer"))
                                ReiterLeiste(listOf("f" to L.t("Hündin"), "m" to L.t("Rüde"), "" to L.t("Keine Angabe")), sex) { sex = it }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(L.t("Geburtstag bekannt"), color = p.ink, modifier = Modifier.weight(1f))
                                    Switch(knowsBirth, { knowsBirth = it }, colors = SwitchDefaults.colors(checkedTrackColor = p.accent))
                                }
                                if (knowsBirth) BirthRow(birth) { birth = it }
                            }
                            Step.WALKS -> {
                                Head(L.t("Zeit für eure erste Runde."))
                                Copy(L.t("ThisDog merkt sich euren Weg und zeigt dir Wiesen und Hundezonen in der Nähe. Dafür fragen wir gleich nach deinem Standort. Aufgezeichnet wird nur, wenn du eine Runde startest."))
                            }
                            Step.REMINDERS -> {
                                Head(L.t("Damit nichts untergeht."))
                                Copy(L.t("Impfung, Wurmkur, Tierarzt: ThisDog erinnert dich rechtzeitig. Dafür fragen wir gleich, ob wir dir Mitteilungen schicken dürfen."))
                            }
                            Step.PACK -> if (inPack) {
                                Head(L.t("Dann holen wir euch dazu."))
                                Copy(L.t("Scanne den QR-Code auf dem Telefon, das schon im Rudel ist, oder öffne den Einladungslink, den du bekommen hast."))
                                if (a.joining) JoiningNote()
                                (packMessage ?: a.joinMessage)?.let { Text(it, fontSize = 14.sp, color = p.health) }
                                if (withEmail || a.state is Account.State.LinkSent) SignInForm(L.t("Schon ein Konto mit E-Mail? Du bekommst einen Code, ein Passwort brauchst du nicht."))
                                else Text(L.t("Mit E-Mail anmelden"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable { withEmail = true }.padding(vertical = 6.dp))
                            } else {
                                Head(L.t("Wer kümmert sich noch um %1\$s?", dogAcc))
                                Copy(L.t("Partner, Eltern, Hundesitter: Im Rudel seht ihr alle dieselben Termine und Runden. Einladen geht mit einem QR-Code oder Link, ohne E-Mail und ohne Passwort.", dog))
                                inviteUrl?.let { InviteCard(it, inviteRole) }
                                packMessage?.let { Text(it, fontSize = 14.sp, color = p.health) }
                            }
                            Step.KEY -> {
                                Head(L.t("Falls alle Telefone weg sind."))
                                Copy(L.t("Eure Daten sind so verschlüsselt, dass nicht einmal wir sie lesen können. Darum gibt es einen Schlüssel, mit dem du jederzeit wieder an alles kommst. Heb ihn einmal gut auf."))
                                if (keySaved) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) { LineIcon(Sym.CHECK, p.accent, 20.dp); Text(L.t("Gesichert"), color = p.accent, fontWeight = FontWeight.SemiBold) }
                            }
                            Step.DONE -> {
                                Head(L.t("%1\$s wartet schon.", dog.replaceFirstChar { it.uppercase() }))
                                Copy(L.t("Zwei Dinge für später, wenn du magst:"))
                                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                    Hint(L.t("Notfallpass"), L.t("Ein QR-Code am Halsband, falls %1\$s einmal wegläuft. Du findest ihn im Reiter Hund.", dog))
                                    Hint(L.t("Neue Hundefreunde"), L.t("Spielt %1\$s auf der Wiese mit einem anderen Hund? Zeig unter Gassi im Reiter Freunde deinen QR-Code, dann seid ihr verbunden.", dog))
                                }
                            }
                        }
                    }
                }
            }
        }
        Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 16.dp).imePadding(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            @Composable fun later(go: () -> Unit) = Text(L.t("Später"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable(onClick = go).heightIn(min = 36.dp).padding(horizontal = 12.dp, vertical = 8.dp))
            when (step) {
                Step.NAME -> PrimaryButton(L.t("Weiter"), enabled = name.isNotBlank()) { next() }
                Step.DETAILS -> PrimaryButton(L.t("Weiter")) { next() }
                Step.WALKS -> { PrimaryButton(L.t("Standort erlauben")) { locate.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) }; later { next() } }
                Step.REMINDERS -> { PrimaryButton(L.t("Mitteilungen erlauben")) {
                    if (Build.VERSION.SDK_INT >= 33) notify.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else { Reminders.setEnabled(context, true); Reminders.schedule(context); next() }
                }; later { next() } }
                Step.PACK -> when {
                    inPack -> { PrimaryButton(L.t("QR-Code scannen"), enabled = !a.joining) { scan() }; later { inPack = false; step = Step.NAME } }
                    inviteUrl != null -> PrimaryButton(L.t("Weiter")) { step = if (a.recoveryCode() != null) Step.KEY else Step.DONE }
                    else -> {
                        PrimaryButton(L.t("Jemanden einladen"), enabled = !working) { choosesRole = true }
                        later { step = Step.DONE }
                    }
                }
                Step.KEY -> if (keySaved) PrimaryButton(L.t("Weiter")) { next() } else { PrimaryButton(L.t("Schlüssel ansehen")) { showKey = a.recoveryCode() ?: demoRecovery() }; later { next() } }
                Step.DONE -> PrimaryButton(L.t("Los geht's")) { finish() }
            }
        }
    }
    showKey?.let { code -> RecoveryDialog(code, onSaved = { keySaved = true }) { showKey = null } }
    if (choosesRole) RoleChoiceDialog({ choosesRole = false }) { role ->
        choosesRole = false; inviteRole = role; working = true; packMessage = null
        scope.launch {
            try { a.ensureOwnPack(); inviteUrl = a.invite(role).url } catch (e: Exception) { packMessage = Account.message(e) }
            working = false
        }
    }
}

/** Der Geburtstag: eine Zeile, die den Kalender des Systems öffnet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BirthRow(iso: String, onChange: (String) -> Unit) {
    val p = LocalPalette.current
    var open by remember { mutableStateOf(false) }
    val day = Day.parse(iso) ?: Day.today()
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.surface).clickable { open = true }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(L.t("Geboren am"), color = p.ink, modifier = Modifier.weight(1f))
        Text("${day.day}. ${Day.MONTH[day.month - 1]} ${day.year}", color = p.accent, fontWeight = FontWeight.SemiBold)
    }
    if (open) {
        val zone = java.time.ZoneOffset.UTC
        val state = rememberDatePickerState(day.date.atStartOfDay(zone).toInstant().toEpochMilli(), selectableDates = object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long) = utcTimeMillis <= System.currentTimeMillis()
        })
        DatePickerDialog({ open = false }, confirmButton = {
            TextButton({ state.selectedDateMillis?.let { onChange(java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate().toString()) }; open = false }) { Text(L.t("Fertig"), color = p.accent) }
        }, dismissButton = { TextButton({ open = false }) { Text(L.t("Abbrechen"), color = p.ink) } }) { DatePicker(state) }
    }
}

private fun demoRecovery(): String? = if (app.thisdog.BuildConfig.DEBUG) app.thisdog.crypto.RecoveryCode.encode(app.thisdog.crypto.Sealing.newKey()) else null

@Composable private fun Head(t: String) { val p = LocalPalette.current; Text(t, fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 34.sp, lineHeight = 40.sp, color = p.ink) }
@Composable private fun Copy(t: String) { val p = LocalPalette.current; Text(t, color = p.ink2, lineHeight = 23.sp) }
@Composable private fun Hint(head: String, text: String) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) { Text(head, fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 18.sp, color = p.ink); Text(text, fontSize = 15.sp, color = p.ink2) }
}

/** Anmelden: E-Mail, dann der Code aus der Mail. Auch im Rudel-Fenster. */
@Composable
fun SignInForm(intro: String) {
    val p = LocalPalette.current; val a = Graph.account; val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }; var code by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }; var working by remember { mutableStateOf(false) }
    fun run(work: suspend () -> Unit) { working = true; message = null; scope.launch { try { work() } catch (e: Exception) { message = Account.message(e) }; working = false } }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        val sentTo = (a.state as? Account.State.LinkSent)?.email ?: a.addingEmail
        when {
            sentTo != null -> {
                Text(L.t("Die Mail an %1\$s ist unterwegs. Gib den Code aus der Mail ein.", sentTo), color = p.ink2)
                SoftField(code, { v -> code = v.filter(Char::isDigit).take(6); if (code.length == 6) run { a.enterCode(code) } }, L.t("Code"),
                    textStyle = TextStyle(fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 34.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center), keyboard = KeyboardOptions(keyboardType = KeyboardType.Number))
                Text(L.t("Andere Adresse"), color = p.accent, modifier = Modifier.clickable { a.startOver() })
            }
            else -> {
                Text(intro, color = p.ink2, lineHeight = 23.sp)
                SoftField(email, { email = it }, L.t("E-Mail-Adresse"), keyboard = KeyboardOptions(keyboardType = KeyboardType.Email))
                PrimaryButton(L.t("Anmeldecode schicken"), enabled = !working && "@" in email) { run { a.requestLink(email.trim()) } }
            }
        }
        message?.let { Text(it, fontSize = 14.sp, color = p.health) }
    }
}

/** Zeigt den Wiederherstellungsschlüssel, zum Kopieren oder Ausdrucken. */
@Composable
fun RecoveryDialog(code: String, onSaved: () -> Unit, onDismiss: () -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        DialogBars()
        Column(Modifier.fillMaxSize().background(p.paper).statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Text(L.t("Fertig"), color = p.accent, fontWeight = FontWeight.SemiBold, modifier = Modifier.align(Alignment.End).clickable(onClick = onDismiss).padding(8.dp))
            Head(L.t("Falls alle Telefone weg sind"))
            Copy(L.t("Mit diesem Schlüssel kommst du wieder an die Termine, Impfungen und Runden deines Hundes. Heb ihn gut auf, am besten in deinem Passwortmanager oder ausgedruckt bei den Impfpapieren."))
            Text(code, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, fontWeight = FontWeight.Medium, color = p.ink, modifier = Modifier.fillMaxWidth().background(p.surface, RoundedCornerShape(16.dp)).padding(16.dp))
            Button({
                val clip = android.content.ClipData.newPlainText("ThisDog", code)
                // Android blendet den Inhalt in der Vorschau der Zwischenablage aus.
                clip.description.extras = android.os.PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
                context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(clip)
                copied = true; onSaved()
            }, Modifier.fillMaxWidth().height(50.dp), shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) { Text(if (copied) L.t("Kopiert") else L.t("Kopieren")) }
            OutlinedButton({ printCode(context, code); onSaved() }, Modifier.fillMaxWidth().height(50.dp), shape = RoundedCornerShape(50)) { Text(L.t("Ausdrucken"), color = p.accent) }
            Text(L.t("Niemand außer dir kann ihn ersetzen, auch wir nicht. Und wer ihn hat und in euer Konto kommt, kann eure Daten lesen. Zeig ihn also nur Menschen, denen du deinen Hund anvertrauen würdest."), fontSize = 13.sp, color = p.ink2)
        }
    }
}

private fun printCode(context: android.content.Context, code: String) {
    val web = android.webkit.WebView(context)
    web.webViewClient = object : android.webkit.WebViewClient() {
        override fun onPageFinished(view: android.webkit.WebView, url: String?) {
            val job = L.t("ThisDog Wiederherstellungsschlüssel")
            context.getSystemService(android.print.PrintManager::class.java).print(job, view.createPrintDocumentAdapter(job), null)
        }
    }
    web.loadDataWithBaseURL(null, "<h2>ThisDog: Wiederherstellungsschlüssel</h2><p style='font:18px monospace'>$code</p><p>Gut aufheben. Falls alle Telefone weg sind, kommst du damit wieder an die Daten deines Hundes.</p>", "text/html", "utf-8", null)
}

/** Der Fortschritt als Leine: Sie wächst von links nach rechts. */
@Composable
private fun ProgressLeash(progress: Float, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val shown by animateFloatAsState(progress, tween(500), label = L.t("Fortschritt"))
    Canvas(modifier) {
        val pad = 24.dp.toPx(); val w = size.width - 2 * pad; val mid = size.height / 2
        val pts = (0..28).map { i -> val u = i / 28f; Offset(pad + w * u, mid + (sin(u * 11) * 5 + sin(u * 4.3f + 1) * 6).dp.toPx()) }
        val whole = leashCurve(pts)
        drawPath(whole, p.accent.copy(alpha = .25f), style = Stroke(1.5.dp.toPx(), cap = StrokeCap.Round))
        val part = Path(); PathMeasure().apply { setPath(whole, false); getSegment(0f, length * shown, part, true) }
        drawPath(part, p.accent, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round))
    }
}
