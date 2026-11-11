package app.thisdog.model

import app.thisdog.i18n.L
import kotlinx.serialization.Serializable

/** Was im Kalender steht. Die Art bestimmt Farbe und Bezeichnung. */
enum class EntryKind(val label: String) {
    PERSONAL(L.t("Eigener Termin")), SEASONAL(L.t("Saisonaler Hinweis")), WARNING(L.t("Warnzeitraum")), BIRTHDAY(L.t("Geburtstag")), HEALTH(L.t("Gesundheit"))
}

/** Ein einzelnes Vorkommen im Kalender – ein eigener Termin, ein Teil einer Serie oder ein Hinweis. */
data class CalendarEntry(
    val id: String, val eventID: String?, val title: String, val start: Day, val end: Day, val time: String,
    val notes: String, val kind: EntryKind, val repetition: Repetition?, val tipSlug: String,
    /** Ende „HH:mm“ am letzten Tag; leer = keine Endzeit. */
    val endTime: String = "",
) {
    val isEditable get() = eventID != null
    val spanDays get() = start.daysUntil(end) + 1
    /** Ab dieser Länge ein Zeitraum (Zecken-Saison), kein Punkt an jedem Tag. */
    val isPeriod get() = spanDays > LONG_SPAN
    fun covers(day: Day) = start <= day && day <= end
    /** Der Titel ohne Emoji: Die Oberfläche zeigt Art und Farbe selbst. */
    val plainTitle get() = buildString {
        title.codePoints().forEach { c -> if (c !in 0x1F000..0x1FAFF && c !in 0x2600..0x27BF && c != 0xFE0F && c != 0x200D) appendCodePoint(c) }
    }.trim()

    /** „10:00–11:00 Uhr“ am selben Tag, „10:00 Uhr“ ohne Ende; über mehrere Tage nur der Beginn. Null, wenn ganztägig. */
    val timeText: String? get() {
        val a = NextUp.clock(time) ?: return null
        val b = NextUp.clock(endTime)
        return if (b != null && spanDays == 1) L.t("%1\$s–%2\$s Uhr", clockText(a), clockText(b)) else L.t("%1\$s Uhr", clockText(a))
    }

    /** Wann der Termin ist, ausgeschrieben: „Fr 14. Nov., 10:00–11:00 Uhr“ oder „Fr 14. Nov., 18:00 – So 16. Nov., 12:00 Uhr“. */
    val whenText: String get() {
        val from = dayText(start)
        val a = NextUp.clock(time) ?: return from
        if (spanDays == 1) return "$from, $timeText"
        val b = NextUp.clock(endTime) ?: return L.t("%1\$s, %2\$s Uhr – %3\$s", from, clockText(a), dayText(end))
        return L.t("%1\$s, %2\$s – %3\$s, %4\$s Uhr", from, clockText(a), dayText(end), clockText(b))
    }

    /** Knapp für Listen: „bis So 16. Nov., 12:00“ bei Zeit über mehrere Tage, sonst „bis 16. Nov.“; null bei einem Tag. */
    val untilText: String? get() {
        if (spanDays <= 1) return null
        val b = NextUp.clock(endTime)
        return if (NextUp.clock(time) != null && b != null) L.t("bis %1\$s, %2\$s", dayText(end), clockText(b)) else L.t("bis %1\$s", end.shortText)
    }

    companion object {
        const val LONG_SPAN = 7
        fun clockText(c: Pair<Int, Int>) = "%d:%02d".format(c.first, c.second)
        fun dayText(d: Day) = "${Day.WEEKDAY_SHORT[d.weekdayFromMonday]} ${d.shortText}"
    }
}

/** Ein Hinweis aus `public_events.json`. Dort zählt „end“ ausschließlich (wie FullCalendar es verlangte). */
@Serializable
data class SeasonalHint(
    val title: String, val start: String, val end: String? = null, val notes: String? = null,
    val classNames: List<String>? = null, val tipSlug: String? = null,
) {
    val entry: CalendarEntry? get() {
        val s = Day.parse(start) ?: return null
        val e = end?.let { Day.parse(it)?.addingDays(-1) } ?: s
        val warning = classNames?.contains("fc-event-warning") == true
        return CalendarEntry("pub_${title}_$start", null, title, s, maxOf(s, e), "", notes ?: "",
            if (warning) EntryKind.WARNING else EntryKind.SEASONAL, null, tipSlug ?: "")
    }
}

/** Löst Termine in Vorkommen auf und sammelt alles, was der Kalender zeigt (wie CalendarBuilder in Swift). */
object CalendarBuilder {
    const val MONTHS_BACK = 12
    const val MONTHS_AHEAD = 24
    const val MAX_OCCURRENCES = 300

    /** Das erste Vorkommen bleibt immer, damit der Beginn einer Serie sichtbar ist. */
    fun occurrences(ev: DogEvent, today: Day = Day.today()): List<CalendarEntry> {
        val start = ev.startDay ?: return emptyList()
        val span = ev.endDay?.let { maxOf(0, start.daysUntil(it)) } ?: 0
        fun entry(s: Day, n: Int) = CalendarEntry(
            if (n == 0 && ev.rule == null) ev.id else "${ev.id}#$n", ev.id, ev.title, s, s.addingDays(span),
            ev.time, ev.notes, EntryKind.PERSONAL, ev.rule, "", if (ev.time.isEmpty()) "" else ev.endTime)
        val rule = ev.rule ?: return listOf(entry(start, 0))
        val from = today.firstOfMonth.addingMonths(-MONTHS_BACK)
        val last = today.firstOfMonth.addingMonths(MONTHS_AHEAD)
        val to = Day(last.year, last.month, Day.daysIn(last.year, last.month))
        val until = ev.untilDay
        val out = mutableListOf<CalendarEntry>()
        // Eine lange laufende Serie (wöchentlich seit Jahren) erreichte das Fenster sonst nie innerhalb von
        // MAX_OCCURRENCES Schritten: Gezählt wird ab dem ersten Vorkommen im Fenster, die Nummern bleiben dieselben.
        // Der erste Termin der Serie bleibt trotzdem (wie in CalendarEntry.swift).
        val skip = firstStep(rule, start, from)
        if (skip > 0) {
            if (until != null && start > until) return out
            out += entry(start, 0)
        }
        for (n in skip until skip + MAX_OCCURRENCES) {
            val d = rule.step(start, n)
            if (d > to) break
            if (until != null && d > until) break
            if (n == 0 || d >= from) out += entry(d, n)
        }
        return out
    }

    /** Die kleinste Nummer, deren Vorkommen nicht vor `from` liegt (die Schritte wachsen mit der Nummer). */
    fun firstStep(rule: Repetition, start: Day, from: Day): Int {
        if (rule.step(start, 0) >= from) return 0
        var lo = 0; var hi = 1
        // Weiter als 1 shl 20 Schritte (20.000 Jahre wöchentlich) sucht niemand.
        while (rule.step(start, hi) < from && hi < (1 shl 20)) { lo = hi; hi *= 2 }
        while (lo + 1 < hi) {
            val mid = (lo + hi) / 2
            if (rule.step(start, mid) < from) lo = mid else hi = mid
        }
        return hi
    }

    /** Geburtstag (dieses und nächstes Jahr) und Fälligkeiten aus den Gesundheitsdaten. */
    fun dogEntries(profile: DogProfile, dues: List<HealthDue>, today: Day = Day.today()): List<CalendarEntry> {
        val out = mutableListOf<CalendarEntry>()
        val b = profile.birthDay
        if (b != null && profile.name.isNotEmpty()) {
            for (year in listOf(today.year, today.year + 1)) if (year > b.year) {
                val d = Day(year, b.month, minOf(b.day, Day.daysIn(year, b.month)))
                out += CalendarEntry("bday_$year", null, L.t("%1\$s wird %2\$s", profile.name, year - b.year), d, d, "", "", EntryKind.BIRTHDAY, null, "")
            }
        }
        for (due in dues) {
            val title = if (due.kind == L.t("Medikament endet")) L.t("%1\$s endet", due.title) else L.t("%1\$s fällig: %2\$s", due.kind, due.title)
            out += CalendarEntry(due.id, null, title, due.due, due.due, "", "", EntryKind.HEALTH, null, "")
        }
        return out
    }

    fun all(events: List<DogEvent>, seasonal: List<SeasonalHint>, today: Day = Day.today()): List<CalendarEntry> =
        (events.flatMap { occurrences(it, today) } + seasonal.mapNotNull { it.entry })
            .sortedWith(compareBy({ it.start }, { it.time }, { it.title }))
}
