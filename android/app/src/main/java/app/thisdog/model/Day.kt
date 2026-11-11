package app.thisdog.model

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * Ein Kalendertag ohne Uhrzeit und Zeitzone – so, wie ihn die Daten speichern („2026-10-17“).
 * Termine des Hundes sind Tage, keine Zeitpunkte; deshalb kein Zeitstempel im Modell (wie Day.swift).
 */
@JvmInline
value class Day(val date: LocalDate) : Comparable<Day> {
    constructor(year: Int, month: Int, day: Int) : this(LocalDate.of(year, month, day))

    val year get() = date.year
    val month get() = date.monthValue
    val day get() = date.dayOfMonth
    val iso: String get() = date.toString()

    override fun compareTo(other: Day) = date.compareTo(other.date)
    override fun toString() = iso

    fun addingDays(n: Int) = Day(date.plusDays(n.toLong()))
    /** Monate weiter; der 31. fällt in kürzeren Monaten auf deren letzten Tag (wie LocalDate). */
    fun addingMonths(n: Int) = Day(date.plusMonths(n.toLong()))
    fun addingYears(n: Int) = Day(date.plusYears(n.toLong()))
    fun daysUntil(other: Day) = ChronoUnit.DAYS.between(date, other.date).toInt()
    val firstOfMonth get() = Day(date.withDayOfMonth(1))
    /** Montag = 0 … Sonntag = 6. */
    val weekdayFromMonday get() = date.dayOfWeek.value - DayOfWeek.MONDAY.value

    val shortText: String get() = app.thisdog.i18n.L.t("%1\$s. %2\$s", day, MONTH_SHORT[month - 1])

    companion object {
        fun today() = Day(LocalDate.now())
        /** Liest „JJJJ-MM-TT“; alles andere ergibt null. */
        fun parse(iso: String?): Day? = runCatching { if (iso.isNullOrBlank()) null else Day(LocalDate.parse(iso)) }.getOrNull()
        fun daysIn(year: Int, month: Int) = java.time.YearMonth.of(year, month).lengthOfMonth()
        private fun symbols(style: java.time.format.TextStyle) = (1..12).map { java.time.Month.of(it).getDisplayName(style, app.thisdog.i18n.L.locale) }
        private fun weekdays(style: java.time.format.TextStyle) = DayOfWeek.entries.map { it.getDisplayName(style, app.thisdog.i18n.L.locale) }
        // Deutsch steht fest, damit es so bleibt, wie wir es wollen („Sep.“, „März“); andere Sprachen kommen aus dem System.
        val MONTH_SHORT get() = if (app.thisdog.i18n.L.isGerman) MONTH_SHORT_DE else symbols(java.time.format.TextStyle.SHORT_STANDALONE)
        val MONTH get() = if (app.thisdog.i18n.L.isGerman) MONTH_DE else symbols(java.time.format.TextStyle.FULL_STANDALONE)
        val WEEKDAY_SHORT get() = if (app.thisdog.i18n.L.isGerman) WEEKDAY_SHORT_DE else weekdays(java.time.format.TextStyle.SHORT_STANDALONE)
        private val MONTH_SHORT_DE = listOf("Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sep.", "Okt.", "Nov.", "Dez.")
        private val MONTH_DE = listOf("Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember")
        private val WEEKDAY_SHORT_DE = listOf("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")
    }
}
