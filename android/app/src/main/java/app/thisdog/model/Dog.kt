package app.thisdog.model

import app.thisdog.i18n.L
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.Transient

/** Das Profil des Hundes – ein Datensatz (Art „profile“, Kennung „profile“), Felder wie auf iOS. */
@Serializable
data class DogProfile(
    val name: String = "",
    val breed: String = "",
    /** „JJJJ-MM-TT“ */
    val birthdate: String = "",
    val chip: String = "",
    /** „f“ Hündin, „m“ Rüde, leer: keine Angabe. */
    val sex: String = "",
    val weightKg: Double? = null,
    val targetWeightKg: Double? = null,
    val activity: String = "normal",
    val neutered: Boolean = false,
    val vetName: String = "",
    val vetPhone: String = "",
    val allergies: String = "",
    val ownerName: String = "",
    val ownerPhone: String = "",
    val tracker: Boolean = false,
    /** Entlaufen: seit wann („JJJJ-MM-TTTHH:MM“, Ortszeit; leer = alles gut), wo zuletzt gesehen, was ein Finder wissen sollte. */
    val lostSince: String = "",
    val lostWhere: String = "",
    val lostNote: String = "",
    override val u: Double = 0.0,
) : SyncedItem {
    @Transient override val id: String = "profile"
    override fun stamped(u: Double) = copy(u = u)

    val isLost get() = lostSince.isNotEmpty()

    val birthDay get() = Day.parse(birthdate)
    val sexLabel get() = when (sex) { "f" -> L.t("Hündin"); "m" -> L.t("Rüde"); else -> null }

    /** „3 Jahre, 4 Monate“ */
    fun age(today: Day = Day.today()): String? {
        val b = birthDay ?: return null
        var months = (today.year - b.year) * 12 + (today.month - b.month)
        if (today.day < b.day) months -= 1
        if (months < 0) return null
        val y = months / 12; val m = months % 12
        val mt = if (m == 1) L.t("1 Monat") else L.t("%1\$s Monate", m)
        if (y == 0) return mt
        val yt = if (y == 1) L.t("1 Jahr") else L.t("%1\$s Jahre", y)
        return if (m == 0) yt else "$yt, $mt"
    }

    /** Lebensphase: große Hunde altern früher. */
    fun stage(today: Day = Day.today()): String? {
        val b = birthDay ?: return null
        val months = b.daysUntil(today) / 30.44
        if (months < 12) return L.t("Welpe")
        val w = weightKg ?: 0.0
        val seniorAt = when { w >= 40 -> 72.0; w >= 25 -> 84.0; w >= 0.1 -> 108.0; else -> 96.0 }
        return if (months >= seniorAt) L.t("Senior") else L.t("Erwachsen")
    }

    companion object {
        const val KIND = "profile"
        val ACTIVITIES = listOf("low" to L.t("Ruhig, kurze Runden"), "normal" to L.t("Normal, täglich unterwegs"), "high" to L.t("Sehr aktiv, Sport und lange Touren"))
    }

    /** Übernimmt die Felder, die `draft` gegenüber `base` geändert hat – alles andere bleibt, wie es jetzt ist. */
    fun applying(draft: DogProfile, base: DogProfile): DogProfile {
        val ser = DogProfile.serializer()
        val now = app.thisdog.data.ThisDogJson.encodeToJsonElement(ser, this).jsonObject
        val b = app.thisdog.data.ThisDogJson.encodeToJsonElement(ser, base).jsonObject
        val d = app.thisdog.data.ThisDogJson.encodeToJsonElement(ser, draft).jsonObject
        val out = now.toMutableMap()
        for (key in b.keys + d.keys) if (key != "u" && b[key] != d[key]) { val v = d[key]; if (v != null) out[key] = v else out.remove(key) }
        return app.thisdog.data.ThisDogJson.decodeFromJsonElement(ser, kotlinx.serialization.json.JsonObject(out)).copy(u = u)
    }
}

/** Ein Eintrag im Gewichtsverlauf. Je Tag einer; die Kennung ist der Tag. */
@Serializable
data class WeightEntry(val d: String, val kg: Double, override val u: Double = 0.0) : SyncedItem {
    override val id get() = d
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "weight" }
}

@Serializable
data class Vaccination(override val id: String, val name: String = "", val date: String = "", val next: String = "",
                       val notes: String = "", override val u: Double = 0.0) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "vaccinations" }
}

@Serializable
data class Deworming(override val id: String, val product: String = "", val date: String = "", val next: String = "",
                     override val u: Double = 0.0) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "deworming" }
}

@Serializable
data class Medication(override val id: String, val name: String = "", val dose: String = "", val from: String = "",
                      val to: String = "", override val u: Double = 0.0) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "meds" }
}

/**
 * Ein Eintrag im Gesundheitstagebuch: was auffiel und wann, auf Wunsch mit Foto (wie HealthNote in Swift).
 * Fehlende Felder sind leer – die Vorgaben greifen beim Lesen.
 */
@Serializable
data class HealthNote(
    override val id: String = newHealthID("notes"),
    /** „JJJJ-MM-TT“ */
    val d: String = Day.today().iso,
    /** „HH:mm“ oder leer */
    val time: String = "",
    val tags: List<String> = emptyList(),
    val text: String = "",
    /** Kleines JPEG als Base64. */
    val photo: String? = null,
    override val u: Double = 0.0,
) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    val day get() = Day.parse(d)
    val headline get() = if (tags.isEmpty()) text.ifEmpty { L.t("Notiz") } else tags.joinToString(", ")

    companion object {
        const val KIND = "notes"
        val PRESETS get() = listOf(L.t("Erbrochen"), L.t("Durchfall"), L.t("Frisst nicht"), L.t("Humpelt"), L.t("Juckreiz"),
            L.t("Husten"), L.t("Zecke"), L.t("Verletzung"), L.t("Schlapp"))

        /** „Heute, 07:40 Uhr“, „Gestern“, „24. Okt.“ */
        fun whenText(n: HealthNote, today: Day = Day.today()): String {
            val day = n.day?.let { if (it == today) L.t("Heute") else if (it == today.addingDays(-1)) L.t("Gestern") else it.shortText } ?: ""
            return if (n.time.isEmpty()) day else L.t("%1\$s, %2\$s Uhr", day, n.time)
        }

        /** Für den Tierarzt: die letzten zwölf Monate, älteste zuerst – so liest man einen Verlauf. */
        fun vetSummary(notes: List<HealthNote>, dog: String, today: Day = Day.today()): String {
            val since = today.addingMonths(-12)
            val lines = notes.filter { (it.day ?: today) >= since }.sortedWith(compareBy({ it.d }, { it.time })).map { n ->
                val date = n.day?.let { "%02d.%02d.%04d".format(it.day, it.month, it.year) } ?: n.d
                val head = listOf(date, n.time).filter(String::isNotEmpty).joinToString(" ")
                val what = listOf(n.tags.joinToString(", "), n.text).filter(String::isNotEmpty).joinToString(": ")
                "$head – $what" + if (n.photo == null) "" else L.t(" (Foto in der App)")
            }
            val name = dog.ifEmpty { L.t("meinem Hund") }
            return (listOf(L.t("Gesundheitstagebuch von %1\$s", name), "") + lines).joinToString("\n")
        }
    }
}

/** Eine Fälligkeit aus den Gesundheitsdaten: wann zuletzt, wann wieder. */
data class HealthDue(val id: String, val title: String, val kind: String, val last: Day?, val due: Day) {
    /** Wie viel vom Abstand zwischen letztem Mal und Fälligkeit vergangen ist (0…1); null ohne letztes Datum. */
    fun progress(today: Day = Day.today()): Double? {
        val l = last ?: return null
        if (l >= due) return null
        return (l.daysUntil(today).toDouble() / l.daysUntil(due)).coerceIn(0.0, 1.0)
    }
}

fun newHealthID(prefix: String) = DogEvent.newID(prefix)
