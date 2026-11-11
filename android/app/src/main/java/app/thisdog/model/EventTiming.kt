package app.thisdog.model

import java.time.Duration
import java.time.LocalDateTime
import java.time.temporal.ChronoUnit

/**
 * Beginn und Ende im Termin-Editor, wie im Kalender von Apple: ganztägig oder mit Uhrzeiten,
 * über einen oder mehrere Tage. Rechnet in ganzen Zeitpunkten und legt erst beim Sichern
 * auf die Felder des Termins um (start, end, time, endTime).
 */
data class EventTiming(val allDay: Boolean, val begin: LocalDateTime, val finish: LocalDateTime) {
    /** Neuer Beginn: Das Ende wandert mit und die Dauer bleibt. */
    fun movingBegin(to: LocalDateTime) = copy(begin = to, finish = to.plus(Duration.between(begin, finish)))

    /** Ganztägig zählen nur die Tage, sonst die Zeitpunkte. */
    val isValid get() = if (allDay) !finish.toLocalDate().isBefore(begin.toLocalDate()) else !finish.isBefore(begin)

    /** Legt Beginn und Ende auf den Termin um; das Gegenstück zu [of]. */
    fun applied(ev: DogEvent): DogEvent {
        val startDay = begin.toLocalDate(); val endDay = finish.toLocalDate()
        val end = if (endDay.isAfter(startDay)) endDay.toString() else ""
        if (allDay) return ev.copy(start = startDay.toString(), end = end, time = "", endTime = "")
        return ev.copy(start = startDay.toString(), end = end, time = hhmm(begin), endTime = if (finish != begin) hhmm(finish) else "")
    }

    companion object {
        private fun hhmm(t: LocalDateTime) = "%02d:%02d".format(t.hour, t.minute)

        /** Die nächste volle Stunde ab jetzt. */
        fun nextHour(now: LocalDateTime) = now.truncatedTo(ChronoUnit.HOURS).plusHours(1)

        /**
         * Neu: mit Uhrzeit, Beginn zur nächsten vollen Stunde am Tag des Termins, Ende eine Stunde später.
         * Vorhanden: ganztägig, wenn keine Uhrzeit; Ende am letzten Tag zur Endzeit, sonst über mehrere Tage zur Uhrzeit
         * des Beginns und an einem Tag eine Stunde nach Beginn.
         */
        fun of(ev: DogEvent, isNew: Boolean, now: LocalDateTime = LocalDateTime.now()): EventTiming {
            val next = nextHour(now)
            val day = (ev.startDay ?: Day(now.toLocalDate())).date
            if (isNew) {
                // Nach 23 Uhr rutscht die nächste volle Stunde auf den Folgetag.
                val begin = day.plusDays(ChronoUnit.DAYS.between(now.toLocalDate(), next.toLocalDate())).atTime(next.toLocalTime())
                return EventTiming(false, begin, begin.plusHours(1))
            }
            val clock = NextUp.clock(ev.time)
            val begin = clock?.let { (h, m) -> day.atTime(h, m) } ?: day.atTime(next.toLocalTime())
            val lastDay = ev.endDay?.date?.takeIf { !it.isBefore(day) } ?: day
            val finish = NextUp.clock(ev.endTime)?.takeIf { clock != null }?.let { (h, m) -> lastDay.atTime(h, m) }
                // Über mehrere Tage ohne Endzeit (ältere Einträge): am letzten Tag zur Uhrzeit des Beginns, wie auf iOS.
                ?: lastDay.atTime(begin.toLocalTime()).takeIf { lastDay.isAfter(day) }
                ?: lastDay.atTime(begin.toLocalTime()).plusHours(1).let { f ->
                    // Die Stunde danach darf nicht auf einen weiteren Tag springen, sonst wüchse der Termin beim bloßen Sichern.
                    if (f.toLocalDate().isAfter(lastDay)) lastDay.atTime(23, 59) else f
                }
            return EventTiming(clock == null, begin, finish)
        }
    }
}
