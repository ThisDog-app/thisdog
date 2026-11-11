package app.thisdog.model

import app.thisdog.i18n.L
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Wie oft sich ein Termin wiederholt – dieselben Schlüssel wie in der iOS-Fassung und im Abgleich. */
enum class Repetition(val key: String, val label: String) {
    WEEKLY("weekly", L.t("Jede Woche")), BIWEEKLY("biweekly", L.t("Alle zwei Wochen")), MONTHLY("monthly", L.t("Jeden Monat")),
    QUARTERLY("quarterly", L.t("Alle drei Monate")), HALFYEARLY("halfyearly", L.t("Alle sechs Monate")), YEARLY("yearly", L.t("Jedes Jahr"));

    /** Der n-te Termin der Serie, immer vom Beginn aus gerechnet: So wandert der 31. nicht dauerhaft auf den 28. */
    fun step(start: Day, n: Int): Day = when (this) {
        WEEKLY -> start.addingDays(7 * n)
        BIWEEKLY -> start.addingDays(14 * n)
        MONTHLY -> start.addingMonths(n)
        QUARTERLY -> start.addingMonths(3 * n)
        HALFYEARLY -> start.addingMonths(6 * n)
        YEARLY -> start.addingYears(n)
    }

    companion object { fun of(key: String) = entries.firstOrNull { it.key == key } }
}

/** Ein eigener Termin (Art „event“). Leere Zeichenketten statt null, damit die Nutzlast gleich aussieht wie auf iOS. */
@Serializable
data class DogEvent(
    override val id: String = newID(),
    val title: String = "",
    val start: String = "",
    val end: String = "",
    val time: String = "",
    /** Ende „HH:mm“ am letzten Tag (oder am Beginntag); leer = keine Endzeit. Nur mit `time` von Bedeutung. */
    val endTime: String = "",
    val notes: String = "",
    val kind: String = "personal",
    @SerialName("repeat") val repetition: String = "",
    val repeatUntil: String = "",
    override val u: Double = 0.0,
) : SyncedItem {
    val startDay get() = Day.parse(start)
    val endDay get() = Day.parse(end)
    val untilDay get() = Day.parse(repeatUntil)
    val rule get() = Repetition.of(repetition)
    override fun stamped(u: Double) = copy(u = u)

    companion object {
        const val KIND = "event"
        /** Kennung im Format der Web-App: `evt_<Zeit base36><5 Zeichen>`. */
        fun newID(prefix: String = "evt"): String {
            val t = System.currentTimeMillis().toString(36)
            val r = (1..5).map { "abcdefghijklmnopqrstuvwxyz0123456789".random() }.joinToString("")
            return "${prefix}_$t$r"
        }
    }
}
