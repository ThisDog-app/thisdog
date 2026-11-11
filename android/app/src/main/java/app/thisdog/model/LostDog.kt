package app.thisdog.model

import app.thisdog.data.EmergencySnapshot
import app.thisdog.i18n.L
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * Hund entlaufen (wie LostDog.swift): Der Notfallpass wird zum Steckbrief, das Rudel sieht es sofort,
 * und ein Text zum Teilen steht bereit.
 */
object LostDog {
    private val STAMP = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")

    /** „2026-11-09T14:30“ in Ortszeit – so liest es auch die Seite auf thisdog.app. */
    fun stamp(t: LocalDateTime = LocalDateTime.now()): String = t.format(STAMP)

    fun parse(s: String): LocalDateTime? = runCatching { LocalDateTime.parse(s, STAMP) }.getOrNull()
        ?: Day.parse(s.take(10))?.date?.atStartOfDay()

    /** „Seit heute, 14:30 Uhr · zuletzt gesehen: Augarten“ */
    fun since(lostSince: String, lostWhere: String, now: LocalDateTime = LocalDateTime.now()): String {
        val out = mutableListOf<String>()
        parse(lostSince)?.let { t ->
            val d = Day(t.toLocalDate()); val today = Day(now.toLocalDate())
            val day = when (d) {
                today -> L.t("heute")
                today.addingDays(-1) -> L.t("gestern")
                else -> "${Day.WEEKDAY_SHORT[d.weekdayFromMonday]}., ${d.shortText}"
            }
            out += L.t("Seit %1\$s, %2\$s Uhr", day, "%02d:%02d".format(t.hour, t.minute))
        }
        if (lostWhere.isNotEmpty()) out += L.t("zuletzt gesehen: %1\$s", lostWhere)
        return out.joinToString(" · ")
    }

    fun since(p: DogProfile, now: LocalDateTime = LocalDateTime.now()) = since(p.lostSince, p.lostWhere, now)

    /** Der Text zum Teilen. Kurz, das Wichtigste zuerst, die Nummer zum Antippen, der Link mit Foto am Ende. */
    fun flyer(s: EmergencySnapshot, url: String, now: LocalDateTime = LocalDateTime.now()): String {
        val facts = listOf(s.breed, s.sex, s.age).filter(String::isNotEmpty).joinToString(", ")
        val lines = mutableListOf(L.t("%1\$s wird vermisst!", s.name))
        val w = since(s.lostSince, s.lostWhere, now)
        if (w.isNotEmpty()) lines += w.replaceFirstChar { it.uppercase() } + "."
        if (facts.isNotEmpty()) lines += "$facts."
        if (s.lostNote.isNotEmpty()) lines += s.lostNote
        if (s.ownerPhone.isNotEmpty()) lines += L.t("Bitte sofort anrufen: %1\$s", listOf(s.ownerName, s.ownerPhone).filter(String::isNotEmpty).joinToString(", "))
        lines += L.t("Nicht hinterherrennen – ängstliche Hunde laufen sonst weiter weg.")
        lines += L.t("Foto und Chipnummer: %1\$s", url)
        return lines.joinToString("\n")
    }
}
