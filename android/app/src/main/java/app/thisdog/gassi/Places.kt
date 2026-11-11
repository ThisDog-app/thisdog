package app.thisdog.gassi

import app.thisdog.i18n.L
import app.thisdog.data.Api
import app.thisdog.model.LatLng
import app.thisdog.model.Track
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.Locale
import kotlin.math.roundToInt

/** Ein Ziel für die Runde: Hundezone, Park, Wald, Wiese (wie Places.swift). */
@Serializable
data class Place(
    val name: String, val kind: String, val label: String, val rank: Int, val lat: Double, val lon: Double,
    /** Kennung beim Server („way/123“, „wien/5“, „eigen/7“). */
    @kotlinx.serialization.SerialName("id") val serverID: String? = null,
    /** Was die Daten sagen (OpenStreetMap, Stadt Wien, ThisDog): Merkmal → Wert und Quelle. */
    val facts: Map<String, Fact> = emptyMap(),
    /** Bewertungen: Merkmal → [ja, nein]; wie viele Konten bewertet haben; Hundegrößen [klein, mittel, groß]. */
    val votes: Map<String, List<Int>> = emptyMap(),
    val voters: Int = 0,
    val sizes: List<Int> = listOf(0, 0, 0),
    val byUser: Boolean = false,
    /** Freigegebene Fotos und wann ThisDog den Ort vor Ort geprüft hat (Sekunden seit 1970). */
    val photos: List<Photo> = emptyList(),
    val checkedAt: Long? = null,
) {
    @Serializable data class Fact(val v: Int, val src: String)
    @Serializable data class Photo(val id: Int, val w: Int, val h: Int) {
        val url get() = "https://thisdog.app/api/photo.php?id=$id"
        val thumb get() = "$url&klein=1"
    }

    val id get() = serverID ?: "$kind:$lat,$lon"
    val coordinate get() = LatLng(lat, lon)
    val isDogZone get() = kind == "dog_park"

    /** Aus Luftlinie eine Runde schätzen: Umwegzuschlag 1,3 für Fußwege, hin und zurück. */
    fun roundTrip(from: LatLng) = Track.distance(from, coordinate) * 1.3 * 2

    companion object {
        /** Gemütliches Hundetempo: 66 m in der Minute. */
        fun minutes(meters: Double) = (meters / 66).roundToInt()
    }
}

/** Was man an einem Ort bewerten kann – dieselben Schlüssel wie api/place.php. */
enum class PlaceFeature(val key: String, val title: String, val sym: String) {
    OFF_LEASH("off_leash", L.t("Freilaufen möglich"), app.thisdog.ui.Sym.PAW), FENCED("fenced", L.t("Eingezäunt"), app.thisdog.ui.Sym.FENCE),
    WATER("water", L.t("Trinkwasser"), app.thisdog.ui.Sym.WATER), CLEAN("clean", L.t("Sauber"), app.thisdog.ui.Sym.SPARKLE),
    GRASS("grass", L.t("Rasen"), app.thisdog.ui.Sym.GRASS), SHADE("shade", L.t("Schatten"), app.thisdog.ui.Sym.TREE),
    BENCH("bench", L.t("Bänke"), app.thisdog.ui.Sym.CHAIR), BAGS("bags", L.t("Kotbeutelspender"), app.thisdog.ui.Sym.BAG),
    SPLIT("split", L.t("Getrennt für große und kleine Hunde"), app.thisdog.ui.Sym.SPLIT);

    val short get() = when (this) { OFF_LEASH -> L.t("Freilaufen"); BAGS -> L.t("Kotbeutel"); SPLIT -> L.t("Groß und klein getrennt"); else -> title }

    /** Getrennte Bereiche für große und kleine Hunde gibt es nur in Hundezonen. */
    val onlyDogZones get() = this == SPLIT

    /** Muss eine Prüfung vor Ort beantworten (CHECK_REQUIRED in api/place.php); die neueren Merkmale sind dort freiwillig. */
    val requiredForCheck get() = this != BAGS && this != SPLIT

    companion object {
        /** Was man an einem Ort dieser Art bewerten, eintragen und sehen kann. */
        fun forPlace(isDogZone: Boolean) = entries.filter { isDogZone || !it.onlyDogZones }
    }
}

/** Die Merkmale, die zu diesem Ort passen (bei Parks ohne „Getrennt für große und kleine Hunde“). */
val Place.features get() = PlaceFeature.forPlace(isDogZone)

/** Was die Ortsseite über ein Merkmal sagt; Quelle null = die Bewertungen. */
sealed interface PlaceVerdict {
    data class Yes(val src: String?) : PlaceVerdict
    data class No(val src: String?) : PlaceVerdict
    data class Partly(val src: String?) : PlaceVerdict
    data class Unsure(val yes: Int, val of: Int) : PlaceVerdict
}

/** Ab drei Bewertungen zählen die Stimmen; darunter gilt, was die Daten sagen. */
const val ENOUGH_VOTERS = 3

val Place.enoughVotes get() = voters >= ENOUGH_VOTERS

/** Mindestens drei Viertel ja: gibt es. Höchstens ein Viertel: gibt es nicht. Dazwischen uneinig. */
fun Place.verdict(f: PlaceFeature): PlaceVerdict? {
    // Vor Ort geprüft gilt vor allem anderen, bis jemand neu prüft.
    facts[f.key]?.takeIf { it.src == "thisdog" }?.let { return if (it.v == 1) PlaceVerdict.Yes("thisdog") else PlaceVerdict.No("thisdog") }
    val v = votes[f.key] ?: listOf(0, 0)
    val n = v.sum()
    if (enoughVotes && n > 0) {
        val share = v[0].toDouble() / n
        return when { share >= 0.75 -> PlaceVerdict.Yes(null); share <= 0.25 -> PlaceVerdict.No(null); else -> PlaceVerdict.Unsure(v[0], n) }
    }
    val fact = facts[f.key] ?: return null
    return when (fact.v) { 1 -> PlaceVerdict.Yes(fact.src); 0 -> PlaceVerdict.No(fact.src); else -> PlaceVerdict.Partly(fact.src) }
}

/** Weitere Angaben aus den Daten: Tränke, Mülleimer, Licht. Kotbeutel sind ein Merkmal ([PlaceFeature.BAGS]) und stehen deshalb nicht hier. */
val Place.extras: List<Pair<String, String>> get() =
    listOf(Triple("water_bowl", app.thisdog.ui.Sym.DRINK, L.t("Hundetränke")),
        Triple("bin", app.thisdog.ui.Sym.DELETE, L.t("Mülleimer")), Triple("lit", app.thisdog.ui.Sym.BULB, L.t("Beleuchtet")))
        .filter { facts[it.first]?.v == 1 }.map { it.second to it.third }

val Place.area get() = facts["area"]?.v
val Place.hasNoDogsArea get() = facts["no_dogs_area"]?.v == 1

val Place.sourceNote: String get() {
    val parts = mutableListOf(when { byUser -> L.t("Eingetragen von Menschen mit Hund"); serverID?.startsWith("eigen/") == true -> L.t("Eingetragen von ThisDog"); else -> L.t("Aus OpenStreetMap") })
    if (facts.values.any { it.src == "wien" }) parts += L.t("ergänzt mit Daten der Stadt Wien (CC BY 4.0)")
    return parts.joinToString(", ")
}

fun sourceLabel(src: String?) = when (src) { "wien" -> L.t("Laut Stadt Wien"); "eigen", "thisdog" -> L.t("Laut ThisDog"); else -> L.t("Laut Karte") }

/** Bewertungen eines Ortes beim Server (api/place.php). Nach außen gehen nur Zählungen. */
object PlaceService {
    @Serializable data class Sizes(val small: Boolean = false, val medium: Boolean = false, val large: Boolean = false)
    @Serializable data class Mine(val votes: Map<String, Int> = emptyMap(), val sizes: Sizes? = null) {
        /** Ob man hier schon etwas gesagt hat: Mehr als eine Bewertung je Mensch und Ort gibt es nicht. */
        val isRated get() = votes.isNotEmpty() || sizes?.let { it.small || it.medium || it.large } == true
    }
    @Serializable data class Summary(val votes: Map<String, List<Int>> = emptyMap(), val voters: Int = 0, val sizes: List<Int> = listOf(0, 0, 0), val mine: Mine = Mine(),
                                     val photos: List<Place.Photo> = emptyList(), val checkedAt: Long? = null, val facts: Map<String, Place.Fact> = emptyMap(), val scout: Boolean = false)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = true }

    suspend fun summary(api: Api, id: String): Summary = json.decodeFromJsonElement(Summary.serializer(), api.get("place.php", mapOf("id" to id)))

    @Serializable private data class VoteBody(val id: String, val votes: Map<String, Int?>, val sizes: Sizes)
    suspend fun vote(api: Api, id: String, votes: Map<String, Int?>, sizes: Sizes): Summary =
        json.decodeFromJsonElement(Summary.serializer(), api.post("place.php", mapOf("action" to "vote"), VoteBody(id, votes, sizes), VoteBody.serializer()))

    @Serializable private data class AddBody(val name: String, val kind: String, val lat: Double, val lon: Double, val votes: Map<String, Int>)
    @Serializable private data class AddAnswer(val place: Place)
    suspend fun add(api: Api, name: String, kind: String, at: LatLng, votes: Map<String, Int>): Place =
        json.decodeFromJsonElement(AddAnswer.serializer(), api.post("place.php", mapOf("action" to "add"), AddBody(name, kind, at.lat, at.lng, votes), AddBody.serializer())).place

    @Serializable private data class CheckBody(val id: String, val answers: Map<String, Int>, val lat: Double, val lon: Double, val at: Long)
    @Serializable private data class CheckId(val id: Int)
    @Serializable private data class CheckAnswer(val check: CheckId)
    /** Eine Prüfung vor Ort (nur Erkunder): alle Merkmale, der Standort und wann geprüft wurde (Sekunden). */
    suspend fun check(api: Api, id: String, answers: Map<String, Int>, at: LatLng, time: Long): Int =
        json.decodeFromJsonElement(CheckAnswer.serializer(), api.post("place.php", mapOf("action" to "check"), CheckBody(id, answers, at.lat, at.lng, time), CheckBody.serializer())).check.id

    suspend fun uploadPhoto(api: Api, id: String, jpeg: ByteArray, label: String = "", check: Int? = null) {
        api.upload("place.php", mapOf("action" to "photo"), buildMap { put("id", id); put("label", label); check?.let { put("check", "$it") } }, "foto", jpeg)
    }

    @Serializable data class MyCheck(val id: Int, val place: String, val name: String = "", val at: Long, val status: String, val photos: Int)
    @Serializable data class Mine2(val scout: Boolean = false, val checks: List<MyCheck> = emptyList())
    suspend fun mine(api: Api): Mine2 = json.decodeFromJsonElement(Mine2.serializer(), api.get("place.php", mapOf("action" to "mine")))

    @Serializable private data class PhotoReport(val photo: Int, val reason: String)
    suspend fun reportPhoto(api: Api, id: Int, reason: String) { api.post("place.php", mapOf("action" to "report_photo"), PhotoReport(id, reason), PhotoReport.serializer()) }

    /** Ob auf dem Foto ein Gesicht zu sehen ist – erkannt auf dem Gerät (android.media.FaceDetector), nichts geht dafür weg. */
    fun hasFace(jpeg: ByteArray): Boolean {
        val opts = android.graphics.BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.RGB_565 }
        val src = android.graphics.BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts) ?: return false
        val k = minOf(1.0, 800.0 / maxOf(src.width, src.height))
        val w = ((src.width * k).toInt() / 2) * 2; val h = (src.height * k).toInt()   // FaceDetector braucht eine gerade Breite
        val b = android.graphics.Bitmap.createScaledBitmap(src, w, h, true).copy(android.graphics.Bitmap.Config.RGB_565, false)
        return android.media.FaceDetector(w, h, 3).findFaces(b, arrayOfNulls(3)) > 0
    }

    // Fotos für das Hochladen bereitet app.thisdog.ui.Pictures vor (höchstens 2000 px, JPEG, auch aus HEIC).

    @Serializable private data class ReportBody(val id: String, val reason: String)
    suspend fun report(api: Api, id: String, reason: String) { api.post("place.php", mapOf("action" to "report"), ReportBody(id, reason), ReportBody.serializer()) }
}

/** Holt Ziele in der Nähe vom eigenen Server (OpenStreetMap, mit Hundezonen). */
object PlaceFinder {
    /** Ab so vielen Metern weg von der letzten Suche wird neu gesucht. */
    const val REFRESH_METERS = 250.0

    const val RADIUS = 3000.0

    @Serializable private data class Answer(val places: List<Place> = emptyList())
    private val json = Json { ignoreUnknownKeys = true }

    /** `null`, wenn der Server gerade keine Ziele liefern kann (OpenStreetMap antwortet nicht). */
    suspend fun near(api: Api, here: LatLng): List<Place>? {
        // Auf zwei Stellen gerundet (rund 1 km) – so grob rechnet der Server ohnehin, und mehr steht dann
        // auch in keinem Zugriffsprotokoll.
        val q = mapOf("lat" to String.format(Locale.US, "%.2f", here.lat), "lon" to String.format(Locale.US, "%.2f", here.lng))
        val found = runCatching { json.decodeFromJsonElement(Answer.serializer(), api.get("places.php", q)).places }.getOrNull() ?: return null
        return found.filter { Track.distance(here, it.coordinate) <= RADIUS }
            .sortedWith(compareBy({ Track.distance(here, it.coordinate) }, { it.rank }))
    }
}
