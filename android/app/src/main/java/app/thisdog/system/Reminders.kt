package app.thisdog.system

import app.thisdog.i18n.L
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.thisdog.MainActivity
import app.thisdog.R
import app.thisdog.data.Graph
import app.thisdog.model.CalendarBuilder
import app.thisdog.model.CalendarEntry
import app.thisdog.model.DogEvent
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Erinnerungen an Termine als Mitteilung auf dem Gerät – ohne Server, auch ohne Netz (wie Reminders.swift).
 * Geplant werden die nächsten 60 Vorkommen, neu bei jeder Änderung, bei jedem Start und nach dem Hochfahren.
 * Der Wecker darf ein paar Minuten später klingeln (Android bündelt im Ruhezustand); dafür braucht die App
 * kein Recht auf exakte Wecker.
 */
object Reminders {
    const val LIMIT = 60
    /** Ganztägige Termine: an diesem Tag um diese Uhrzeit. */
    const val ALL_DAY_HOUR = 8
    /** Termine mit Uhrzeit: so viele Minuten vorher. */
    const val LEAD_MINUTES = 60L
    private const val CHANNEL = "erinnerungen"
    private const val PREFS = "erinnerungen"

    fun isEnabled(context: Context) = prefs(context).getBoolean("an", false)
    fun setEnabled(context: Context, on: Boolean) { prefs(context).edit().putBoolean("an", on).apply(); if (!on) cancelAll(context) }
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** „09:30“ → (9, 30); leer oder ungültig → null. */
    fun clock(s: String): Pair<Int, Int>? {
        val p = s.split(":"); if (p.size != 2) return null
        val h = p[0].toIntOrNull() ?: return null; val m = p[1].toIntOrNull() ?: return null
        return if (h in 0..23 && m in 0..59) h to m else null
    }

    /** Wann an welches Vorkommen erinnert wird, aufsteigend; nur, was noch bevorsteht. */
    fun upcoming(events: List<DogEvent>, extra: List<CalendarEntry>, now: LocalDateTime): List<Pair<LocalDateTime, CalendarEntry>> {
        val today = app.thisdog.model.Day(now.toLocalDate())
        return (events.flatMap { CalendarBuilder.occurrences(it, today) } + extra).mapNotNull { e ->
            val at = clock(e.time)?.let { (h, m) -> e.start.date.atTime(h, m).minusMinutes(LEAD_MINUTES) } ?: e.start.date.atTime(ALL_DAY_HOUR, 0)
            if (at.isAfter(now)) at to e else null
        }.sortedBy { it.first }
    }

    fun body(e: CalendarEntry): String = clock(e.time)?.let { (h, m) -> L.t("Um %d:%02d Uhr").format(h, m) }
        ?: if (e.spanDays > 1) L.t("Ab heute, %1\$s Tage", e.spanDays) else L.t("Heute")

    /** Plant die nächsten Erinnerungen neu. */
    fun schedule(context: Context) {
        cancelAll(context)
        if (!isEnabled(context)) return
        val store = Graph.store
        val am = context.getSystemService(AlarmManager::class.java)
        val plan = upcoming(store.events, CalendarBuilder.dogEntries(store.profile, store.dues), LocalDateTime.now()).take(LIMIT)
        plan.forEachIndexed { i, (at, e) ->
            val intent = Intent(context, ReminderReceiver::class.java).putExtra("titel", e.title).putExtra("text", body(e)).putExtra("id", e.id)
                .putExtra("abhaken", e.id in store.markableDueIds)
            val pi = PendingIntent.getBroadcast(context, i, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli(), pi)
        }
        prefs(context).edit().putInt("geplant", plan.size).apply()
    }

    private fun cancelAll(context: Context) {
        val am = context.getSystemService(AlarmManager::class.java)
        repeat(prefs(context).getInt("geplant", LIMIT)) { i ->
            PendingIntent.getBroadcast(context, i, Intent(context, ReminderReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE)?.let { am.cancel(it); it.cancel() }
        }
        prefs(context).edit().putInt("geplant", 0).apply()
    }

    fun channel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) nm.createNotificationChannel(NotificationChannel(CHANNEL, L.t("Erinnerungen an Termine"), NotificationManager.IMPORTANCE_DEFAULT))
    }

    fun show(context: Context, id: String, title: String, text: String, doneable: Boolean = false) {
        channel(context)
        val open = PendingIntent.getActivity(context, id.hashCode(), Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val b = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.icon_hund).setColor(0xFFEE6A24.toInt())
            .setContentTitle(title).setContentText(text).setAutoCancel(true).setContentIntent(open).setCategory(Notification.CATEGORY_REMINDER)
        // Impfung und Entwurmung: gleich aus der Mitteilung abhaken, auch auf einer verbundenen Uhr.
        if (doneable) {
            val done = PendingIntent.getBroadcast(context, id.hashCode(), Intent(context, DoneReceiver::class.java).putExtra("id", id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            b.addAction(Notification.Action.Builder(null, L.t("Erledigt"), done).build())
        }
        context.getSystemService(NotificationManager::class.java).notify("erinnerung", id.hashCode(), b.build())
    }
}

/** „Erledigt“ an einer Erinnerung: abhaken, ohne die App zu öffnen. */
class DoneReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        Graph.init(context)
        Graph.store.markDone(id)
        WeekWidget.refresh(context)
        context.getSystemService(NotificationManager::class.java).cancel("erinnerung", id.hashCode())
        Reminders.schedule(context)
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Reminders.show(context, intent.getStringExtra("id") ?: return, intent.getStringExtra("titel") ?: return, intent.getStringExtra("text") ?: "",
            intent.getBooleanExtra("abhaken", false))
    }
}

/** Nach dem Hochfahren und nach einem Update sind geplante Wecker weg – also neu planen. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Graph.init(context)
        Reminders.schedule(context)
        // Ein Fehler im Systemkalender darf das Planen der Erinnerungen nicht mitreißen.
        runCatching { SystemCalendar.sync(context) }
    }
}
