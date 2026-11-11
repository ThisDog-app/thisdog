package app.thisdog.system

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import app.thisdog.MainActivity
import app.thisdog.R
import app.thisdog.data.Graph
import app.thisdog.gassi.Heat
import app.thisdog.i18n.L
import app.thisdog.model.Calc
import app.thisdog.model.Day
import app.thisdog.model.WalkText
import kotlin.math.roundToInt

/** Widget „Gassi diese Woche“: Strecke seit Montag, dazu Hitze oder die nächste Fälligkeit. Tippen öffnet Gassi. */
class WeekWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        Graph.init(context)
        val views = render(context)
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    companion object {
        /** Nach jeder Änderung an Runden, Gesundheit oder Wetter. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, WeekWidget::class.java))
            if (ids.isEmpty()) return
            val views = render(context)
            ids.forEach { manager.updateAppWidget(it, views) }
        }

        private fun render(context: Context): RemoteViews {
            val store = Graph.store
            val today = Day.today()
            val monday = Day(today.date.with(java.time.DayOfWeek.MONDAY))
            val week = store.walks.filter { it.day >= monday }
            val v = RemoteViews(context.packageName, R.layout.widget_woche)
            v.setTextViewText(R.id.widget_name, store.profile.name.ifEmpty { L.t("Gassi") })
            v.setTextViewText(R.id.widget_km, WalkText.km(week.sumOf { it.meters }))
            v.setTextViewText(R.id.widget_einheit, L.t("km diese Woche"))
            v.setTextViewText(R.id.widget_hinweis, note(today) ?: if (week.size == 1) L.t("1 Runde seit Montag") else L.t("%1\$s Runden seit Montag", week.size))
            val open = PendingIntent.getActivity(context, 71, Intent(context, MainActivity::class.java).putExtra("tab", "GASSI")
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            v.setOnClickPendingIntent(R.id.widget_root, open)
            return v
        }

        /** Das Wichtigste neben der Strecke: erst Hitze, dann die nächste Fälligkeit. */
        private fun note(today: Day): String? {
            val air = Heat.air; val surface = Heat.surface()
            if (Heat.warning != null && air != null && surface != null) return L.t("%1\$s °C – Asphalt %2\$s °C", air.roundToInt(), surface.roundToInt())
            val due = Graph.store.dues.firstOrNull { today.daysUntil(it.due) <= 30 } ?: return null
            val n = today.daysUntil(due.due)
            return when {
                n < 0 -> L.t("%1\$s: seit %2\$s Tagen fällig", due.title, -n)
                n == 0 -> L.t("%1\$s: heute fällig", due.title)
                n == 1 -> L.t("%1\$s: in 1 Tag fällig", due.title)
                else -> L.t("%1\$s: in %2\$s Tagen fällig", due.title, n)
            }
        }
    }
}
