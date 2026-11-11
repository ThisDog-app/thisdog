package app.thisdog.gassi

import app.thisdog.i18n.L
import app.thisdog.model.Day
import app.thisdog.model.LatLng
import app.thisdog.model.SyncedItem
import app.thisdog.model.Track
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import kotlinx.serialization.Serializable

/**
 * Ein Check-in (wie CheckIn.swift): Datensatz im Rudel (Art „checkin“), Ende-zu-Ende verschlüsselt. Hundefreunde
 * bekommen ihn drei Stunden lang als eigenes, mit dem Schlüssel der Freundschaft verschlüsseltes Paket.
 */
@Serializable
data class CheckIn(
    override val id: String,
    val place: String,
    val name: String,
    val type: String,
    val lat: Double,
    val lon: Double,
    /** Zeitpunkt in Millisekunden seit 1970. */
    val at: Double,
    override val u: Double = 0.0,
) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    val coordinate get() = LatLng(lat, lon)
    val date: java.time.ZonedDateTime get() = Instant.ofEpochMilli(at.toLong()).atZone(ZoneId.systemDefault())

    companion object {
        const val KIND = "checkin"
        fun key(p: Place) = p.serverID ?: "${p.name}@${String.format(java.util.Locale.US, "%.4f,%.4f", p.lat, p.lon)}"
        fun of(p: Place, atMillis: Long = System.currentTimeMillis()) =
            CheckIn("chk_" + java.util.UUID.randomUUID().toString().replace("-", "").take(12), key(p), p.name, p.kind, p.lat, p.lon, atMillis.toDouble())
    }
}

object CheckIns {
    /** So nah muss man sein: Parks werden mit ihrer Mitte geführt, deshalb großzügig. */
    const val REACH = 300.0
    /** Unterwegs fragt die App, sobald man so nah an einem Ort ist. */
    const val PROMPT = 80.0
    /** Ein zweiter Check-in am selben Ort zählt erst nach zwei Stunden. */
    const val AGAIN_MS = 2 * 3600_000L

    fun inReach(p: Place, here: LatLng?) = here != null && Track.distance(here, p.coordinate) <= REACH
    fun recent(p: Place, all: List<CheckIn>, now: Long = System.currentTimeMillis()) =
        all.filter { it.place == CheckIn.key(p) && now - it.at < AGAIN_MS }.maxByOrNull { it.at }
    fun visits(p: Place, all: List<CheckIn>) = all.filter { it.place == CheckIn.key(p) }.sortedByDescending { it.at }

    /** „heute um 8:12“, „gestern“, „am Dienstag“, „am 3. Okt.“ */
    fun whenText(c: CheckIn, today: LocalDate = LocalDate.now()): String {
        val d = c.date; val day = Day(d.toLocalDate())
        return when (day.daysUntil(Day(today))) {
            0 -> L.t("heute um %d:%02d").format(d.hour, d.minute)
            1 -> "gestern"
            in 2..6 -> L.t("am ") + listOf(L.t("Montag"), L.t("Dienstag"), L.t("Mittwoch"), L.t("Donnerstag"), L.t("Freitag"), L.t("Samstag"), L.t("Sonntag"))[day.weekdayFromMonday]
            else -> L.t("am %1\$s", day.shortText)
        }
    }

    /** „Stellas Revier“, „Max’ Revier“. */
    fun revierTitle(name: String) = when {
        name.isEmpty() -> L.t("Revier")
        name.endsWith("s") || name.endsWith("x") || name.endsWith("z") -> L.t("%1\$s’ Revier", name)
        else -> L.t("%1\$ss Revier", name)
    }
}

/** Das Revier: besuchte Orte nach Besuchen, Abzeichen, die letzten Check-ins (wie Revier in CheckIn.swift). */
class Revier(all: List<CheckIn>, now: LocalDate = LocalDate.now()) {
    data class Spot(val place: String, val name: String, val type: String, val at: LatLng, val visits: Int, val last: Double)
    data class Badge(val id: String, val sym: String, val title: String, val detail: String)

    val spots: List<Spot> = all.groupBy { it.place }.values.map { list ->
        val last = list.maxBy { it.at }
        Spot(last.place, last.name, last.type, last.coordinate, list.size, last.at)
    }.sortedWith(compareByDescending<Spot> { it.visits }.thenByDescending { it.last })
    val recent = all.sortedByDescending { it.at }
    val total = all.size
    val badges: List<Badge>
    val next: Badge?

    init {
        val earned = mutableListOf<Badge>()
        var n: Badge? = null
        val top = spots.firstOrNull()
        if (top != null && top.visits >= 10) earned += Badge("stammgast", app.thisdog.ui.Sym.BADGE, L.t("Stammgast"), top.name)
        else if (top != null) n = Badge("stammgast", app.thisdog.ui.Sym.BADGE, L.t("Stammgast"), L.t("noch %1\$s Besuche in %2\$s", 10 - top.visits, top.name))
        if (spots.size >= 5) earned += Badge("entdecken", app.thisdog.ui.Sym.MAP, L.t("Auf Entdeckungstour"), L.t("%1\$s verschiedene Orte", spots.size))
        else if (n == null && spots.isNotEmpty()) n = Badge("entdecken", app.thisdog.ui.Sym.MAP, L.t("Auf Entdeckungstour"), L.t("noch %1\$s neue Orte", 5 - spots.size))
        val sundays = sundayStreak(all, now)
        if (sundays >= 4) earned += Badge("sonntag", app.thisdog.ui.Sym.SUN, L.t("Sonntagsrunde"), L.t("%1\$s Sonntage in Folge", sundays))
        badges = earned; next = n
    }

    companion object {
        /** Wie viele Sonntage in Folge (bis zum letzten Sonntag) es mindestens einen Check-in gab. */
        fun sundayStreak(all: List<CheckIn>, now: LocalDate): Int {
            val sundays = all.map { it.date.toLocalDate() }.filter { it.dayOfWeek == DayOfWeek.SUNDAY }.toSet()
            var day = now.with(TemporalAdjusters.previousOrSame(DayOfWeek.SUNDAY))
            if (day !in sundays) day = day.minusWeeks(1)
            var n = 0
            while (day in sundays) { n++; day = day.minusWeeks(1) }
            return n
        }
    }
}
