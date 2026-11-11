package app.thisdog.ui

import app.thisdog.i18n.L
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.TextButton
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Graph
import app.thisdog.model.*

fun verdictColor(v: Food.Verdict, p: Palette) = when (v) { Food.Verdict.OK -> p.ok; Food.Verdict.WARN -> p.warning; Food.Verdict.BAD -> p.health }

/** Zum Ansehen (Entwicklerfassung): `--ez ratgeber true`, `--es suche Trauben`. */
object KnowledgeDemo { var ratgeber = false; var suche = "" }

/** Wissen: Food-Check und Ratgeber. */
@Composable
fun KnowledgeScreen(wide: Boolean) {
    val p = LocalPalette.current
    val quer = isQuer()
    var tips by remember { mutableStateOf(KnowledgeDemo.ratgeber) }
    Column(Modifier.fillMaxSize().background(p.paper).statusBarsPadding()) {
        // Breit und quer links oben, nicht mittig über dem Knick.
        Row(Modifier.fillMaxWidth().padding(horizontal = if (quer) 10.dp else 16.dp).padding(top = 10.dp, bottom = 6.dp), horizontalArrangement = if (wide || quer) Arrangement.Start else Arrangement.Center) {
            // Beide Hälften gleich breit, damit die Markierung auf beiden Seiten gleich aussieht.
            Row(Modifier.width(IntrinsicSize.Max).clip(RoundedCornerShape(50)).background(p.surface).border(1.dp, p.line, RoundedCornerShape(50)).padding(5.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf(false to L.t("Food-Check"), true to L.t("Ratgeber")).forEach { (t, l) ->
                    Text(l, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (tips == t) p.accent else p.ink, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        maxLines = 1, softWrap = false,
                        modifier = Modifier.weight(1f).selectionPill(tips == t).clickable { tips = t }.padding(horizontal = 16.dp, vertical = 9.dp))
                }
            }
        }
        Box(Modifier.weight(1f)) { if (tips) TipsScreen(wide, quer) else FoodCheck(wide, quer) }
    }
}

/** Was am häufigsten gefragt wird – dieselbe Liste wie auf iOS. */
val FREQUENT = listOf(L.t("Schokolade"), L.t("Trauben"), L.t("Xylit"), L.t("Zwiebel"), L.t("Knoblauch"), L.t("Käse (hart, laktosearm)"), L.t("Banane"),
    L.t("Apfel (ohne Kerne)"), L.t("Karotte (roh oder gekocht)"), L.t("Gurke"), L.t("Erdbeeren"), L.t("Huhn (gekocht)"), L.t("Reis (gekocht)"))

/** „Darf mein Hund …?“: Suche mit Antwort, sobald es einen klaren Treffer gibt. Quer links suchen, rechts die Antwort. */
@Composable
private fun FoodCheck(wide: Boolean, quer: Boolean) {
    val c = Graph.content
    var query by remember { mutableStateOf(KnowledgeDemo.suche) }
    var picked by remember { mutableStateOf<Food?>(null) }
    var category by remember { mutableStateOf<String?>(null) }
    val hits = remember(query, c.search) { c.search.search(query, 12) }
    val answer = picked ?: hits.firstOrNull()?.food
    val bottom = dockClearance()
    // Foto und Strichcode: Was ein Foto ergeben hat, bleibt als Auswahl sichtbar, solange einer davon gesucht wird.
    var photoTerms by remember { mutableStateOf<List<String>>(emptyList()) }
    var product by remember { mutableStateOf<app.thisdog.model.ScannedProduct.Result?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val (takePhoto, pickPhoto) = rememberFoodScanner({ t -> photoTerms = t; query = t.first(); picked = null; category = null }, { message = it }) { product = it }
    product?.let { ProductSheet(it) { product = null } }
    message?.let { m -> AlertDialog({ message = null }, confirmButton = { TextButton({ message = null }) { Text(L.t("OK")) } }, text = { Text(m) }, containerColor = LocalPalette.current.paper) }
    val search: @Composable () -> Unit = {
        SearchField(query, wide && !quer, { query = it; picked = null; category = null }, { query = ""; picked = null }, takePhoto, pickPhoto)
        if (photoTerms.size > 1 && query in photoTerms) PhotoChoices(photoTerms, query) { query = it; picked = null }
    }
    val list: @Composable () -> Unit = { FoodList(query, hits.map { it.food }, answer, picked, category, wide || quer, { picked = it }, { category = it }) }
    val frequent: @Composable () -> Unit = { Frequent(picked) { picked = if (picked == it) null else it } }
    when {
        // Die Tastatur lässt hier nur die linke Spalte brauchbar.
        quer -> Row(Modifier.fillMaxSize().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Column(Modifier.width(320.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) { search(); list() }
            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(top = 8.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) { answer?.let { AnswerCard(it) }; frequent() }
        }
        wide -> Row(Modifier.fillMaxSize()) {
            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).padding(top = 12.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(22.dp)) { search(); list() }
            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).padding(top = 12.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(32.dp)) { answer?.let { AnswerCard(it) }; frequent(); Overview(true) { picked = it } }
        }
        else -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 12.dp, bottom = bottom), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            search()
            if (answer != null && (query.isNotEmpty() || picked != null)) AnswerCard(answer)
            if (query.isEmpty() && category == null) frequent()
            list()
        }
    }
}

/** Nach einem Foto: Was die Bilderkennung sonst noch für möglich hält. */
@Composable
private fun PhotoChoices(terms: List<String>, query: String, onPick: (String) -> Unit) {
    val p = LocalPalette.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(L.t("Auf dem Foto:"), fontSize = 14.sp, color = p.ink2)
        terms.forEach { t ->
            val on = t == query
            Text(t, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.clip(RoundedCornerShape(50))
                .background(if (on) p.soft else p.surface).clickable { onPick(t) }.padding(horizontal = 12.dp, vertical = 7.dp))
        }
    }
}

@Composable
private fun SearchField(query: String, big: Boolean, onChange: (String) -> Unit, onClear: () -> Unit, onCamera: () -> Unit, onLibrary: () -> Unit) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FitText(L.t("Darf mein Hund …?"), TextStyle(fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = if (big) 40.sp else 32.sp, color = p.ink), minSize = 24.sp)
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.surface).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            LineIcon(Sym.SEARCH, p.ink3, 24.dp)
            Box(Modifier.weight(1f)) {
                if (query.isEmpty()) Text(L.t("z. B. Trauben, Käse, Banane"), fontSize = 19.sp, color = p.ink3, maxLines = 1)
                BasicTextField(query, onChange, textStyle = TextStyle(fontSize = 19.sp, color = p.ink), cursorBrush = SolidColor(p.accent), singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            if (query.isNotEmpty()) LineIcon(Sym.CLEAR, p.ink3, 22.dp, Modifier.clickable(onClick = onClear).semantics { contentDescription = L.t("Leeren") })
            Box {
                var menu by remember { mutableStateOf(false) }
                LineIcon(Sym.CAMERA, p.accent, 24.dp, Modifier.clickable { menu = true }.semantics { contentDescription = L.t("Foto oder Strichcode") })
                DropdownMenu(menu, { menu = false }, containerColor = p.surface) {
                    DropdownMenuItem({ Text(L.t("Foto aufnehmen")) }, { menu = false; onCamera() }, leadingIcon = { LineIcon(Sym.CAMERA, p.ink, 20.dp) })
                    DropdownMenuItem({ Text(L.t("Aus der Mediathek")) }, { menu = false; onLibrary() }, leadingIcon = { LineIcon(Sym.GALLERY, p.ink, 20.dp) })
                }
            }
        }
        Text(L.t("Tipp: Essen oder Strichcode fotografieren."), fontSize = 13.sp, color = p.ink3)
    }
}

@Composable
private fun FoodList(query: String, hits: List<Food>, answer: Food?, picked: Food?, category: String?, side: Boolean, onPick: (Food) -> Unit, onCategory: (String?) -> Unit) {
    val p = LocalPalette.current
    val c = Graph.content
    when {
        query.isNotEmpty() ->
            if (hits.isEmpty()) Text(L.t("„%1\$s“ steht nicht in der Liste. Im Zweifel nicht füttern und in der Praxis fragen.", query), fontSize = 15.sp, color = p.ink2)
            else FoodRows(hits, if (side) answer else null, onPick)
        category != null -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.clip(RoundedCornerShape(50)).clickable { onCategory(null) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                LineIcon(Sym.LEFT, p.accent, 18.dp); Text(L.t("Alle Kategorien"), fontSize = 15.sp, color = p.accent)
            }
            Text(category, fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 24.sp, color = p.ink)
            val rank = mapOf(Food.Verdict.BAD to 0, Food.Verdict.WARN to 1, Food.Verdict.OK to 2)
            FoodRows(c.foods.filter { it.category == category }.sortedWith(compareBy({ rank[it.verdict] }, { it.name })), if (side) picked else null, onPick)
        }
        else -> Column(verticalArrangement = Arrangement.spacedBy(22.dp)) {
            if (!side) Overview(false, onPick)
            Categories(onCategory)
        }
    }
}

@Composable
private fun FoodRows(foods: List<Food>, highlight: Food?, onPick: (Food) -> Unit) {
    val p = LocalPalette.current
    Column {
        foods.forEach { f ->
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if (highlight == f) p.soft else Color.Transparent).clickable { onPick(f) }.padding(vertical = 9.dp, horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(verdictColor(f.verdict, p)))
                Column(Modifier.weight(1f)) { Text(f.name, fontWeight = FontWeight.SemiBold, color = p.ink); Text(f.verdictLabel, fontSize = 15.sp, color = p.ink2) }
                if (Graph.store.isFavorite(f)) LineIcon(Sym.HEART, p.accent, 18.dp)
            }
        }
    }
}

/** Was am häufigsten gefragt wird: ein Tipp, und die Antwort steht da. */
@Composable
private fun Frequent(picked: Food?, onPick: (Food) -> Unit) {
    val p = LocalPalette.current
    val foods = FREQUENT.mapNotNull { n -> Graph.content.foods.firstOrNull { it.name == n } }
    if (foods.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Title(L.t("Oft gefragt"))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            foods.forEach { f ->
                val on = picked == f
                Row(Modifier.clip(RoundedCornerShape(50)).background(if (on) p.soft else p.surface).border(1.dp, if (on) p.accent.copy(alpha = .4f) else p.line, RoundedCornerShape(50))
                    .clickable { onPick(f) }.padding(horizontal = 13.dp, vertical = 9.dp).semantics(mergeDescendants = true) { contentDescription = "${f.name}, ${f.verdictLabel}" }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(verdictColor(f.verdict, p)))
                    Text(f.name.substringBefore(" ("), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
                }
            }
        }
    }
}

/** Die Merkliste, sonst breit der Überblick über alle Lebensmittel. */
@Composable
private fun Overview(big: Boolean, onPick: (Food) -> Unit) {
    val p = LocalPalette.current
    val foods = Graph.content.foods
    val favs = foods.filter { Graph.store.isFavorite(it) }
    if (favs.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Title(L.t("Merkliste")); FoodRows(favs, null, onPick)
    } else if (big) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(L.t("%1\$d Lebensmittel", foods.size), fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 40.sp, color = p.ink)
        VerdictBar(foods, Modifier.fillMaxWidth().height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            listOf(Food.Verdict.OK to L.t("erlaubt"), Food.Verdict.WARN to L.t("mit Vorsicht"), Food.Verdict.BAD to L.t("nicht geeignet")).forEach { (v, t) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(verdictColor(v, p)))
                    Text("${foods.count { it.verdict == v }} $t", fontSize = 15.sp, color = p.ink2)
                }
            }
        }
    }
}

/** Jede Kategorie mit einem Streifen: wie viel darin erlaubt, mit Vorsicht, nicht geeignet ist. */
@Composable
private fun Categories(onCategory: (String) -> Unit) {
    val p = LocalPalette.current
    val groups = Graph.content.foods.groupBy { it.category }.entries.sortedByDescending { it.value.size }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Title(L.t("Kategorien"))
        Spacer(Modifier.height(2.dp))
        groups.forEach { (name, foods) ->
            Column(Modifier.fillMaxWidth().clickable { onCategory(name) }.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row { Text(name, fontWeight = FontWeight.SemiBold, color = p.ink, modifier = Modifier.weight(1f)); Text("${foods.size}", fontSize = 15.sp, color = p.ink3) }
                VerdictBar(foods, Modifier.fillMaxWidth().height(6.dp))
            }
        }
    }
}

/** Anteile erlaubt, mit Vorsicht, nicht geeignet als ein Streifen. */
@Composable
private fun VerdictBar(foods: List<Food>, modifier: Modifier) {
    val p = LocalPalette.current
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        listOf(Food.Verdict.OK, Food.Verdict.WARN, Food.Verdict.BAD).forEach { v ->
            val n = foods.count { it.verdict == v }
            if (n > 0) Box(Modifier.weight(n.toFloat()).fillMaxHeight().clip(RoundedCornerShape(50)).background(verdictColor(v, p)))
        }
    }
}

/** Die Antwort: Zeichen, Urteil, Begründung. */
@Composable
private fun AnswerCard(f: Food) {
    val p = LocalPalette.current
    val color = verdictColor(f.verdict, p)
    val favorite = Graph.store.isFavorite(f)
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(p.surface).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(56.dp).clip(CircleShape).background(color), contentAlignment = Alignment.Center) {
                LineIcon(when (f.verdict) { Food.Verdict.OK -> Sym.CHECK; Food.Verdict.BAD -> Sym.CLOSE; else -> Sym.ALERT }, Color.White, 35.dp)
            }
            Column(Modifier.weight(1f)) {
                FitText(f.verdictLabel, TextStyle(fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 28.sp, color = color), minSize = 20.sp)
                Text(f.name, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, color = p.ink)
            }
            // Keine gefüllte Form im Linien-Stil: Gemerkt ist an der Farbe zu erkennen.
            RoundButton(Sym.HEART, if (favorite) L.t("Von der Merkliste nehmen") else L.t("Auf die Merkliste"), 44.dp, if (favorite) p.accent else p.ink3) { Graph.store.toggleFavorite(f) }
        }
        Text(f.reason, color = p.ink)
        f.aliases?.takeIf { it.isNotEmpty() }?.let { Text(L.t("Auch: %1\$s", it.joinToString(", ")), fontSize = 13.sp, color = p.ink2) }
        Text(f.category, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink3)
    }
}

/** Der Ratgeber: oben, was gerade passt (Jahreszeit, Lebensphase), darunter alle Tipps. Quer und breit links die Auswahl, rechts der Text. */
@Composable
private fun TipsScreen(wide: Boolean, quer: Boolean) {
    val p = LocalPalette.current
    val c = Graph.content
    val season = Season.of(Day.today())
    val stage = TipRanking.stageKey(Graph.store.profile.stage())
    var opened by remember { mutableStateOf<Tip?>(null) }
    var category by remember { mutableStateOf<String?>(null) }
    val rec = c.tips.map { it to TipRanking.score(it, season, stage) }.filter { it.second >= 3 }.sortedWith(compareBy({ -it.second }, { it.first.id })).take(3).map { it.first }
    val shown = c.tips.filter { category == null || it.category == category }
    val current = opened ?: rec.firstOrNull() ?: c.tips.firstOrNull()
    val name = Graph.store.profile.name
    val title = if (name.isEmpty()) L.t("Passend zum %1\$s", season.label) else L.t("Für %1\$s im %2\$s", name, season.label)
    val bottom = dockClearance()
    val chips: @Composable () -> Unit = {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip(L.t("Alle"), category == null) { category = null }
            c.tips.map { it.category }.toSet().sorted().forEach { k -> Chip(k, category == k) { category = k } }
        }
    }
    when {
        quer -> Row(Modifier.fillMaxSize().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            // Im Ratgeber wird gelesen. Links die Auswahl, rechts der Text, ohne eigenes Fenster.
            Column(Modifier.width(300.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (category == null && rec.isNotEmpty()) {
                    Text(title, fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 27.sp, color = p.ink)
                    rec.forEach { t -> TipRow(t, current?.id == t.id) { opened = t } }
                }
                chips()
                (if (category == null) shown.filter { it !in rec } else shown).forEach { t -> TipRow(t, current?.id == t.id) { opened = t } }
            }
            current?.let { t -> key(t.id) { Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(top = 8.dp, bottom = 24.dp)) { TipDetail(t, true) } } }
        }
        wide -> Row(Modifier.fillMaxSize()) {
            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).padding(top = 12.dp, bottom = bottom)) { TipsOverview(title, 40f, rec, shown, chips, current) { opened = it } }
            current?.let { t -> key(t.id) { Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).padding(top = 12.dp, bottom = bottom)) { TipDetail(t, false) } } }
        }
        else -> {
            val open = opened
            if (open != null) {
                androidx.activity.compose.BackHandler { opened = null }
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 4.dp, bottom = bottom)) {
                    Breadcrumb(L.t("Ratgeber"), open.category, Modifier.padding(bottom = 8.dp)) { opened = null }
                    TipDetail(open, false)
                }
            } else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 12.dp, bottom = bottom)) {
                TipsOverview(title, 32f, rec, shown, chips, null) { opened = it }
            }
        }
    }
}

@Composable
private fun TipsOverview(title: String, size: Float, rec: List<Tip>, shown: List<Tip>, chips: @Composable () -> Unit, current: Tip?, onOpen: (Tip) -> Unit) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(26.dp)) {
        Text(title, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = size.sp, lineHeight = (size * 1.15f).sp, color = p.ink, maxLines = 2)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(14.dp)) { rec.forEach { t -> TipCard(t) { onOpen(t) } } }
        chips()
        Column { shown.forEach { t -> TipRow(t, current?.id == t.id) { onOpen(t) } } }
    }
}

/** Das Bild eines Tipps, vom Server; solange es fehlt, die zarte Fläche. */
@Composable
private fun TipImage(t: Tip, modifier: Modifier) {
    val url = t.remoteImage
    if (url != null) RemoteImage(url, modifier.background(LocalPalette.current.soft), ContentScale.Crop)
    else Box(modifier.background(LocalPalette.current.soft))
}

@Composable
private fun TipCard(t: Tip, onClick: () -> Unit) {
    val p = LocalPalette.current
    Column(Modifier.width(240.dp).clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TipImage(t, Modifier.size(240.dp, 150.dp).clip(RoundedCornerShape(20.dp)))
        Text(t.title, fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, color = p.ink, minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(L.t("%1\$s, %2\$s Min.", t.category, t.minutes), fontSize = 13.sp, color = p.ink2)
    }
}

@Composable
private fun TipRow(t: Tip, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (selected) p.soft else Color.Transparent).clickable(onClick = onClick).padding(8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        TipImage(t, Modifier.size(60.dp).clip(RoundedCornerShape(14.dp)))
        Column(Modifier.weight(1f)) {
            Text(t.title, fontWeight = FontWeight.SemiBold, color = p.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(L.t("%1\$s, %2\$s Min.", t.category, t.minutes), fontSize = 15.sp, color = p.ink2)
        }
    }
}

/** Ein Tipp: Bild und Text. Quer steht das Bild neben dem Titel, damit gleich Text zu sehen ist. */
@Composable
private fun TipDetail(t: Tip, quer: Boolean) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        if (quer) Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            TipImage(t, Modifier.size(132.dp, 100.dp).clip(RoundedCornerShape(20.dp)))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(t.title, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 26.sp, lineHeight = 30.sp, color = p.ink); TipTags(t)
            }
        } else {
            TipImage(t, Modifier.fillMaxWidth().height(220.dp).clip(RoundedCornerShape(24.dp)))
            Text(t.title, fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 34.sp, lineHeight = 39.sp, color = p.ink)
            TipTags(t)
        }
        TipText.blocks(t.content).forEach { b ->
            when (b) {
                is TipText.Block.Heading -> Text(b.t.replace("**", ""), fontFamily = Display, fontWeight = FontWeight.SemiBold, fontSize = 21.sp, color = p.ink, modifier = Modifier.padding(top = 6.dp))
                is TipText.Block.Bullet -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { Box(Modifier.padding(top = 8.dp).size(6.dp).clip(CircleShape).background(p.accent)); Text(b.t.replace("**", ""), color = p.ink) }
                is TipText.Block.Paragraph -> Text(b.t.replace("**", ""), color = p.ink, lineHeight = 23.sp)
            }
        }
    }
}

@Composable
private fun TipTags(t: Tip) {
    val p = LocalPalette.current
    val tags = listOf(t.category) + t.season.orEmpty().mapNotNull { Season.byKey(it)?.label } + L.t("%1\$s Min.", t.minutes)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tags.forEach { Text(it, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2, modifier = Modifier.clip(RoundedCornerShape(50)).background(p.line.copy(alpha = .6f)).padding(horizontal = 10.dp, vertical = 4.dp)) }
    }
}
