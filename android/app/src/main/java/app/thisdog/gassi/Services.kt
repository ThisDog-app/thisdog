package app.thisdog.gassi

import app.thisdog.data.Api
import app.thisdog.i18n.L
import app.thisdog.model.LatLng
import app.thisdog.model.Track
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.util.Locale

/**
 * Eine Adresse rund um den Hund: Tierarzt, Hundefriseur, Tierbedarf … (api/services.php, Daten aus OpenStreetMap).
 * Bis auf id, kind, label, name, lat und lon kann alles fehlen. `ad` gibt es nur beim gesponserten Eintrag.
 */
@Serializable
data class Service(
    val id: String, val kind: String, val label: String, val name: String, val lat: Double, val lon: Double,
    val street: String? = null, val city: String? = null, val phone: String? = null, val website: String? = null, val hours: String? = null,
    /** Nur bei Tierärzten mit Notdienst. */
    val emergency: Boolean = false,
    @Transient val ad: Ad? = null,
) {
    /** Was den gesponserten Platz ausmacht: Kennung für das Zählen, der Text des Betriebs und wer bezahlt. */
    data class Ad(val id: Int, val text: String?, val advertiser: String?)

    val coordinate get() = LatLng(lat, lon)
    val icon get() = ServiceKind.of(kind)?.icon ?: "pin"
    /** „Tierarzt · Praterstraße 12“ – ohne Straße nur die Art. */
    val subtitle get() = listOfNotNull(label, street?.takeIf { it.isNotBlank() }).joinToString(" · ")
    /** Öffnungszeiten, wie sie in OpenStreetMap stehen, je Abschnitt eine Zeile. */
    val hoursText get() = hours?.replace("; ", "\n")
    val websiteURL get() = website?.let(::websiteURL)
}

/** Die Arten in der Reihenfolge der Chips, mit Icon (wie auf iOS). Unbekannte Arten stehen nur unter „Alle“. */
enum class ServiceKind(val key: String, val icon: String) {
    VET("vet", "tierarzt"), GROOMER("groomer", "schere"), SHOP("shop", "laden"), SCHOOL("school", "pfeife"),
    SHELTER("shelter", "herz"), BOARDING("boarding", "haus"), CAFE("cafe", "tasse");

    /** Der Chip, in der Mehrzahl. */
    val chip: String get() = when (this) {
        VET -> L.t("Tierärzte"); GROOMER -> L.t("Hundefriseure"); SHOP -> L.t("Tierbedarf"); SCHOOL -> L.t("Hundeschulen")
        SHELTER -> L.t("Tierheime"); BOARDING -> L.t("Pensionen"); CAFE -> L.t("Lokale")
    }

    companion object {
        fun of(key: String) = entries.firstOrNull { it.key == key }
    }
}

/** Ohne http(s) davor nimmt die Website https:// an; OpenStreetMap kennt beides. */
fun websiteURL(raw: String): String {
    val w = raw.trim()
    return if (w.startsWith("http://", true) || w.startsWith("https://", true)) w else "https://" + w.removePrefix("//")
}

/** Was services.php liefert: die Adressen nach Entfernung, höchstens ein gesponserter Eintrag, und ob es die Gegend gibt. */
data class Services(val list: List<Service>, val sponsor: Service?, val covered: Boolean) {
    companion object { val EMPTY = Services(emptyList(), null, true) }
}

/** Was zu Chip und Suchtext passt (lokal). `kind` null heißt „Alle“. */
object ServiceFilter {
    /** Name, Art oder Straße enthalten den Suchtext, ohne Rücksicht auf Groß und klein. Leer passt immer. */
    fun matches(s: Service, query: String): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return true
        return listOfNotNull(s.name, s.label, s.street).any { it.contains(q, ignoreCase = true) }
    }

    fun matches(s: Service, kind: String?, query: String) = (kind == null || s.kind == kind) && matches(s, query)

    /** Chips nur für Arten, die es in der Antwort gibt (der gesponserte Eintrag zählt mit), in fester Reihenfolge. „Alle“ kommt davor. */
    fun chips(list: List<Service>, sponsor: Service? = null): List<ServiceKind> {
        val present = (list + listOfNotNull(sponsor)).map { it.kind }.toSet()
        return ServiceKind.entries.filter { it.key in present }
    }

    fun list(all: List<Service>, kind: String?, query: String) = all.filter { matches(it, kind, query) }

    /** Der gesponserte Eintrag erscheint nur, wenn er zum Chip und zum Suchtext passt. */
    fun sponsor(sponsor: Service?, kind: String?, query: String) = sponsor?.takeIf { matches(it, kind, query) }

    /**
     * Die Adressen in der Nähe und die Treffer der Namenssuche, ohne Doppelte (nach id) und ohne den gesponserten
     * Eintrag – der steht eigens oben. Mit Standort nach Entfernung.
     */
    fun merge(near: List<Service>, found: List<Service>, sponsor: Service?, here: LatLng?): List<Service> {
        val seen = HashSet<String>().apply { sponsor?.let { add(it.id) } }
        val all = (near + found).filter { seen.add(it.id) }
        return if (here == null) all else all.sortedBy { Track.distance(here, it.coordinate) }
    }
}

/** Holt Adressen vom eigenen Server; gleiche Rundung und Nachladen wie [PlaceFinder]. Kein Konto nötig. */
object ServiceFinder {
    /** Ab so vielen Metern weg von der letzten Suche wird neu geladen. */
    const val REFRESH_METERS = PlaceFinder.REFRESH_METERS
    /** Erst so viele Zeilen, „Mehr zeigen“ lädt so viele dazu. */
    const val PAGE = 30
    /** So viele nächste Adressen liegen auf der Karte. */
    const val ON_MAP = 40
    /** Ab so vielen Zeichen fragt die Suche auch den Server. */
    const val SEARCH_MIN = 3
    const val DEBOUNCE_MS = 400L

    @Serializable private data class SponsorJson(
        val id: Int, val place: String? = null, val kind: String, val label: String, val name: String, val lat: Double, val lon: Double,
        val street: String? = null, val city: String? = null, val phone: String? = null, val website: String? = null, val hours: String? = null,
        val emergency: Boolean = false, val text: String? = null, val advertiser: String? = null,
    ) {
        fun service() = Service(place ?: "anzeige/$id", kind, label, name, lat, lon, street, city, phone, website, hours, emergency, Service.Ad(id, text, advertiser))
    }
    @Serializable private data class Answer(val services: List<Service> = emptyList(), val sponsor: SponsorJson? = null, val covered: Boolean = true)
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    fun decode(e: JsonElement): Services = json.decodeFromJsonElement(Answer.serializer(), e).let { Services(it.services, it.sponsor?.service(), it.covered) }
    fun decode(text: String): Services = decode(json.parseToJsonElement(text))

    /** Adressen in der Nähe, mit `query` die Namenssuche im weiteren Umkreis. Wirft bei Netz- oder Serverfehler. */
    suspend fun near(api: Api, here: LatLng, query: String? = null): Services {
        // Auf zwei Stellen gerundet, wie bei places.php.
        val q = buildMap {
            put("lat", String.format(Locale.US, "%.2f", here.lat)); put("lon", String.format(Locale.US, "%.2f", here.lng))
            query?.trim()?.takeIf { it.isNotEmpty() }?.let { put("q", it) }
        }
        return decode(api.get("services.php", q))
    }

    @Serializable private data class TapBody(val action: String, val sponsor: Int)
    /** Der gesponserte Eintrag wurde angetippt. Fehler zählen nicht. */
    suspend fun tap(api: Api, sponsor: Int) {
        runCatching { api.post("services.php", body = TapBody("tap", sponsor), serializer = TapBody.serializer()) }
    }
}
