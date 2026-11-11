package app.thisdog.gassi

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.thisdog.BuildConfig
import app.thisdog.i18n.L
import app.thisdog.model.Asphalt
import app.thisdog.model.Calc
import app.thisdog.model.LatLng
import app.thisdog.model.Track
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Wie warm es gerade ist, für die Hitzewarnung vor der Runde. Kommt vom norwegischen Wetterdienst (MET Norway,
 * frei nutzbar mit Quellenangabe), höchstens alle halbe Stunde. Ohne Wetter bleibt es still – dann gibt es
 * keine Warnung und keinen Belagswert.
 */
object Heat {
    var air by mutableStateOf<Double?>(null); private set
    var daylight by mutableStateOf(true); private set
    var at by mutableStateOf(0L); private set
    /** Alles, was der Belag braucht: Luft, Wolken, Wind und wo. */
    var conditions by mutableStateOf<Asphalt.Conditions?>(null); private set
    /** Die letzte Wettermeldung mit der nächsten Stunde. */
    var reading by mutableStateOf<Reading?>(null); private set

    private var spot: LatLng? = null
    private var loading = false
    private val client = OkHttpClient.Builder().callTimeout(12, TimeUnit.SECONDS).build()

    /** Zum Ansehen ohne Wetter (Entwicklerfassung, `--es hitze 33`). */
    fun demo(t: Double) { air = t; daylight = true; at = System.currentTimeMillis(); conditions = Asphalt.Conditions(t, 0.0, 2.0, 48.21, 16.37) }

    /** Die Temperatur, solange sie höchstens zwei Stunden alt ist – älter gilt nicht mehr als „jetzt“. */
    val current: Double? get() = air?.takeIf { System.currentTimeMillis() - at <= 2 * 3600_000 }

    /** Wie warm der Belag jetzt etwa ist; null ohne aktuelles Wetter. */
    fun surface(millis: Long = System.currentTimeMillis()): Double? {
        if (current == null) return null
        return conditions?.let { Asphalt.surface(it, millis) }
    }

    val warning: Calc.Paws? get() {
        if (current == null) return null
        return conditions?.let { Asphalt.warning(it, System.currentTimeMillis()) }
    }

    /** Holt das Wetter, wenn es alt ist oder man weit weg ist. Gibt zurück, ob es neu ist. */
    suspend fun refresh(here: LatLng): Boolean {
        if (loading) return false
        val last = spot
        if (System.currentTimeMillis() - at < 30 * 60_000 && last != null && Track.distance(last, here) < 5000) return false
        loading = true
        try {
            // Auf zwei Stellen gerundet (rund 1 km): genauer braucht es das Wetter nicht.
            val url = String.format(Locale.US, "https://api.met.no/weatherdata/locationforecast/2.0/compact?lat=%.2f&lon=%.2f", here.lat, here.lng)
            val body = withContext(Dispatchers.IO) {
                runCatching {
                    client.newCall(Request.Builder().url(url)
                        // MET Norway verlangt, dass sich Apps zu erkennen geben.
                        .header("User-Agent", "ThisDog/${BuildConfig.VERSION_NAME} (Android; https://thisdog.app)").build())
                        .execute().use { if (it.isSuccessful) it.body.string() else null }
                }.getOrNull()
            } ?: return false
            val r = parse(body) ?: return false
            air = r.air
            daylight = sunElevation(here, System.currentTimeMillis()) > 0
            conditions = Asphalt.Conditions(r.air, r.cloud, r.wind, here.lat, here.lng)
            reading = r
            at = System.currentTimeMillis()
            spot = here
            return true
        } finally { loading = false }
    }

    /** Jetzt: Luft, Bewölkung (0…1), Wind; dazu die nächste Stunde: Wettersymbol, Niederschlag in mm, Temperatur danach. */
    data class Reading(val air: Double, val cloud: Double, val wind: Double,
                       val symbol: String? = null, val rain: Double? = null, val nextAir: Double? = null)

    fun parse(json: String): Reading? = runCatching {
        val series = Json.parseToJsonElement(json).jsonObject["properties"]!!.jsonObject["timeseries"]!!.jsonArray
        val data = series[0].jsonObject["data"]!!.jsonObject
        val d = data["instant"]!!.jsonObject["details"]!!.jsonObject
        val next = data["next_1_hours"]?.jsonObject
        Reading(d["air_temperature"]!!.jsonPrimitive.double,
            (d["cloud_area_fraction"]?.jsonPrimitive?.double ?: 50.0) / 100,
            d["wind_speed"]?.jsonPrimitive?.double ?: 3.0,
            next?.get("summary")?.jsonObject?.get("symbol_code")?.jsonPrimitive?.content,
            next?.get("details")?.jsonObject?.get("precipitation_amount")?.jsonPrimitive?.double,
            series.getOrNull(1)?.jsonObject?.get("data")?.jsonObject?.get("instant")?.jsonObject?.get("details")?.jsonObject
                ?.get("air_temperature")?.jsonPrimitive?.double)
    }.getOrNull()

    /** „Bewölkt“ aus dem Wettersymbol von MET Norway („partlycloudy_day“). */
    fun skyText(symbol: String): String {
        val s = symbol.substringBefore('_')
        return when {
            s.contains("thunder") -> L.t("Gewitter")
            s.contains("snow") -> L.t("Schnee")
            s.contains("sleet") -> L.t("Schneeregen")
            s.contains("rain") -> L.t("Regen")
            s == "fog" -> L.t("Nebel")
            s == "cloudy" -> L.t("Bewölkt")
            s == "partlycloudy" -> L.t("Teils bewölkt")
            s == "fair" -> L.t("Heiter")
            s == "clearsky" -> L.t("Klar")
            else -> ""
        }
    }

    /** „Die nächste Stunde bleibt trocken. Dann 6 °C.“ */
    fun nextHourLine(r: Reading): String {
        val wet = (r.rain ?: 0.0) >= 0.1
        val what = if (r.symbol?.contains("snow") == true || r.symbol?.contains("sleet") == true) L.t("Schnee") else L.t("Regen")
        val line = if (wet) L.t("%1\$s in der nächsten Stunde, etwa %2\$s mm.", what, "%.1f".format(java.util.Locale.GERMAN, r.rain)) else L.t("Die nächste Stunde bleibt trocken.")
        return r.nextAir?.let { line + " " + L.t("Dann %1\$s °C.", Math.round(it)) } ?: line
    }

    /** Sonnenhöhe in Grad. */
    fun sunElevation(here: LatLng, millis: Long): Double = Asphalt.sunElevation(here.lat, here.lng, millis)
}
