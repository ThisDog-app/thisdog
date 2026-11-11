package app.thisdog.ui

import app.thisdog.i18n.L
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.thisdog.system.Reminders
import app.thisdog.system.SystemCalendar

/** Erinnerungen und Systemkalender ein- und ausschalten (wie CalendarSettings.swift). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CalendarSettings(onDismiss: () -> Unit) {
    val p = LocalPalette.current; val context = LocalContext.current
    var remindersOn by remember { mutableStateOf(Reminders.isEnabled(context)) }
    var calendarOn by remember { mutableStateOf(SystemCalendar.isEnabled(context)) }
    var refused by remember { mutableStateOf<String?>(null) }

    val notify = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        remindersOn = granted; Reminders.setEnabled(context, granted); Reminders.schedule(context)
        refused = if (granted) null else L.t("Mitteilungen sind für ThisDog ausgeschaltet. Einschalten unter Einstellungen › Apps › ThisDog › Benachrichtigungen.")
    }
    val calendar = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        val granted = r.values.all { it }
        calendarOn = granted; if (granted) SystemCalendar.enable(context)
        refused = if (granted) null else L.t("ThisDog hat keinen Zugriff auf den Kalender. Erlauben unter Einstellungen › Apps › ThisDog › Berechtigungen.")
    }

    fun setReminders(on: Boolean) {
        if (!on) { Reminders.setEnabled(context, false); remindersOn = false; return }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            notify.launch(Manifest.permission.POST_NOTIFICATIONS)
        else { Reminders.setEnabled(context, true); remindersOn = true; Reminders.schedule(context) }
    }
    fun setCalendar(on: Boolean) {
        if (!on) { SystemCalendar.disable(context); calendarOn = false; return }
        if (SystemCalendar.hasAccess(context)) { SystemCalendar.enable(context); calendarOn = true }
        else calendar.launch(arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR))
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Text(L.t("Erinnerungen und Kalender"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 28.sp, color = p.ink)
            Setting(L.t("Erinnerungen"), L.t("Ganztägige Termine um %1\$s Uhr am Tag selbst, Termine mit Uhrzeit eine Stunde vorher.", Reminders.ALL_DAY_HOUR), remindersOn, ::setReminders)
            Setting(L.t("Im Android-Kalender"), L.t("Deine Termine stehen dort in einem eigenen Kalender „%1\$s“ auf diesem Gerät. Ausschalten entfernt ihn wieder.", SystemCalendar.TITLE), calendarOn, ::setCalendar)
            refused?.let { Text(it, fontSize = 14.sp, color = p.ink2) }
        }
    }
}

@Composable
private fun Setting(title: String, footer: String, on: Boolean, onChange: (Boolean) -> Unit) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.weight(1f))
            Switch(on, onChange, colors = SwitchDefaults.colors(checkedTrackColor = p.accent))
        }
        Text(footer, fontSize = 14.sp, color = p.ink2)
    }
}
