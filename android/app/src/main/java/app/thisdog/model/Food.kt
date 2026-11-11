package app.thisdog.model

import app.thisdog.i18n.L
import java.text.Normalizer
import kotlin.math.abs
import kotlinx.serialization.Serializable

/** Ein Lebensmittel aus `foods.json`. */
@Serializable
data class Food(val name: String, val status: String, val category: String, val reason: String, val aliases: List<String>? = null) {
    enum class Verdict { OK, WARN, BAD }
    val verdict get() = when (status) { "ok" -> Verdict.OK; "bad" -> Verdict.BAD; else -> Verdict.WARN }
    val verdictLabel get() = when (verdict) { Verdict.OK -> L.t("Erlaubt"); Verdict.WARN -> L.t("Nur mit Vorsicht"); Verdict.BAD -> L.t("Nicht geeignet") }
}

/** Ein Eintrag auf der Merkliste (Art „favorite“, Kennung = Name). */
@Serializable
data class FavoriteFood(val name: String, override val u: Double = 0.0) : SyncedItem {
    override val id get() = name
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "favorite" }
}

/**
 * Die Suche, Zeile für Zeile wie FoodSearch.swift: Umlaute aufgelöst, Endungen gekappt („Trauben“ ≈ „Traube“),
 * zusammengesetzte Wörter in beide Richtungen, Tippfehler bis zu einer Grenze, jeder Begriff auch ohne Umlaut.
 */
class FoodSearch(foods: List<Food>) {
    data class Hit(val food: Food, val score: Double, val matched: String)
    private data class Term(val t: String, val weight: Double, val raw: String)

    private val entries: List<Pair<Food, List<Term>>> = foods.map { f ->
        val terms = mutableListOf<Term>()
        fun add(raw: String, weight: Double) {
            terms += Term(norm(raw), weight, raw)
            val l = loose(raw)
            if (l != norm(raw)) terms += Term(l, weight, raw)
        }
        add(f.name, 1.0)
        f.aliases.orEmpty().forEach { add(it, 0.92) }
        add(f.category, 0.45)
        f to terms.filter { it.t.isNotEmpty() }
    }

    fun search(raw: String, limit: Int = 10, minScore: Double = 380.0): List<Hit> {
        val q = norm(raw)
        if (q.isEmpty()) return emptyList()
        val qStem = stem(q)
        val words = q.split(" ").filter { it.length > 1 }
        val out = mutableListOf<Hit>()
        for ((food, terms) in entries) {
            var best = 0.0; var matched = ""
            for (term in terms) {
                val s = score(q, qStem, term.t) ?: continue
                val v = s * term.weight
                if (v > best) { best = v; matched = term.raw }
            }
            if (best == 0.0 && words.size > 1 && words.all { w -> terms.any { it.t.contains(w) } }) best = 420.0
            if (best >= minScore) out += Hit(food, best, matched)
        }
        val collator = java.text.Collator.getInstance(app.thisdog.i18n.L.locale)
        out.sortWith { a, b -> if (a.score != b.score) b.score.compareTo(a.score) else collator.compare(a.food.name, b.food.name) }
        return out.take(limit)
    }

    companion object {
        fun norm(s: String): String {
            var v = s.lowercase().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
            v = Normalizer.normalize(v, Normalizer.Form.NFD).replace(Regex("\\p{M}"), "")
            v = v.map { if ("_-–—/.,;:()\"'`!?*".contains(it)) ' ' else it }.joinToString("")
            return v.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        }

        /** Wie `norm`, aber Umlaute ohne e: „Käse“ → „kase“. */
        fun loose(s: String) = norm(s.replace("ä", "a").replace("ö", "o").replace("ü", "u").replace("Ä", "A").replace("Ö", "O").replace("Ü", "U"))

        private val SUFFIXES = listOf("ern", "nen", "en", "er", "es", "em", "e", "n", "s")

        fun stem(w: String): String {
            if (w.length < 5) return w
            for (s in SUFFIXES) if (w.length - s.length >= 4 && w.endsWith(s)) return w.dropLast(s.length)
            return w
        }

        fun editDistance(a: String, b: String, limit: Int = 2): Int {
            if (a == b) return 0
            if (abs(a.length - b.length) > limit) return limit + 1
            if (a.isEmpty() || b.isEmpty()) return maxOf(a.length, b.length)
            var prev = IntArray(b.length + 1) { it }; var cur = IntArray(b.length + 1)
            for (i in 1..a.length) {
                cur[0] = i; var best = cur[0]
                for (j in 1..b.length) {
                    cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
                    best = minOf(best, cur[j])
                }
                if (best > limit) return limit + 1
                prev = cur.copyOf()
            }
            return prev[b.length]
        }

        fun score(q: String, qStem: String, term: String): Double? {
            if (term == q) return 1000.0
            if (term.startsWith(q)) return 880.0 - minOf(60, term.length - q.length)
            if (term.contains(" $q")) return 760.0
            val at = term.indexOf(q)
            if (at > 0) return 690.0 - minOf(40, at * 2)
            if (q.length > term.length && term.length >= 4 && q.contains(term)) return 640.0
            val tStem = stem(term)
            if (qStem.length >= 3 && tStem.length >= 3) {
                if (tStem == qStem) return 820.0
                if (tStem.startsWith(qStem)) return 720.0
                if (qStem.length > tStem.length && qStem.contains(tStem)) return 610.0
            }
            if (q.length >= 4) {
                val limit = if (q.length >= 8) 2 else 1
                val d = editDistance(q, term, limit)
                if (d <= limit) return 560.0 - d * 90
                val head = term.split(" ").firstOrNull() ?: ""
                if (head != term && head.length >= 4) {
                    val dh = editDistance(q, head, limit)
                    if (dh <= limit) return 500.0 - dh * 90
                }
            }
            return null
        }
    }
}
