package app.thisdog.model

import app.thisdog.i18n.L
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double

/** Ein Tipp aus `tips.json`. */
@Serializable
data class Tip(
    val id: Int, val slug: String, val title: String, val category: String,
    val tags: List<String>? = null, val age: List<String>? = null, val season: List<String>? = null,
    val media: List<Media>? = null, val content: String, val checklist: List<String>? = null,
) {
    @Serializable data class Media(val src: String, val alt: String? = null)
    /** `img/tips/hitze-1.png` → `hitze-1`; auf dem Server liegen die Bilder als `w900/<name>.webp`. */
    val imageName get() = media?.firstOrNull()?.src?.substringAfterLast('/')?.substringBefore('.')
    val remoteImage get() = imageName?.let { "https://thisdog.app/img/tips/w900/$it.webp" }
    /** Lesezeit bei 200 Wörtern je Minute. */
    val minutes get() = maxOf(1, Math.round(content.split(Regex("\\s+")).size / 200.0).toInt())
}

enum class Season(val key: String, val label: String) {
    SPRING("spring", L.t("Frühling")), SUMMER("summer", L.t("Sommer")), AUTUMN("autumn", L.t("Herbst")), WINTER("winter", L.t("Winter"));
    companion object {
        fun of(d: Day) = when (d.month) { 12, 1, 2 -> WINTER; in 3..5 -> SPRING; in 6..8 -> SUMMER; else -> AUTUMN }
        fun byKey(k: String) = entries.firstOrNull { it.key == k }
    }
}

object TipRanking {
    /** Jahreszeit +3, Lebensphase +1, ganzjährig +0,5. */
    fun score(t: Tip, season: Season, stage: String?): Double {
        var s = 0.0
        if (t.season?.contains(season.key) == true) s += 3
        if (stage != null && t.age?.contains(stage) == true) s += 1
        if (t.season?.size == 4) s += 0.5
        return s
    }
    fun stageKey(label: String?) = when (label) { L.t("Welpe") -> "puppy"; L.t("Senior") -> "senior"; L.t("Erwachsen") -> "adult"; else -> null }
}

/** Die Häkchen der Checklisten – ein Datensatz für alle Tipps (Art „checks“): `{"<slug>": [true, false], "u": …}`. */
@Serializable(with = TipChecks.Serializer::class)
data class TipChecks(val bySlug: Map<String, List<Boolean>> = emptyMap(), override val u: Double = 0.0) : SyncedItem {
    override val id get() = "checks"
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "checks" }

    object Serializer : KSerializer<TipChecks> {
        override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor
        override fun deserialize(decoder: Decoder): TipChecks {
            val o = (decoder as JsonDecoder).decodeJsonElement() as? JsonObject ?: return TipChecks()
            var u = 0.0; val map = mutableMapOf<String, List<Boolean>>()
            for ((k, v) in o) {
                if (k == "u") u = (v as? JsonPrimitive)?.let { runCatching { it.double }.getOrNull() } ?: 0.0
                else (v as? JsonArray)?.let { a -> runCatching { a.map { (it as JsonPrimitive).boolean } }.getOrNull()?.let { map[k] = it } }
            }
            return TipChecks(map, u)
        }
        override fun serialize(encoder: Encoder, value: TipChecks) {
            val m = value.bySlug.mapValues { (_, l) -> JsonArray(l.map { JsonPrimitive(it) }) } + ("u" to JsonPrimitive(value.u))
            (encoder as JsonEncoder).encodeJsonElement(JsonObject(m))
        }
    }
}

/** Der Text eines Tipps: Überschriften (###), Aufzählungen (*), Absätze. */
object TipText {
    sealed interface Block { data class Heading(val t: String) : Block; data class Bullet(val t: String) : Block; data class Paragraph(val t: String) : Block }

    fun blocks(md: String): List<Block> {
        val out = mutableListOf<Block>(); val para = mutableListOf<String>()
        fun flush() { if (para.isNotEmpty()) { out += Block.Paragraph(para.joinToString("\n")); para.clear() } }
        for (raw in md.split("\n")) {
            val line = raw.trim()
            when {
                line.isEmpty() -> flush()
                line.startsWith("#") -> { flush(); out += Block.Heading(line.trimStart('#').trim()) }
                line.startsWith("* ") || line.startsWith("- ") -> { flush(); out += Block.Bullet(line.drop(2)) }
                else -> para += line
            }
        }
        flush()
        return out
    }
}
