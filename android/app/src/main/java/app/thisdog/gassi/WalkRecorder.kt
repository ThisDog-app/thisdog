package app.thisdog.gassi

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import app.thisdog.model.LatLng
import app.thisdog.model.Polyline
import app.thisdog.model.Track
import app.thisdog.model.Walk
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Zeichnet eine Runde auf (wie WalkRecorder.swift). Die Ortung läuft im [WalkService], damit sie bei
 * gesperrtem Bildschirm weiterläuft; hier landen die Punkte.
 *
 * Verworfen werden Punkte, die zu ungenau sind oder einen Sprung bedeuten, den kein Mensch mit Hund läuft.
 * Die laufende Runde liegt nach jedem dritten Punkt in einer Datei: Wird die App beendet, läuft sie beim
 * nächsten Start weiter.
 */
object WalkRecorder {
    enum class Phase { IDLE, RECORDING, PAUSED }

    var phase by mutableStateOf(Phase.IDLE); private set
    val coordinates = mutableStateListOf<LatLng>()
    var meters by mutableStateOf(0.0); private set
    /** Wo man gerade steht, auch vor dem Start (für die Karte). */
    var here by mutableStateOf<LatLng?>(null); private set
    /** Je vollem Kilometer die gelaufene Zeit bis dorthin. */
    val splits = mutableStateListOf<Double>()
    var startedAt by mutableStateOf<Long?>(null); private set

    private var banked = 0.0
    private var runningSince: Long? = null
    private var last: Location? = null
    private var file: File? = null

    const val MAX_ACCURACY = 30f
    /** Schneller als 7 m/s (25 km/h) läuft niemand mit Hund – das ist ein Sprung der Ortung. */
    const val MAX_SPEED = 7.0
    const val MIN_STEP = 2.0

    /** Jeder glaubwürdige Punkt der laufenden Runde (für die Hundefreunde). */
    var onPoint: ((LatLng, Long) -> Unit)? = null
    var onEnd: (() -> Unit)? = null

    fun init(context: Context) {
        if (file != null) return
        file = File(context.filesDir, "laufende-runde.json")
        restore()
        if (phase == Phase.RECORDING) WalkService.start(context)
    }

    fun hasPermission(context: Context) =
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun seconds(now: Long = System.currentTimeMillis()) = banked + (runningSince?.let { (now - it) / 1000.0 } ?: 0.0)

    val pace get() = if (meters >= 100) seconds() / 60 / (meters / 1000) else null

    /** Für „Wohin heute?“: einmal den Standort, ohne aufzuzeichnen. */
    @SuppressLint("MissingPermission")
    fun locateOnce(context: Context) {
        if (!hasPermission(context)) return
        val lm = context.getSystemService(LocationManager::class.java) ?: return
        val providers = lm.getProviders(true)
        providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time }?.let { here = LatLng(it.latitude, it.longitude) }
        // Alle eingeschalteten Quellen gleichzeitig: Ohne Google-Dienste (und im Emulator) antwortet „fused“ nicht immer.
        val wanted = listOf(LocationManager.FUSED_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter { it in providers }
        for (provider in wanted) {
            if (Build.VERSION.SDK_INT >= 30) {
                lm.getCurrentLocation(provider, null, ContextCompat.getMainExecutor(context)) { l -> l?.let { here = LatLng(it.latitude, it.longitude) } }
            } else {
                @Suppress("DEPRECATION")
                lm.requestSingleUpdate(provider, { l: Location -> here = LatLng(l.latitude, l.longitude) }, android.os.Looper.getMainLooper())
            }
        }
    }

    fun start(context: Context) {
        coordinates.clear(); splits.clear()
        meters = 0.0; banked = 0.0; last = null
        startedAt = System.currentTimeMillis(); runningSince = startedAt
        phase = Phase.RECORDING
        persist()
        WalkService.start(context)
    }

    fun pause(context: Context) {
        if (phase != Phase.RECORDING) return
        banked = seconds(); runningSince = null
        phase = Phase.PAUSED
        last = null  // Nach der Pause zählt der Weg nicht als Sprung vom alten Punkt aus.
        persist()
        WalkService.update(context)
    }

    fun resume(context: Context) {
        if (phase != Phase.PAUSED) return
        runningSince = System.currentTimeMillis()
        phase = Phase.RECORDING
        persist()
        WalkService.update(context)
    }

    /** Beendet die Runde und gibt sie zurück; `null`, wenn kaum gelaufen wurde. */
    fun finish(context: Context): Walk? {
        val total = seconds()
        val started = startedAt
        val walk = if (started != null && (meters >= 20 || total >= 60))
            Walk(Walk.newID(), started.toDouble(), System.currentTimeMillis().toDouble(), total, meters, Polyline.encode(Track.simplify(coordinates.toList())))
        else null
        WalkService.stop(context)
        reset()
        return walk
    }

    fun discard(context: Context) { WalkService.stop(context); reset() }

    private fun reset() {
        if (phase != Phase.IDLE) onEnd?.invoke()
        phase = Phase.IDLE
        coordinates.clear(); splits.clear()
        meters = 0.0; banked = 0.0; runningSince = null; startedAt = null; last = null
        file?.delete()
    }

    /** Nimmt einen Ortungspunkt auf, wenn er glaubwürdig ist. Gibt zurück, ob er zählt. */
    fun take(loc: Location): Boolean {
        here = LatLng(loc.latitude, loc.longitude)
        if (phase != Phase.RECORDING || !loc.hasAccuracy() || loc.accuracy > MAX_ACCURACY) return false
        last?.let { prev ->
            val d = loc.distanceTo(prev).toDouble()
            val dt = (loc.time - prev.time) / 1000.0
            if (d < MIN_STEP) return false
            if (dt > 0 && d / dt > MAX_SPEED) return false
            meters += d
            while (meters >= (splits.size + 1) * 1000.0) splits.add(seconds(loc.time))
        }
        last = loc
        val point = LatLng(loc.latitude, loc.longitude)
        coordinates.add(point)
        startedAt?.let { onPoint?.invoke(point, it) }
        if (coordinates.size % 3 == 0) persist()
        return true
    }

    // Sichern

    @Serializable
    private data class Saved(val phase: Phase, val lat: List<Double>, val lon: List<Double>, val meters: Double, val banked: Double,
                             val runningSince: Long? = null, val startedAt: Long? = null, val splits: List<Double>)

    private fun persist() {
        val f = file ?: return
        val s = Saved(phase, coordinates.map { it.lat }, coordinates.map { it.lng }, meters, banked, runningSince, startedAt, splits.toList())
        runCatching { File(f.path + ".neu").apply { writeText(Json.encodeToString(Saved.serializer(), s)) }.renameTo(f) }
    }

    private fun restore() {
        val s = runCatching { Json.decodeFromString(Saved.serializer(), file!!.readText()) }.getOrNull() ?: return
        if (s.phase == Phase.IDLE) return
        phase = s.phase
        coordinates.addAll(s.lat.zip(s.lon) { a, b -> LatLng(a, b) })
        meters = s.meters; banked = s.banked; runningSince = s.runningSince; startedAt = s.startedAt
        splits.addAll(s.splits)
    }
}
