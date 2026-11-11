package app.thisdog.model

import app.thisdog.i18n.L
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlinx.serialization.Serializable

data class LatLng(val lat: Double, val lng: Double)

/** Eine Gassirunde (Art „walk“); die Strecke steht geglättet und als „Encoded Polyline“ darin, wie auf iOS. */
@Serializable
data class Walk(
    override val id: String,
    /** Beginn und Ende in Millisekunden seit 1970. */
    val start: Double,
    val end: Double,
    /** Gelaufene Zeit ohne Pausen, in Sekunden. */
    val seconds: Double,
    val meters: Double,
    val path: String,
    val notes: String = "",
    override val u: Double = 0.0,
) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    val day get() = Day(Instant.ofEpochMilli(start.toLong()).atZone(ZoneId.systemDefault()).toLocalDate())
    val coordinates get() = Polyline.decode(path)
    /** Minuten je Kilometer, wenn genug gelaufen wurde. */
    val pace get() = if (meters >= 100) seconds / 60 / (meters / 1000) else null

    companion object {
        const val KIND = "walk"
        fun newID() = DogEvent.newID("walk")
    }
}

/** Das Polyline-Verfahren von Google: Koordinaten als Differenzen in druckbaren Zeichen. */
object Polyline {
    fun encode(coords: List<LatLng>): String {
        val out = StringBuilder()
        var lastLat = 0; var lastLon = 0
        for (c in coords) {
            val lat = Math.round(c.lat * 1e5).toInt(); val lon = Math.round(c.lng * 1e5).toInt()
            chunk(lat - lastLat, out); chunk(lon - lastLon, out)
            lastLat = lat; lastLon = lon
        }
        return out.toString()
    }

    fun decode(s: String): List<LatLng> {
        val out = mutableListOf<LatLng>()
        var i = 0; var lat = 0; var lon = 0
        fun next(): Int? {
            var result = 0; var shift = 0
            while (i < s.length) {
                val b = s[i].code - 63; i++
                result = result or ((b and 0x1F) shl shift)
                shift += 5
                if (b < 0x20) return if (result and 1 != 0) (result shr 1).inv() else result shr 1
            }
            return null
        }
        while (i < s.length) {
            val dLat = next() ?: break; val dLon = next() ?: break
            lat += dLat; lon += dLon
            out += LatLng(lat / 1e5, lon / 1e5)
        }
        return out
    }

    private fun chunk(value: Int, out: StringBuilder) {
        var v = if (value < 0) (value shl 1).inv() else value shl 1
        while (v >= 0x20) { out.append(((0x20 or (v and 0x1F)) + 63).toChar()); v = v shr 5 }
        out.append((v + 63).toChar())
    }
}

object Track {
    /** Entfernung zweier Punkte in Metern (Haversine). */
    fun distance(a: LatLng, b: LatLng): Double {
        val r = 6371000.0
        val p1 = Math.toRadians(a.lat); val p2 = Math.toRadians(b.lat)
        val dp = p2 - p1; val dl = Math.toRadians(b.lng - a.lng)
        val h = Math.sin(dp / 2).let { it * it } + cos(p1) * cos(p2) * Math.sin(dl / 2).let { it * it }
        return 2 * r * Math.asin(minOf(1.0, sqrt(h)))
    }

    fun length(c: List<LatLng>) = c.zipWithNext().sumOf { distance(it.first, it.second) }

    /** Douglas-Peucker: lässt Punkte weg, die weniger als `tolerance` Meter von der Linie abweichen. */
    fun simplify(c: List<LatLng>, tolerance: Double = 3.0): List<LatLng> {
        if (c.size <= 2) return c
        val keep = BooleanArray(c.size).also { it[0] = true; it[c.size - 1] = true }
        val stack = ArrayDeque(listOf(0 to c.size - 1))
        while (stack.isNotEmpty()) {
            val (a, b) = stack.removeLast()
            var maxD = 0.0; var index = 0
            for (i in a + 1 until b) { val d = offset(c[i], c[a], c[b]); if (d > maxD) { maxD = d; index = i } }
            if (maxD > tolerance) { keep[index] = true; stack.addLast(a to index); stack.addLast(index to b) }
        }
        return c.filterIndexed { i, _ -> keep[i] }
    }

    private fun offset(p: LatLng, a: LatLng, b: LatLng): Double {
        val mLat = 111_320.0; val mLon = 111_320.0 * cos(a.lat * Math.PI / 180)
        val px = (p.lng - a.lng) * mLon; val py = (p.lat - a.lat) * mLat
        val bx = (b.lng - a.lng) * mLon; val by = (b.lat - a.lat) * mLat
        val len2 = bx * bx + by * by
        if (len2 <= 0) return sqrt(px * px + py * py)
        val t = ((px * bx + py * by) / len2).coerceIn(0.0, 1.0)
        val dx = px - t * bx; val dy = py - t * by
        return sqrt(dx * dx + dy * dy)
    }
}

object WalkText {
    private val de get() = app.thisdog.i18n.L.locale
    /** „1,84 km“ oder „650 m“. */
    fun distance(m: Double): String =
        if (m < 1000) "${(m / 10).roundToInt() * 10} m" else String.format(de, if (m < 10_000) L.t("%.2f km") else L.t("%.1f km"), m / 1000)
    fun km(m: Double) = String.format(de, "%.2f", m / 1000)
    fun clock(seconds: Double): String { val s = seconds.toInt(); return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60) }
    fun duration(seconds: Double): String { val m = (seconds / 60).roundToInt(); return if (m >= 60) L.t("%1\$s Std. %2\$s Min.", m / 60, m % 60) else L.t("%1\$s Min.", m) }
    fun pace(minPerKm: Double?): String { val p = minPerKm ?: return "–"; if (!p.isFinite() || p >= 60) return "–"; val s = (p * 60).roundToInt(); return "%d:%02d".format(s / 60, s % 60) }
}
