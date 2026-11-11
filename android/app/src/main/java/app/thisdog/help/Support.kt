package app.thisdog.help

import app.thisdog.i18n.L
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import app.thisdog.BuildConfig
import app.thisdog.data.Api
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.log2
import kotlin.math.roundToInt

/**
 * Der Gerätecode (wie DeviceCode.swift und api/lib-support.php): 9 Zeichen, Crockford-Base32, das neunte eine
 * Prüfziffer. Er nennt App-Fassung, System und Geräteart – kein Gerät, kein Konto, keine Person.
 */
object DeviceCode {
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /** Plattform 2 = Android · Geräteart: 3 Telefon, 4 Tablet, 5 faltbar */
    fun encode(platform: Int, os: Int, kind: Int, ramLog2: Int, major: Int, minor: Int, build: Int): String {
        val v = ((platform and 3).toLong() shl 36) or ((os and 63).toLong() shl 30) or ((kind and 7).toLong() shl 27) or
            ((ramLog2 and 7).toLong() shl 24) or ((major and 15).toLong() shl 20) or ((minor and 63).toLong() shl 14) or (build and 16383).toLong()
        val vals = (7 downTo 0).map { ((v shr (it * 5)) and 31).toInt() }.toMutableList()
        vals += vals.withIndex().sumOf { (i, c) -> c * (i + 1) } % 31
        val s = vals.joinToString("") { ALPHABET[it].toString() }
        return "${s.take(3)}-${s.substring(3, 6)}-${s.takeLast(3)}"
    }

    private fun kind(c: Context) = when {
        Build.VERSION.SDK_INT >= 30 && c.packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_HINGE_ANGLE) -> 5
        c.resources.configuration.smallestScreenWidthDp >= 600 -> 4
        else -> 3
    }

    fun current(c: Context): String {
        val mem = ActivityManager.MemoryInfo().also { c.getSystemService(ActivityManager::class.java).getMemoryInfo(it) }.totalMem
        val ram = log2((mem / 1_073_741_824.0).coerceAtLeast(1.0)).roundToInt().coerceIn(0, 7)
        val v = BuildConfig.VERSION_NAME.split(".").mapNotNull { it.toIntOrNull() }
        return encode(2, Build.VERSION.RELEASE.substringBefore(".").toIntOrNull() ?: 0, kind(c), ram, v.getOrElse(0) { 0 }, v.getOrElse(1) { 0 }, BuildConfig.VERSION_CODE)
    }

    fun description(c: Context) =
        L.t("ThisDog %1\$s (%2\$s), Android %3\$s, ", BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE, Build.VERSION.RELEASE.substringBefore(".")) +
            when (kind(c)) { 5 -> "faltbar"; 4 -> L.t("Tablet"); else -> L.t("Telefon") }
}

object Support {
    @Serializable private data class Body(val kind: String, val email: String, val text: String, val code: String, val via: String = "app")
    @Serializable private data class Answer(val number: String)
    private val json = Json { ignoreUnknownKeys = true }

    /** Schickt eine Anfrage; gibt die Nummer zurück („T-0001“). */
    suspend fun send(api: Api, c: Context, kind: String, email: String, text: String): String =
        json.decodeFromJsonElement(Answer.serializer(), api.post("support.php", emptyMap(), Body(kind, email, text, DeviceCode.current(c)), Body.serializer())).number
}
