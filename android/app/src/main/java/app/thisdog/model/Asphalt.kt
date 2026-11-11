package app.thisdog.model

import app.thisdog.i18n.L
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin

/**
 * Wie heiß der Belag gerade ist (wie Asphalt.swift). Eine Wärmebilanz statt einer Sommertabelle: Die Sonne heizt
 * (Sonnenstand aus Ort und Uhrzeit, gedämpft durch Wolken), Wind und Ausstrahlung kühlen. Abgestimmt auf die
 * bekannten Messreihen an klaren Sommermittagen (25 °C Luft → gut 50 °C Belag); im Herbst, bei Wolken oder nachts
 * liegt der Belag nahe an der Luft.
 */
object Asphalt {
    /** Luft in °C, Bewölkung 0…1, Wind in m/s (10 m), Ort. */
    data class Conditions(val air: Double, val cloud: Double, val wind: Double, val lat: Double, val lng: Double)

    private const val ABSORPTION = 0.95
    private const val INTO_GROUND = 0.35

    fun surface(c: Conditions, millis: Long): Double {
        // Der Belag hinkt der Sonne nach: Mittel aus jetzt und vor einer Stunde.
        val sun = (irradiance(c, millis) + irradiance(c, millis - 3_600_000)) / 2
        val heating = ABSORPTION * (1 - INTO_GROUND) * sun
        val longwave = 90 * (1 - 0.8 * c.cloud.coerceIn(0.0, 1.0))
        val exchange = 5.7 + 3.8 * c.wind.coerceAtLeast(0.0) * 0.5 + 5.5
        return c.air + ((heating - longwave) / exchange).coerceAtLeast(-4.0)
    }

    /** Sonnenstrahlung auf den Boden in W/m²: klarer Himmel nach Haurwitz, Wolken nach Kasten und Czeplak. */
    fun irradiance(c: Conditions, millis: Long): Double {
        val s = sin(Math.toRadians(sunElevation(c.lat, c.lng, millis)))
        if (s <= 0.01) return 0.0
        return 1098 * s * exp(-0.057 / s) * (1 - 0.75 * c.cloud.coerceIn(0.0, 1.0).pow(3.4))
    }

    /** Sonnenhöhe in Grad (Näherung, auf wenige Zehntelgrad genau). */
    fun sunElevation(latDeg: Double, lngDeg: Double, millis: Long): Double {
        val d = millis / 86400000.0 + 2440587.5 - 2451545.0
        val g = Math.toRadians((357.529 + 0.98560028 * d) % 360)
        val q = (280.459 + 0.98564736 * d) % 360
        val l = Math.toRadians(q + 1.915 * sin(g) + 0.020 * sin(2 * g))
        val e = Math.toRadians(23.439 - 0.00000036 * d)
        val dec = asin(sin(e) * sin(l))
        val ra = atan2(cos(e) * sin(l), cos(l))
        val gmst = (18.697374558 + 24.06570982441908 * d) % 24
        val ha = Math.toRadians(gmst * 15 + lngDeg) - ra
        val lat = Math.toRadians(latDeg)
        return Math.toDegrees(asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)))
    }

    /** Nur, wenn es knapp wird. */
    fun warning(c: Conditions, millis: Long): Calc.Paws? = Calc.paws(surface(c, millis)).takeIf { it != Calc.Paws.OK }

    /** „bedeckt, Sonne tief“ – woher der Wert kommt, in wenigen Worten. */
    fun reason(c: Conditions, millis: Long): String {
        val h = sunElevation(c.lat, c.lng, millis)
        if (h <= 0) return L.t("Sonne untergegangen")
        val sky = if (c.cloud >= 0.75) L.t("bedeckt") else if (c.cloud >= 0.35) L.t("teils bewölkt") else L.t("sonnig")
        return when { h < 20 -> L.t("%1\$s, Sonne tief", sky); h > 45 -> L.t("%1\$s, Sonne hoch", sky); else -> sky }
    }
}
