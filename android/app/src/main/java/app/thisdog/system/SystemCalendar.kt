package app.thisdog.system

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import androidx.core.content.ContextCompat
import app.thisdog.data.Graph
import app.thisdog.model.DogEvent
import app.thisdog.model.Repetition
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Trägt die eigenen Termine in einen eigenen Kalender „ThisDog“ im Systemkalender ein (wie SystemCalendar.swift).
 * Die App bleibt die Quelle: Sie legt an, ändert und löscht dort, was sie selbst eingetragen hat.
 * Der Kalender liegt nur auf diesem Gerät (lokales Konto); Serien werden als Serie eingetragen.
 */
object SystemCalendar {
    const val TITLE = "ThisDog"
    private const val ACCOUNT = "ThisDog"
    private const val PREFS = "kalender"

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun isEnabled(context: Context) = prefs(context).getBoolean("an", false) && hasAccess(context)
    fun hasAccess(context: Context) = listOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
        .all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    fun enable(context: Context) { prefs(context).edit().putBoolean("an", true).apply(); runCatching { sync(context) } }

    /** Schaltet aus und entfernt den Kalender „ThisDog“ samt Einträgen. */
    fun disable(context: Context) {
        prefs(context).edit().putBoolean("an", false).apply()
        if (hasAccess(context)) ownCalendar(context, create = false)?.let { context.contentResolver.delete(asSyncAdapter(ContentUris.withAppendedId(Calendars.CONTENT_URI, it)), null, null) }
        prefs(context).edit().remove("links").apply()
    }

    private fun asSyncAdapter(uri: Uri) = uri.buildUpon().appendQueryParameter(android.provider.CalendarContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(Calendars.ACCOUNT_NAME, ACCOUNT).appendQueryParameter(Calendars.ACCOUNT_TYPE, android.provider.CalendarContract.ACCOUNT_TYPE_LOCAL).build()

    private fun ownCalendar(context: Context, create: Boolean): Long? {
        val cr = context.contentResolver
        cr.query(Calendars.CONTENT_URI, arrayOf(Calendars._ID), "${Calendars.ACCOUNT_NAME} = ? AND ${Calendars.ACCOUNT_TYPE} = ?",
            arrayOf(ACCOUNT, android.provider.CalendarContract.ACCOUNT_TYPE_LOCAL), null)?.use { if (it.moveToFirst()) return it.getLong(0) }
        if (!create) return null
        val v = ContentValues().apply {
            put(Calendars.ACCOUNT_NAME, ACCOUNT); put(Calendars.ACCOUNT_TYPE, android.provider.CalendarContract.ACCOUNT_TYPE_LOCAL)
            put(Calendars.NAME, TITLE); put(Calendars.CALENDAR_DISPLAY_NAME, TITLE); put(Calendars.CALENDAR_COLOR, 0xFFEE6A24.toInt())
            put(Calendars.CALENDAR_ACCESS_LEVEL, Calendars.CAL_ACCESS_OWNER); put(Calendars.OWNER_ACCOUNT, ACCOUNT)
            put(Calendars.VISIBLE, 1); put(Calendars.SYNC_EVENTS, 1)
        }
        return cr.insert(asSyncAdapter(Calendars.CONTENT_URI), v)?.let { ContentUris.parseId(it) }
    }

    /** Bringt den Kalender „ThisDog“ auf den Stand der Termine. */
    fun sync(context: Context) {
        if (!isEnabled(context)) return
        val cal = ownCalendar(context, create = true) ?: return
        val cr = context.contentResolver
        val links = prefs(context).getString("links", "")!!.split(";").filter { it.contains("=") }
            .associate { it.substringBefore("=") to it.substringAfter("=").toLong() }.toMutableMap()
        val wanted = Graph.store.events.associateBy { it.id }
        for ((id, row) in links.toMap()) if (wanted[id] == null) { runCatching { cr.delete(ContentUris.withAppendedId(Events.CONTENT_URI, row), null, null) }; links.remove(id) }
        // Jeder Termin für sich: Lehnt der Kalender einen ab, bleiben die anderen, und die App stürzt nicht ab.
        for (ev in wanted.values) runCatching {
            val v = values(ev, cal) ?: return@runCatching
            val row = links[ev.id]
            val updated = row != null && cr.update(ContentUris.withAppendedId(Events.CONTENT_URI, row), v, null, null) > 0
            if (!updated) cr.insert(Events.CONTENT_URI, v)?.let { links[ev.id] = ContentUris.parseId(it) }
        }
        prefs(context).edit().putString("links", links.entries.joinToString(";") { "${it.key}=${it.value}" }).apply()
    }

    private fun values(ev: DogEvent, cal: Long): ContentValues? {
        val start = ev.startDay ?: return null
        return ContentValues().apply {
            put(Events.CALENDAR_ID, cal); put(Events.TITLE, ev.title); put(Events.DESCRIPTION, ev.notes.ifEmpty { null })
            val clock = Reminders.clock(ev.time)
            val zone = ZoneId.systemDefault()
            if (clock != null) {
                val begin = start.date.atTime(clock.first, clock.second)
                // Ende am letzten Tag zur Endzeit; ohne Endzeit (oder unsinnig) eine Stunde.
                val finish = Reminders.clock(ev.endTime)?.let { (h, m) -> (ev.endDay ?: start).date.atTime(h, m) }?.takeIf { it.isAfter(begin) } ?: begin.plusHours(1)
                val at = begin.atZone(zone).toInstant().toEpochMilli()
                val minutes = java.time.Duration.between(begin, finish).toMinutes()
                put(Events.ALL_DAY, 0); put(Events.DTSTART, at); put(Events.EVENT_TIMEZONE, zone.id)
                // Android verlangt genau eins von beiden; beim Ändern (Serie ↔ einzeln) bliebe das alte sonst stehen.
                if (ev.rule == null) { put(Events.DTEND, finish.atZone(zone).toInstant().toEpochMilli()); putNull(Events.DURATION) }
                else { put(Events.DURATION, "PT${minutes}M"); putNull(Events.DTEND) }
            } else {
                // Ganztägig verlangt Android Mitternacht in UTC und ein ausschließliches Ende.
                val from = start.date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
                val days = start.daysUntil(ev.endDay ?: start).coerceAtLeast(0) + 1
                put(Events.ALL_DAY, 1); put(Events.DTSTART, from); put(Events.EVENT_TIMEZONE, "UTC")
                if (ev.rule == null) { put(Events.DTEND, from + days * 86_400_000L); putNull(Events.DURATION) }
                else { put(Events.DURATION, "P${days}D"); putNull(Events.DTEND) }
            }
            ev.rule?.let { put(Events.RRULE, rrule(it, ev.untilDay)) } ?: putNull(Events.RRULE)
        }
    }

    fun rrule(r: Repetition, until: app.thisdog.model.Day?): String {
        val base = when (r) {
            Repetition.WEEKLY -> "FREQ=WEEKLY"; Repetition.BIWEEKLY -> "FREQ=WEEKLY;INTERVAL=2"
            Repetition.MONTHLY -> "FREQ=MONTHLY"; Repetition.QUARTERLY -> "FREQ=MONTHLY;INTERVAL=3"
            Repetition.HALFYEARLY -> "FREQ=MONTHLY;INTERVAL=6"; Repetition.YEARLY -> "FREQ=YEARLY"
        }
        // Das Ende der Serie gilt einschließlich: bis zum Ende dieses Tages.
        return until?.let { base + ";UNTIL=" + it.date.format(DateTimeFormatter.BASIC_ISO_DATE) + "T235959Z" } ?: base
    }
}
