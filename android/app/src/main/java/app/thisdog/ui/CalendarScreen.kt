package app.thisdog.ui

import app.thisdog.i18n.L
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.model.*

fun kindColor(k: EntryKind, p: Palette) = when (k) {
    EntryKind.PERSONAL -> p.accent; EntryKind.HEALTH -> p.health; EntryKind.SEASONAL -> p.seasonal
    EntryKind.WARNING -> p.warning; EntryKind.BIRTHDAY -> if (p === DarkPalette) androidx.compose.ui.graphics.Color(0xFFEE86AE) else androidx.compose.ui.graphics.Color(0xFFD9608F)
}

/**
 * Der Kalender (wie CalendarScreen.swift). Schmal eine Spalte: was als Nächstes ansteht, der Monat, darunter die Leine ab
 * dem gewählten Tag. Breit Monat links und Termine rechts, quer der ganze Monat dicht links.
 */
@Composable
fun CalendarScreen(wide: Boolean) {
    var settings by remember { mutableStateOf(false) }
    val store = Graph.store
    val p = LocalPalette.current
    val quer = isQuer()
    var selected by remember { mutableStateOf(Day.today()) }
    /** Der obere der gezeigten Monate. Breit und hochkant ist Platz für zwei. */
    var month by remember { mutableStateOf(Day.today().firstOfMonth) }
    var twoMonths by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<DogEvent?>(null) }
    // Wo die Leine den Monat verlässt und wo die Zeitleine beginnt, beide im Fenster gemessen (Pixel).
    var leashExit by remember { mutableStateOf(0f) }
    var leashTop by remember { mutableStateOf(0f) }
    val density = LocalDensity.current
    val entries = CalendarBuilder.all(store.events, Graph.content.seasonal) + CalendarBuilder.dogEntries(store.profile, store.dues)
    val select = { d: Day ->
        val lastShown = if (twoMonths) month.addingMonths(1) else month
        if (d.firstOfMonth < month || d.firstOfMonth > lastShown) month = d.firstOfMonth
        selected = d
    }
    val shift = { n: Int ->
        val target = month.addingMonths(n)
        month = target
        selected = if (target == Day.today().firstOfMonth) Day.today() else target
    }

    val header: @Composable (Float) -> Unit = { size -> CalendarHeader(NextUp.pick(entries), size, { select(it.start) }, { settings = true }) { editing = DogEvent(title = "", start = selected.iso) } }
    val leash: @Composable (LeashEntry) -> Unit = { entry ->
        TimeLeash(selected, entries.filter { !it.isPeriod }, entry, onSelect = { e -> e.eventID?.let { store.event(it) }?.let { editing = it } },
            onAdd = { editing = DogEvent(title = "", start = it.iso) })
    }
    val sideLeash: @Composable (Float) -> Unit = { margin ->
        Box(Modifier.onGloballyPositioned { leashTop = it.positionInWindow().y }) { leash(LeashEntry.Side(margin, with(density) { (leashExit - leashTop).toDp().value })) }
    }
    val bottom = dockClearance()
    when {
        quer -> Row(Modifier.fillMaxSize().background(p.paper)) {
            Column(Modifier.width(340.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 6.dp)) {
                MonthPane(month, selected, select, shift, entries, roomy = false, dense = true, margin = 12f, exit = MonthExit.Side(12f)) { leashExit = it }
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp).padding(top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                header(36f); sideLeash(12f)
            }
        }
        wide -> BoxWithConstraints(Modifier.fillMaxSize().background(p.paper).statusBarsPadding()) {
            // Quer darf der Monat schmaler sein: Die Termine rechts brauchen den Platz.
            val share = if (maxWidth > maxHeight) .4f else .5f
            // Zwei Monate, wenn beide ganz hineinpassen (Tablet hochkant), sonst einer.
            LaunchedEffect(maxHeight) { twoMonths = maxHeight > 1000.dp }
            Row(Modifier.fillMaxSize()) {
                Column(Modifier.weight(share).fillMaxHeight().verticalScroll(rememberScrollState()).padding(top = 24.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(40.dp)) {
                    MonthPane(month, selected, select, shift, entries, roomy = true, dense = false, margin = 24f, exit = MonthExit.Side(24f)) { leashExit = it }
                    if (twoMonths) SecondMonth(month.addingMonths(1), selected, select, entries) { leashExit = it }
                }
                Column(Modifier.weight(1f - share).fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 24.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    header(52f); sideLeash(24f)
                }
            }
        }
        // Ohne Abstand: Die Leine läuft aus dem Monat direkt in die Zeitleine.
        else -> Column(Modifier.fillMaxSize().background(p.paper).statusBarsPadding().verticalScroll(rememberScrollState()).padding(bottom = bottom)) {
            Box(Modifier.padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 28.dp)) { header(44f) }
            MonthPane(month, selected, select, shift, entries, roomy = false, dense = false, margin = 16f, exit = MonthExit.Bottom(LEASH_X)) {}
            Box(Modifier.padding(horizontal = 16.dp)) { leash(LeashEntry.Top) }
        }
    }
    if (settings) CalendarSettings { settings = false }
    editing?.let { ev -> EventEditor(ev, isNew = store.event(ev.id) == null, onDismiss = { editing = null }) }
}

private const val LEASH_X = 54f

/**
 * Was als Nächstes ansteht: die wichtigste Antwort der Seite, darum auch der größte Text.
 * Rechts oben, an immer derselben Stelle, das laute Plus und klein die selten gebrauchte Glocke.
 */
@Composable
private fun CalendarHeader(next: CalendarEntry?, size: Float, onPick: (CalendarEntry) -> Unit, onBell: () -> Unit, onAdd: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxWidth()) {
        if (next != null) NextUpView(next, size, 96.dp, Modifier.clickable { onPick(next) })
        else Text(L.t("Gerade steht nichts an."), fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = (size * .56f).sp, color = p.ink2, modifier = Modifier.padding(end = 96.dp).heightIn(min = 46.dp))
        Row(Modifier.align(Alignment.TopEnd), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            RoundButton(Sym.BELL, L.t("Erinnerungen und Kalender"), 40.dp, p.ink3, onBell)
            Box(Modifier.size(46.dp).clip(CircleShape).background(p.accent).clickable(onClick = onAdd).semantics { contentDescription = L.t("Neuer Termin") }, contentAlignment = Alignment.Center) {
                LineIcon(Sym.ADD, Color.White, 24.dp)
            }
        }
    }
}

/** „Noch 2 Tage“ und der Termin, am selben Tag in Stunden und Minuten. Die Größe richtet sich nach dem Gerät. */
@Composable
private fun NextUpView(e: CalendarEntry, size: Float, reserved: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val line = NextUp.remaining(e)
    val date = dateLine(e)
    Column(modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = "$line, ${e.plainTitle}, $date" }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FitText(line, androidx.compose.ui.text.TextStyle(fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = size.sp, color = p.accent), Modifier.padding(end = reserved), (size * .7f).sp)
        Text(e.plainTitle, fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = (size * .56f).sp, lineHeight = (size * .68f).sp, color = p.ink, maxLines = 2)
        Text(date, fontSize = 15.sp, color = p.ink2)
    }
}

/** Wann der Termin ist: Wochentag, Datum und, wenn es welche gibt, die Uhrzeiten bis zum Ende. */
private fun dateLine(e: CalendarEntry): String = e.whenText

private sealed interface MonthExit { data class Bottom(val x: Float) : MonthExit; data class Side(val margin: Float) : MonthExit }
sealed interface LeashEntry { object Top : LeashEntry; data class Side(val margin: Float, val y: Float) : LeashEntry }

/** Ein Zeitraum über dem Monat, etwa die Zecken-Saison. */
@Composable
private fun Periods(month: Day, entries: List<CalendarEntry>) {
    val p = LocalPalette.current
    val today = Day.today()
    val last = Day(month.year, month.month, Day.daysIn(month.year, month.month))
    entries.filter { it.isPeriod && it.end >= month && it.start <= last }.forEach { e ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(kindColor(e.kind, p)))
            Text(e.plainTitle, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = p.ink2)
            Text(if (e.covers(today)) L.t("bis %1\$s", e.end.shortText) else L.t("%1\$s bis %2\$s", e.start.shortText, e.end.shortText), fontSize = 13.sp, color = p.ink3)
        }
    }
}

@Composable
private fun MonthPane(month: Day, selected: Day, onSelect: (Day) -> Unit, onShift: (Int) -> Unit, entries: List<CalendarEntry>, roomy: Boolean, dense: Boolean, margin: Float, exit: MonthExit, onExit: (Float) -> Unit) {
    val p = LocalPalette.current
    val today = Day.today()
    Column(Modifier.padding(horizontal = margin.dp), verticalArrangement = Arrangement.spacedBy(if (dense) 6.dp else 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            // Der längste Monatsname („September“) muss auch in eine Hälfte passen: lieber kleiner als abgeschnitten.
            val big = if (dense) 26.sp else if (roomy) 36.sp else 34.sp
            val small = if (dense) 22.sp else if (roomy) 28.sp else 26.sp
            androidx.compose.foundation.text.BasicText(androidx.compose.ui.text.buildAnnotatedString {
                append(Day.MONTH[month.month - 1])
                pushStyle(androidx.compose.ui.text.SpanStyle(fontWeight = FontWeight.Normal, color = p.ink3)); append(" ${month.year}"); pop()
            }, Modifier.weight(1f), style = androidx.compose.ui.text.TextStyle(fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = big, color = p.ink), maxLines = 1, softWrap = false,
                autoSize = androidx.compose.foundation.text.TextAutoSize.StepBased(small, big, 1.sp))
            if (month != today.firstOfMonth) Text(L.t("Heute"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.accent,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(p.soft).clickable { onSelect(today) }.padding(horizontal = 12.dp, vertical = 5.dp))
            RoundButton(Sym.LEFT, L.t("Vorheriger Monat"), 36.dp, p.ink2) { onShift(-1) }
            RoundButton(Sym.RIGHT, L.t("Nächster Monat"), 36.dp, p.ink2) { onShift(1) }
        }
        Periods(month, entries)
        AnimatedContent(month, label = L.t("Monat")) { m -> MonthGrid(m, selected, onSelect, onShift, entries, roomy, dense, exit, onExit) }
    }
}

/** Der Monat darunter: nur Name und Raster, geblättert wird oben. */
@Composable
private fun SecondMonth(month: Day, selected: Day, onSelect: (Day) -> Unit, entries: List<CalendarEntry>, onExit: (Float) -> Unit) {
    val p = LocalPalette.current
    Column(Modifier.padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(Day.MONTH[month.month - 1], fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 28.sp, color = p.ink, maxLines = 1)
            Text("${month.year}", fontFamily = Display, fontSize = 28.sp, color = p.ink3)
        }
        Periods(month, entries)
        MonthGrid(month, selected, onSelect, {}, entries, true, false, MonthExit.Side(24f), onExit)
    }
}

/**
 * Der Monat: immer ganze Wochen. Heute ist ausgefüllt, ein anderer gewählter Tag dunkel. Mehrtägiges liegt als Band
 * hinter den Tagen, einzelne Termine sind Punkte. Vom gewählten Tag läuft ein Bogen hinter den Zahlen zur Zeitleine.
 */
@Composable
private fun MonthGrid(month: Day, selected: Day, onSelect: (Day) -> Unit, onShift: (Int) -> Unit, entries: List<CalendarEntry>, roomy: Boolean, dense: Boolean, exit: MonthExit, onExit: (Float) -> Unit) {
    val p = LocalPalette.current
    val today = Day.today()
    val count = Day.daysIn(month.year, month.month)
    val last = Day(month.year, month.month, count)
    val cells = remember(month) {
        val lead = month.weekdayFromMonday
        val out = (lead downTo 1).map { month.addingDays(-it) }.toMutableList()
        out += (1..count).map { Day(month.year, month.month, it) }
        var n = last; while (out.size % 7 != 0) { n = n.addingDays(1); out += n }
        out.toList()
    }
    val visible = entries.filter { !it.isPeriod && it.end >= month && it.start <= last }
    val dots = remember(month, entries) {
        val out = mutableMapOf<Day, MutableList<EntryKind>>()
        for (e in visible) if (e.spanDays == 1) { val l = out.getOrPut(e.start) { mutableListOf() }; if (e.kind !in l) l += e.kind }
        out
    }
    val bands = remember(month, entries) {
        val out = mutableSetOf<Day>()
        for (e in visible) if (e.spanDays > 1) { var d = maxOf(e.start, month); while (d <= minOf(e.end, last)) { out += d; d = d.addingDays(1) } }
        out
    }
    val cellH = if (dense) 39f else if (roomy) 62f else 48f; val disc = if (dense) 31f else if (roomy) 42f else 36f; val rowGap = if (dense) 0f else if (roomy) 6f else 2f
    val drawn = remember { Animatable(1f) }
    LaunchedEffect(selected) { drawn.snapTo(0f); drawn.animateTo(1f, tween(550)) }
    val density = LocalDensity.current
    Column(Modifier.pointerInput(month) {
        var dx = 0f
        detectHorizontalDragGestures(onDragEnd = { if (dx < -80) onShift(1) else if (dx > 80) onShift(-1); dx = 0f }) { _, d -> dx += d }
    }) {
        Row { Day.WEEKDAY_SHORT.forEach { Text(it, Modifier.weight(1f), fontSize = 12.sp, fontWeight = FontWeight.Medium, color = p.ink3, textAlign = TextAlign.Center) } }
        Spacer(Modifier.height(if (dense) 4.dp else 8.dp))
        Box {
            Canvas(Modifier.matchParentSize().onGloballyPositioned { c ->
                val i = cells.indexOf(selected)
                if (selected in month..last && i >= 0) onExit(c.positionInWindow().y + with(density) { minOf(((i / 7) * (cellH + rowGap) + disc / 2 + cellH).dp.toPx(), c.size.height.toFloat()) })
            }) {
                val w = size.width / 7; val h = cellH.dp.toPx(); val r = disc.dp.toPx(); val rowStep = (cellH + rowGap).dp.toPx()
                fun center(d: Day): Offset? = cells.indexOf(d).takeIf { it >= 0 }?.let { Offset((it % 7 + .5f) * w, (it / 7) * rowStep + r / 2) }
                for (e in visible) if (e.spanDays > 1) {
                    var a = maxOf(e.start, month); val end = minOf(e.end, last)
                    while (a <= end) {
                        val b = minOf(a.addingDays(6 - a.weekdayFromMonday), end)
                        val ca = center(a); val cb = center(b)
                        if (ca != null && cb != null) drawRoundRect(kindColor(e.kind, p).copy(alpha = .14f), Offset(ca.x - r / 2, ca.y - r / 2), Size(cb.x - ca.x + r, r), CornerRadius(r / 2))
                        a = b.addingDays(1)
                    }
                }
                val c = if (selected in month..last) center(selected) else null
                if (c != null) {
                    val to: Offset; val c1: Offset; val c2: Offset
                    when (exit) {
                        is MonthExit.Bottom -> { to = Offset(exit.x.dp.toPx(), size.height + 1); val drop = to.y - c.y; c1 = Offset(c.x + 10.dp.toPx(), c.y + drop * .55f); c2 = Offset(to.x, to.y - drop * .45f) }
                        is MonthExit.Side -> { to = Offset(size.width + exit.margin.dp.toPx(), minOf(c.y + h, size.height)); val run = to.x - c.x; c1 = Offset(c.x + run * .2f, c.y + h * 1.1f); c2 = Offset(to.x - run * .4f, to.y + 6.dp.toPx()) }
                    }
                    val path = Path().apply { moveTo(c.x, c.y); cubicTo(c1.x, c1.y, c2.x, c2.y, to.x, to.y) }
                    val part = Path(); PathMeasure().apply { setPath(path, false); getSegment(0f, length * drawn.value, part, true) }
                    drawPath(part, p.accent.copy(alpha = .5f), style = Stroke(1.5.dp.toPx(), cap = StrokeCap.Round))
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(rowGap.dp)) {
                cells.chunked(7).forEach { week ->
                    Row {
                        week.forEach { d ->
                            val inMonth = d in month..last
                            val isToday = d == today && inMonth; val isSel = d == selected && inMonth
                            Box(Modifier.weight(1f).height(cellH.dp), contentAlignment = Alignment.TopCenter) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clickable { onSelect(d) }.semantics { contentDescription = "${d.day}. ${Day.MONTH[d.month - 1]}${if (isToday) ", heute" else ""}" }) {
                                    val fill = when { isSel && isToday -> p.accent; isSel -> p.ink; else -> Color.Transparent }
                                    // Die Leine läuft hinter der Zahl vorbei, nicht durch sie hindurch; zwischen den Zahlen bleibt sie sichtbar.
                                    Box(Modifier.size(disc.dp).clip(CircleShape).background(fill).drawBehind { if (!isSel && d !in bands) drawCircle(p.paper, size.minDimension / 2 - 4.dp.toPx()) }, contentAlignment = Alignment.Center) {
                                        Text("${d.day}", fontFamily = Display, fontSize = if (dense) 15.sp else if (roomy) 18.sp else 17.sp, fontWeight = if (isToday || isSel) FontWeight.SemiBold else FontWeight.Normal,
                                            color = when { isSel && isToday -> Color.White; isSel -> p.paper; isToday -> p.accent; !inMonth -> p.ink3.copy(alpha = .55f); d < today -> p.ink3; else -> p.ink })
                                    }
                                    Row(horizontalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.height(8.dp).padding(top = 3.dp)) {
                                        if (inMonth) dots[d].orEmpty().take(3).forEach { k -> Box(Modifier.size(5.dp).clip(CircleShape).background(kindColor(k, p))) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Die Zeitleine: eine locker hängende Leine, an der die Termine wie Knoten sitzen; in langen Pausen eine Schlinge. */
@Composable
fun TimeLeash(start: Day, entries: List<CalendarEntry>, entry: LeashEntry, onSelect: (CalendarEntry) -> Unit, onAdd: (Day) -> Unit) {
    val p = LocalPalette.current
    val dateH = 20f; val rowH = 46f; val lead = 22f; val textX = 84f
    val layout = remember(start, entries) { LeashLayout(start, entries, 13f, dateH, rowH, 18f) }
    val today = Day.today()
    val drawn = remember { Animatable(1f) }
    LaunchedEffect(start) { drawn.snapTo(0f); drawn.animateTo(1f, tween(600)) }
    fun xAt(y: Float): Float {
        val ease = minOf(1f, y / 70f)
        return LEASH_X + (kotlin.math.sin(y / 47f + .8f) * 3.6f + kotlin.math.sin(y / 113f + 2.1f) * 3.2f) * ease * ease
    }
    Box(Modifier.fillMaxWidth().height((lead + layout.height + 8).dp)) {
        Canvas(Modifier.matchParentSize()) {
            val px = { v: Float -> v.dp.toPx() }
            val y0 = lead + dateH / 2
            val loops = layout.gaps.filter { it.days >= 7 }.map { lead + it.y + dateH / 2 + 4 }
            val pts = mutableListOf<Offset>()
            var y = if (entry is LeashEntry.Side) y0 else 0f
            val end = lead + layout.height
            val done = mutableSetOf<Int>()
            while (y <= end) {
                val i = loops.indexOfFirst { kotlin.math.abs(it - y) < 16 }
                if (i >= 0) { if (done.add(i)) pts += leashLoop(Offset(px(xAt(loops[i])), px(loops[i])), px(7f), -1f) }
                else pts += Offset(px(xAt(y)), px(y))
                y += 14f
            }
            val line = leashCurve(pts)
            val part = Path(); PathMeasure().apply { setPath(line, false); getSegment(0f, length * drawn.value, part, true) }
            drawPath(part, p.accent.copy(alpha = .5f), style = Stroke(px(1.5f), cap = StrokeCap.Round))
            if (entry is LeashEntry.Side) {
                val joinY = maxOf(y0, entry.y + 40f)
                val to = Offset(px(xAt(joinY)), px(joinY)); val from = Offset(px(-entry.margin), px(entry.y))
                val branch = Path().apply { moveTo(from.x, from.y); cubicTo(from.x + (to.x - from.x) * .7f, from.y, to.x, to.y - kotlin.math.abs(to.y - from.y) * .6f - px(10f), to.x, to.y) }
                drawPath(branch, p.accent.copy(alpha = .5f), style = Stroke(px(1.5f), cap = StrokeCap.Round))
            }
            for (s in layout.spans) {
                val from = lead + s.from + dateH / 2; val to = lead + s.to + dateH / 2
                val q = generateSequence(from) { it + 8f }.takeWhile { it < to }.map { Offset(px(xAt(it)), px(it)) }.toList() + Offset(px(xAt(to)), px(to))
                drawPath(leashCurve(q), kindColor(s.kind, p).copy(alpha = .2f), style = Stroke(px(10f), cap = StrokeCap.Round))
            }
            for (n in layout.nodes) {
                val cy = lead + n.y + dateH / 2; val c = Offset(px(xAt(cy)), px(cy))
                if (n.day == today) drawCircle(p.accent, px(6f), c)
                else { drawCircle(p.paper, px(5f), c); drawCircle(n.entries.firstOrNull()?.let { kindColor(it.kind, p) } ?: p.ink3, px(5f), c, style = Stroke(px(1.8f))) }
            }
        }
        layout.gaps.forEach { g ->
            Text(L.t("%1\$s Tage", g.days), fontSize = 11.sp, color = p.ink3, textAlign = TextAlign.End, modifier = Modifier.width((LEASH_X - 16).dp).offset(y = (lead + g.y + dateH / 2 + 6).dp))
        }
        layout.nodes.forEach { n ->
            Column(Modifier.padding(start = textX.dp).offset(y = (lead + n.y).dp).fillMaxWidth()) {
                Text(dateLabel(n.day, today), fontSize = 13.sp, fontWeight = FontWeight.Medium, color = p.ink3, modifier = Modifier.height(dateH.dp))
                if (n.entries.isEmpty()) Row(Modifier.height(rowH.dp).clickable { onAdd(n.day) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    LineIcon(Sym.ADD, p.accent, 20.dp); Text(L.t("Termin anlegen"), fontSize = 16.sp, color = p.accent)
                }
                n.entries.forEach { e ->
                    Column(Modifier.height(rowH.dp).fillMaxWidth().clickable(enabled = e.isEditable) { onSelect(e) }, verticalArrangement = Arrangement.Center) {
                        Text(e.plainTitle, fontFamily = Display, fontWeight = FontWeight.Medium, fontSize = 17.sp, color = if (e.isEditable) p.ink else p.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        val m = meta(e); if (m.isNotEmpty()) Text(m, fontSize = 13.sp, color = p.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

private fun dateLabel(d: Day, today: Day) = when (today.daysUntil(d)) {
    0 -> L.t("Heute"); 1 -> L.t("Morgen"); 2 -> L.t("Übermorgen"); else -> "${Day.WEEKDAY_SHORT[d.weekdayFromMonday]} ${d.shortText}"
}

private fun meta(e: CalendarEntry): String {
    val parts = mutableListOf<String>()
    e.timeText?.let { parts += it }
    e.untilText?.let { parts += it }
    e.repetition?.let { parts += it.label.replaceFirstChar { c -> c.lowercase() } }
    if (parts.isEmpty() && !e.isEditable) parts += e.kind.label
    return parts.joinToString(", ")
}

/** Termin anlegen oder bearbeiten – Titel, Beginn und Ende (ganztägig oder mit Uhrzeit), Wiederholung, Notiz. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EventEditor(event: DogEvent, isNew: Boolean, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    var e by remember { mutableStateOf(event) }
    var timing by remember { mutableStateOf(EventTiming.of(event, isNew)) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.paper) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(if (isNew) L.t("Neuer Termin") else L.t("Termin"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 30.sp, color = p.ink)
            OutlinedTextField(e.title, { e = e.copy(title = it) }, label = { Text(L.t("Titel")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.surface).padding(horizontal = 14.dp, vertical = 6.dp)) {
                // Ganztägig umschalten behält die Tage; die Uhrzeiten bleiben für den Rückweg erhalten.
                Row(Modifier.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(L.t("Ganztägig"), Modifier.weight(1f), color = p.ink)
                    Switch(timing.allDay, { timing = timing.copy(allDay = it) }, colors = SwitchDefaults.colors(checkedTrackColor = p.accent))
                }
                TimingRow(L.t("Beginn"), timing.begin, !timing.allDay, false) { timing = timing.movingBegin(it) }
                TimingRow(L.t("Ende"), timing.finish, !timing.allDay, !timing.isValid) { timing = timing.copy(finish = it) }
            }
            if (!timing.isValid) Text(L.t("Das Ende liegt vor dem Beginn."), fontSize = 14.sp, color = p.health)
            Text(L.t("Wiederholen"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                (listOf(null) + Repetition.entries).forEach { r ->
                    val on = e.rule == r
                    FilterChip(on, { e = e.copy(repetition = r?.key ?: "") }, label = { Text(r?.label ?: L.t("Nicht")) })
                }
            }
            OutlinedTextField(e.notes, { e = e.copy(notes = it) }, label = { Text(L.t("Notiz")) }, modifier = Modifier.fillMaxWidth(), minLines = 2)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                if (!isNew) TextButton({ Graph.store.deleteEvent(e.id); onDismiss() }) { Text(L.t("Löschen"), color = p.health) }
                Spacer(Modifier.weight(1f))
                Button({ Graph.store.save(timing.applied(e)); onDismiss() }, enabled = e.title.isNotBlank() && timing.isValid) { Text(L.t("Sichern")) }
            }
        }
    }
}

/** Eine Zeile „Beginn“ oder „Ende“: Tag und, wenn nicht ganztägig, Uhrzeit – jeweils ein Feld, das seine Auswahl öffnet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimingRow(label: String, at: java.time.LocalDateTime, withTime: Boolean, wrong: Boolean, onChange: (java.time.LocalDateTime) -> Unit) {
    val p = LocalPalette.current
    var pickDay by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }
    val day = Day(at.toLocalDate())
    val color = if (wrong) p.health else p.ink
    @Composable fun Pill(text: String, describe: String, onClick: () -> Unit) =
        Text(text, color = color, fontWeight = FontWeight.Medium, modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(p.paper).clickable(onClick = onClick)
            .semantics { contentDescription = describe }.padding(horizontal = 10.dp, vertical = 6.dp))
    Row(Modifier.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, Modifier.weight(1f), color = p.ink)
        val dayText = CalendarEntry.dayText(day) + if (day.year != Day.today().year) " ${day.year}" else ""
        Pill(dayText, "$label: $dayText") { pickDay = true }
        if (withTime) { val t = CalendarEntry.clockText(at.hour to at.minute); Pill(t, "$label: ${L.t("%1\$s Uhr", t)}") { pickTime = true } }
    }
    if (pickDay) {
        val zone = java.time.ZoneOffset.UTC
        val state = rememberDatePickerState(at.toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli())
        DatePickerDialog({ pickDay = false }, confirmButton = {
            TextButton({ state.selectedDateMillis?.let { onChange(java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate().atTime(at.toLocalTime())) }; pickDay = false }) { Text(L.t("Fertig"), color = p.accent) }
        }, dismissButton = { TextButton({ pickDay = false }) { Text(L.t("Abbrechen"), color = p.ink) } }) { DatePicker(state) }
    }
    if (pickTime) {
        val state = rememberTimePickerState(at.hour, at.minute, is24Hour = true)
        AlertDialog({ pickTime = false }, containerColor = p.paper,
            confirmButton = { TextButton({ onChange(at.toLocalDate().atTime(state.hour, state.minute)); pickTime = false }) { Text(L.t("Fertig"), color = p.accent) } },
            dismissButton = { TextButton({ pickTime = false }) { Text(L.t("Abbrechen"), color = p.ink) } },
            text = { TimePicker(state) })
    }
}
