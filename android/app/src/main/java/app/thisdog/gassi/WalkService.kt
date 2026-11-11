package app.thisdog.gassi

import app.thisdog.i18n.L
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import app.thisdog.MainActivity
import app.thisdog.R
import app.thisdog.model.WalkText

/**
 * Hält die Ortung während der Runde am Leben – auch mit gesperrtem Bildschirm. Android verlangt dafür
 * eine sichtbare Mitteilung; sie zeigt die Strecke, so wie die Live-Aktivität auf dem iPhone.
 */
class WalkService : Service(), LocationListener {
    private var lm: LocationManager? = null
    private var shownMeters = 0.0

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        app.thisdog.data.Graph.init(this)  // Startet Android den Dienst neu, fehlt sonst das Konto für die Hundefreunde.
        WalkRecorder.init(this)
        if (WalkRecorder.phase == WalkRecorder.Phase.IDLE) { stopSelf(); return START_NOT_STICKY }
        channel()
        val n = notification()
        // Startet Android den Dienst im Hintergrund neu, darf er ab Android 12 (und ohne Ortungsrecht) nicht in den
        // Vordergrund – dann still aufhören. Die Runde liegt in der Datei und läuft beim nächsten Öffnen der App weiter.
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION) else startForeground(ID, n)
        } catch (e: Exception) { stopSelf(); return START_NOT_STICKY }
        if (lm == null && WalkRecorder.hasPermission(this)) {
            val m = getSystemService(LocationManager::class.java)
            // GPS und „fused“ zugleich: Punkte, die beide fast gleich melden, fallen unter die 2-m-Schwelle.
            val on = m.getProviders(true)
            listOf(LocationManager.FUSED_PROVIDER, LocationManager.GPS_PROVIDER).filter { it in on }
                .forEach { m.requestLocationUpdates(it, 2000L, 3f, this, Looper.getMainLooper()) }
            lm = m
        }
        return START_STICKY
    }

    override fun onLocationChanged(location: Location) {
        if (WalkRecorder.take(location) && WalkRecorder.meters - shownMeters >= 50) refresh()
    }

    override fun onDestroy() {
        lm?.removeUpdates(this); lm = null
        super.onDestroy()
    }

    private fun refresh() {
        shownMeters = WalkRecorder.meters
        getSystemService(NotificationManager::class.java).notify(ID, notification())
    }

    private fun channel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, L.t("Laufende Runde"), NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).putExtra("tab", "GASSI").addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val paused = WalkRecorder.phase == WalkRecorder.Phase.PAUSED
        val since = System.currentTimeMillis() - (WalkRecorder.seconds() * 1000).toLong()
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.icon_hund)
            .setContentTitle(if (paused) L.t("Pause") else L.t("Unterwegs"))
            .setContentText(WalkText.distance(WalkRecorder.meters))
            .setColor(0xFFEE6A24.toInt())
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_WORKOUT)
            .setContentIntent(open)
            .apply { if (!paused) setUsesChronometer(true).setWhen(since).setShowWhen(true) }
            .apply {
                // Android 16: als Live-Update oben in der Statusleiste und auf dem Sperrbildschirm, mit der Strecke im Chip.
                if (Build.VERSION.SDK_INT >= 36) {
                    setRequestPromotedOngoing(true)
                    setShortCriticalText(if (paused) L.t("Pause") else WalkText.km(WalkRecorder.meters) + " km")
                }
            }
            .build()
    }

    companion object {
        private const val CHANNEL = "runde"
        private const val ID = 7

        /** Aus dem Hintergrund verweigert Android den Start (ForegroundServiceStartNotAllowedException) – kein Absturz. */
        fun start(context: Context) { runCatching { ContextCompat.startForegroundService(context, Intent(context, WalkService::class.java)) } }
        fun update(context: Context) = start(context)
        fun stop(context: Context) { context.stopService(Intent(context, WalkService::class.java)) }
    }
}
