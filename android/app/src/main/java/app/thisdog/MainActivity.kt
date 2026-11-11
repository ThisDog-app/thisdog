package app.thisdog

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import app.thisdog.data.Graph
import app.thisdog.ui.AppTab
import app.thisdog.ui.ThisDogApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Graph.init(this)
        app.thisdog.gassi.WalkRecorder.init(this)
        if (BuildConfig.DEBUG && intent.getBooleanExtra("beispiel", false)) Beispiel.seed(Graph.store)
        if (BuildConfig.DEBUG) {
            if (intent.getBooleanExtra("revier", false)) Beispiel.seedCheckIns(Graph.store)
            if (intent.getBooleanExtra("vermisst", false)) Beispiel.seedLost(Graph.store)
            app.thisdog.ui.GassiDemo.rudel = intent.getBooleanExtra("rudel", false)
            if (intent.getBooleanExtra("rudeldemo", false)) Graph.account.demoPack()
            app.thisdog.ui.GassiDemo.bewertet = intent.getBooleanExtra("bewertet", false)
            app.thisdog.ui.GassiDemo.orte = intent.getBooleanExtra("orte", false)
            app.thisdog.ui.GassiDemo.ortseite = intent.getBooleanExtra("ortseite", false)
            app.thisdog.ui.GassiDemo.revierAnsicht = intent.getBooleanExtra("revieransicht", false)
            app.thisdog.ui.GassiDemo.erkunder = intent.getBooleanExtra("erkunder", false)
            // Zum Ansehen: Gassi mit bestimmtem Reiter und Blatt, eine eben beendete oder angetippte Runde.
            intent.getStringExtra("reiter")?.let { app.thisdog.ui.GassiDemo.reiter = it }
            intent.getStringExtra("stufe")?.let { app.thisdog.ui.GassiDemo.stufe = it }
            app.thisdog.ui.GassiDemo.fertig = intent.getBooleanExtra("fertig", false)
            intent.getStringExtra("hitze")?.toDoubleOrNull()?.let { app.thisdog.gassi.Heat.demo(it) }
            app.thisdog.ui.GassiDemo.rundekarte = intent.getBooleanExtra("rundekarte", false)
            // Wie auf iOS `-runde`: eine laufende Runde, die Ortung kommt aus dem Emulator (Berechtigung vorher mit adb erteilen).
            if (intent.getBooleanExtra("runde", false) && app.thisdog.gassi.WalkRecorder.phase == app.thisdog.gassi.WalkRecorder.Phase.IDLE && app.thisdog.gassi.WalkRecorder.hasPermission(this)) app.thisdog.gassi.WalkRecorder.start(this)
            intent.getStringExtra("hundreiter")?.let { app.thisdog.ui.DogDemo.reiter = it }
            app.thisdog.ui.KnowledgeDemo.ratgeber = intent.getBooleanExtra("ratgeber", false)
            intent.getStringExtra("suche")?.let { app.thisdog.ui.KnowledgeDemo.suche = it }
            app.thisdog.ui.HomeDemo.stupsen = intent.getBooleanExtra("stupsen", false)
            app.thisdog.ui.OnboardingDemo.name = intent.getStringExtra("hundname") ?: ""
        }
        // Für Bildschirmfotos: ein Foto aus dem eigenen Ordner der App als Bild des Hundes (`--es hundefoto <Dateiname>`).
        if (BuildConfig.DEBUG) intent.getStringExtra("hundefoto")?.let { name ->
            java.io.File(getExternalFilesDir(null), name).takeIf { it.exists() }?.readBytes()?.let(app.thisdog.ui.AvatarImage::prepare)
                ?.let { Graph.store.upsert(app.thisdog.data.Kinds.avatar, app.thisdog.model.Avatar(app.thisdog.model.Avatar.DOG, it)) }
        }
        val tab = intent.getStringExtra("tab")?.let { t -> AppTab.entries.firstOrNull { it.name.equals(t, true) } }             // Läuft noch eine Runde, geht es dort weiter.
            ?: if (app.thisdog.gassi.WalkRecorder.phase != app.thisdog.gassi.WalkRecorder.Phase.IDLE) AppTab.GASSI else AppTab.HEUTE
        val demoEmergency = BuildConfig.DEBUG && intent.getBooleanExtra("notfall", false)
        val demoFriends = BuildConfig.DEBUG && intent.getBooleanExtra("freunde", false)
        val forceOnboarding = BuildConfig.DEBUG && intent.getBooleanExtra("onboarding", false)
        val step = intent.getIntExtra("schritt", 0)
        val demoSettings = BuildConfig.DEBUG && intent.getBooleanExtra("einstellungen", false)
        setContent { ThisDogApp(tab, demoEmergency, demoFriends, forceOnboarding, step, demoSettings) }
        // Nur beim ersten Start: Nach Drehen oder Wiederherstellen und beim Öffnen aus den letzten Apps trüge das alte
        // Intent den Link noch einmal herein – eine Einladung würde dann ein zweites Mal eingelöst.
        val fromHistory = intent.flags and android.content.Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) handleLink(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        handleLink(intent)
    }

    /**
     * thisdog.app/anmelden/…, /rudel/…#k=…, /freund/…#k=… – der Schlüssel hinter dem # erreicht den Server nie.
     * Kommt der Link über den Knopf auf thisdog.app/rudel (intent://), fehlt das # – der Schlüssel reist dann als Zusatz „k“.
     */
    private fun handleLink(intent: android.content.Intent?) {
        val uri = intent?.data ?: return
        if (uri.host != "thisdog.app") return
        val fragment = uri.fragment ?: intent.getStringExtra("k")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{20,64}")) }?.let { "k=$it" }
        Graph.account.open(uri.path ?: return, fragment)
    }
}
