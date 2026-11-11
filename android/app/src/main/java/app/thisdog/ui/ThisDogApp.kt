package app.thisdog.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import app.thisdog.data.Graph

/** Knopfhöhe, Innenabstand und der kleine Abstand nach unten. */
private val DOCK_BOTTOM = 46.dp + 10.dp + 6.dp
/** Quer die Spalte, in der die Leiste senkrecht steht. */
private val DOCK_END = 46.dp + 10.dp + 12.dp

@Composable
fun ThisDogApp(startTab: AppTab = AppTab.HEUTE, demoEmergency: Boolean = false, demoFriends: Boolean = false, forceOnboarding: Boolean = false, onboardingStep: Int = 0, demoSettings: Boolean = false) {
    ThisDogTheme {
        val startContext = androidx.compose.ui.platform.LocalContext.current
        val start = remember { startContext.getSharedPreferences("start", android.content.Context.MODE_PRIVATE) }
        // Einmal beim Start entschieden: Die Antwort darf sich nicht ändern, während jemand seinen Hund einträgt.
        var onboarding by rememberSaveable { mutableStateOf(forceOnboarding || (!start.getBoolean("fertig", false) && !Graph.store.hasProfile)) }
        // Telefon quer: Die Statusleiste kostet zu viel von der wenigen Höhe und kommt mit einem Wisch wieder.
        val quer = isQuer()
        val activity = startContext as? android.app.Activity
        LaunchedEffect(quer) {
            activity?.window?.let { w ->
                val c = androidx.core.view.WindowCompat.getInsetsController(w, w.decorView)
                c.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                if (quer) c.hide(androidx.core.view.WindowInsetsCompat.Type.statusBars()) else c.show(androidx.core.view.WindowInsetsCompat.Type.statusBars())
            }
        }
        if (onboarding) {
            OnboardingScreen(onboardingStep) { start.edit().putBoolean("fertig", true).apply(); onboarding = false }
            return@ThisDogTheme
        }
        val p = LocalPalette.current
        var tab by rememberSaveable { mutableStateOf(startTab) }
        var packOpen by remember { mutableStateOf(GassiDemo.rudel) }
        var emergencyOpen by remember { mutableStateOf(demoEmergency) }
        var settingsOpen by remember { mutableStateOf(demoSettings) }
        val links = app.thisdog.data.Graph.account.linkArrived
        LaunchedEffect(links) { if (links > 0) packOpen = true }
        val friendLinks = Graph.account.friendArrived
        LaunchedEffect(friendLinks) { if (friendLinks > 0) tab = AppTab.GASSI }
        // Ein Suchfeld behielte beim Wechsel des Bereichs sonst den Fokus, und die Tastatur bliebe stehen.
        val focus = androidx.compose.ui.platform.LocalFocusManager.current
        LaunchedEffect(tab) { focus.clearFocus(force = true) }
        val wide = LocalConfiguration.current.screenWidthDp >= 600
        LaunchedEffect(Unit) { Graph.account.refresh(); Graph.content.refresh() }
        // Wetter für die Hitzewarnung, sobald ein Standort da ist (und wenn man weit gefahren ist).
        val spot = app.thisdog.gassi.WalkRecorder.here ?: Graph.store.walks.maxByOrNull { it.start }?.coordinates?.firstOrNull()
        LaunchedEffect(spot?.let { String.format(java.util.Locale.US, "%.1f,%.1f", it.lat, it.lng) }) {
            // Auch ohne Ortswechsel alle halbe Stunde: Mittags wird es wärmer.
            while (spot != null) { app.thisdog.gassi.Heat.refresh(spot); kotlinx.coroutines.delay(30 * 60_000L) }
        }
        // Ohne Push (FCM fehlt noch) holt die App Änderungen im Rudel selbst: beim Zurückkehren und jede Minute,
        // solange sie sichtbar ist.
        val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
        LaunchedEffect(lifecycle) {
            lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.RESUMED) {
                while (true) { Graph.account.sync(); kotlinx.coroutines.delay(60_000) }
            }
        }
        // Erinnerungen und Systemkalender folgen jeder Änderung an Terminen, Gesundheit und Geburtstag.
        val context = androidx.compose.ui.platform.LocalContext.current
        val store = Graph.store
        // Das Widget folgt Runden, Gesundheit und Wetter.
        LaunchedEffect(store.walks, store.dues, app.thisdog.gassi.Heat.at) { app.thisdog.system.WeekWidget.refresh(context) }
        LaunchedEffect(store.events, store.profile, store.dues) {
            app.thisdog.system.Reminders.schedule(context)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { app.thisdog.system.SystemCalendar.sync(context) } }
        }
        val dock = if (quer) DockSpace(end = DOCK_END) else DockSpace(bottom = DOCK_BOTTOM)
        CompositionLocalProvider(LocalDock provides dock) {
            Box(Modifier.fillMaxSize().background(p.paper)) {
                // Die Karte reicht bis an alle Ränder, jede andere Seite endet vor der Leiste.
                val page = if (tab == AppTab.GASSI) Modifier.fillMaxSize()
                    else Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)).padding(end = dock.end)
                Box(page) {
                    when (tab) {
                        AppTab.HEUTE -> HomeScreen(wide, { tab = it }, { gassiUi.selected = it; tab = AppTab.GASSI }, { packOpen = true }, { settingsOpen = true }, { emergencyOpen = true })
                        AppTab.KALENDER -> CalendarScreen(wide)
                        AppTab.HUND -> DogScreen(wide, onPack = { packOpen = true }, onEmergency = { emergencyOpen = true })
                        AppTab.WISSEN -> KnowledgeScreen(wide)
                        AppTab.GASSI -> GassiScreen(onPack = { packOpen = true }, demoFriends = demoFriends)
                    }
                }
                when {
                    quer -> TabDock(tab, { tab = it }, Modifier.align(Alignment.CenterEnd).windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)).padding(end = 6.dp), vertical = true)
                    // Breit unter der rechten Hälfte, beim rechten Daumen, wenn sie dort hineinpasst. Sonst in der Mitte.
                    LocalConfiguration.current.screenWidthDp >= 760 -> Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 6.dp)) {
                        Spacer(Modifier.weight(1f))
                        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { TabDock(tab, { tab = it }) }
                    }
                    else -> TabDock(tab, { tab = it }, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 6.dp))
                }
            }
        }
        if (packOpen) PackScreen { packOpen = false }
        if (emergencyOpen) EmergencyScreen({ emergencyOpen = false }, { emergencyOpen = false; packOpen = true }, demo = demoEmergency)
        if (settingsOpen) SettingsScreen { settingsOpen = false }
    }
}
