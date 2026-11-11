package app.thisdog.model

import app.thisdog.i18n.L

/**
 * Wo auf der Zeitleine was liegt (wie LeashLayout in TimeLeash.swift). Der Abstand folgt der Zeit, wird aber nie
 * enger, als ein Knoten Platz braucht; an Lücken ab vier Tagen steht ihre Länge.
 */
class LeashLayout(start: Day, entries: List<CalendarEntry>, pointsPerDay: Float, dateHeight: Float, rowHeight: Float, spacing: Float, maxNodes: Int = 10) {
    data class Node(val day: Day, val entries: List<CalendarEntry>, val y: Float, val height: Float)
    data class Gap(val days: Int, val y: Float)
    data class Span(val kind: EntryKind, val from: Float, val to: Float)

    val nodes: List<Node>; val gaps: List<Gap>; val spans: List<Span>; val height: Float

    init {
        val byDay = entries.filter { it.start >= start }.groupBy { it.start }.toMutableMap()
        // Was vorher begonnen hat und noch läuft (Weihnachten am 25.), hängt am ersten Knoten.
        val running = entries.filter { it.start < start && it.end >= start }
        if (running.isNotEmpty()) byDay[start] = running + byDay[start].orEmpty()
        var days = byDay.keys.sorted().toMutableList()
        if (days.firstOrNull() != start) days.add(0, start)
        days = days.take(maxNodes).toMutableList()
        val n = mutableListOf<Node>()
        for (day in days) {
            val list = byDay[day].orEmpty()
            val h = dateHeight + rowHeight * maxOf(1, list.size)
            val wanted = start.daysUntil(day) * pointsPerDay
            val y = n.lastOrNull()?.let { maxOf(wanted, it.y + it.height + spacing) } ?: 0f
            n += Node(day, list, y, h)
        }
        fun yOf(d: Day): Float {
            val first = n.firstOrNull() ?: return 0f
            if (d <= first.day) return 0f
            for ((a, b) in n.zipWithNext()) if (d <= b.day) {
                val t = a.day.daysUntil(d).toFloat() / maxOf(1, a.day.daysUntil(b.day))
                return a.y + (b.y - a.y) * t
            }
            val last = n.last(); return last.y + last.day.daysUntil(d) * pointsPerDay
        }
        val g = mutableListOf<Gap>()
        var lastEnd: Day? = null; var lastY = 0f
        for (node in n) {
            lastEnd?.let { val d = it.daysUntil(node.day); if (d >= GAP_LABEL_DAYS) g += Gap(d, (lastY + node.y) / 2) }
            lastEnd = maxOf(node.day, node.entries.maxOfOrNull { it.end } ?: node.day); lastY = node.y
        }
        val s = n.flatMap { node -> node.entries.filter { it.spanDays > 1 }.map { Span(it.kind, node.y, maxOf(node.y + 8, yOf(it.end))) } }
        nodes = n; gaps = g; spans = s
        height = maxOf(n.lastOrNull()?.let { it.y + it.height } ?: 0f, s.maxOfOrNull { it.to } ?: 0f)
    }

    companion object { const val GAP_LABEL_DAYS = 4 }
}

/** Worauf der große Countdown zählt: der nächste eigene oder Gesundheitstermin, der noch nicht begonnen hat. */
object NextUp {
    fun clock(time: String): Pair<Int, Int>? {
        val parts = time.split(":"); if (parts.size != 2) return null
        val h = parts[0].toIntOrNull() ?: return null; val m = parts[1].toIntOrNull() ?: return null
        return if (h in 0..23 && m in 0..59) h to m else null
    }

    fun pick(entries: List<CalendarEntry>, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): CalendarEntry? =
        upcoming(entries, 1, now).firstOrNull()

    /** Die nächsten Termine, frühester zuerst. */
    fun upcoming(entries: List<CalendarEntry>, limit: Int, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): List<CalendarEntry> {
        val today = Day(now.toLocalDate())
        return entries.filter { (it.kind == EntryKind.PERSONAL || it.kind == EntryKind.HEALTH) && !it.isPeriod }
            .filter { e -> if (e.start > today) true else e.start == today && clock(e.time)?.let { (h, m) -> now.toLocalDate().atTime(h, m) > now } == true }
            .sortedWith(compareBy({ it.start }, { it.time })).take(limit)
    }

    /** „Noch 2 Tage“ am Stück, damit jede Sprache Zahl und Wort so stellen und beugen kann, wie sie es braucht. */
    fun remaining(e: CalendarEntry, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): String {
        val today = Day(now.toLocalDate())
        val c = clock(e.time)
        if (c != null && e.start == today) {
            val mins = maxOf(0L, java.time.Duration.between(now, now.toLocalDate().atTime(c.first, c.second)).toMinutes()).toInt()
            if (mins == 1) return L.t("Noch 1 Minute")
            if (mins < 60) return L.t("Noch %1\$d Minuten", mins)
            val h = Math.round(mins / 60.0).toInt()
            return if (h == 1) L.t("Noch 1 Stunde") else L.t("Noch %1\$d Stunden", h)
        }
        val n = today.daysUntil(e.start)
        return when {
            n == 1 -> L.t("Noch 1 Tag")
            n < 14 -> L.t("Noch %1\$d Tage", n)
            n < 63 -> if (n / 7 == 1) L.t("Noch 1 Woche") else L.t("Noch %1\$d Wochen", n / 7)
            else -> L.t("Noch %1\$d Monate", n / 30)
        }
    }

    fun countdown(e: CalendarEntry, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): Pair<String, String> {
        val today = Day(now.toLocalDate())
        val c = clock(e.time)
        if (c != null && e.start == today) {
            val mins = maxOf(0L, java.time.Duration.between(now, now.toLocalDate().atTime(c.first, c.second)).toMinutes()).toInt()
            if (mins < 60) return "$mins" to if (mins == 1) L.t("Minute") else L.t("Minuten")
            val h = Math.round(mins / 60.0).toInt(); return "$h" to if (h == 1) L.t("Stunde") else L.t("Stunden")
        }
        val n = today.daysUntil(e.start)
        return when {
            n < 14 -> "$n" to if (n == 1) L.t("Tag") else L.t("Tage")
            n < 63 -> "${n / 7}" to if (n / 7 == 1) L.t("Woche") else L.t("Wochen")
            else -> "${n / 30}" to L.t("Monate")
        }
    }
}
