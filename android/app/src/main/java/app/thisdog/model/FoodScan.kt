package app.thisdog.model

import app.thisdog.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Foto im Food-Check: Die Bilderkennung (ML Kit, auf dem Gerät) liefert englische Begriffe („Banana“);
 * hier wird daraus ein Suchbegriff für die eigene Liste. Dieselbe Zuordnung wie auf iOS.
 */
object FoodPhoto {
    val terms: Map<String, String> = mapOf(
        "almond" to "Mandeln", "apple" to "Apfel", "avocado" to "Avocado", "bagel" to "Brötchen",
        "banana" to "Banane", "bean" to "Bohnen", "bell_pepper" to "Paprika", "birthday_cake" to "Kuchen",
        "blueberry" to "Heidelbeeren", "bread" to "Brot", "broccoli" to "Brokkoli", "butter" to "Butter",
        "cake" to "Kuchen", "cake_regular" to "Kuchen", "caramel" to "Zucker", "carrot" to "Karotte",
        "cashew" to "Cashewkerne", "cauliflower" to "Blumenkohl", "celery" to "Sellerie", "cereal" to "Müsli",
        "cheese" to "Käse", "cheesecake" to "Kuchen", "cherry" to "Kirsche", "chestnut" to "Kastanie",
        "chewing_gum" to "Kaugummi", "chives" to "Schnittlauch", "chocolate" to "Schokolade", "chocolate_chip" to "Schokolade",
        "citrus_fruit" to "Orange", "coconut" to "Kokosnuss", "cookie" to "Kekse", "corn" to "Mais",
        "croissant" to "Croissant", "cucumber" to "Gurke", "cupcake" to "Kuchen", "donut" to "Kuchen",
        "egg" to "Hühnerei", "fig" to "Feige", "fish" to "Fisch", "fried_chicken" to "Huhn",
        "fried_egg" to "Spiegelei", "fruitcake" to "Kuchen", "garlic" to "Knoblauch", "gingerbread" to "Lebkuchen",
        "grape" to "Trauben", "grapefruit" to "Grapefruit", "green_beans" to "Grüne Bohnen", "grilled_chicken" to "Huhn",
        "guava" to "Guave", "ham" to "Kochschinken", "honey" to "Honig", "kiwi" to "Kiwi",
        "lemon" to "Zitrone", "lime" to "Limette", "macadamia" to "Macadamianüsse", "mango" to "Mango",
        "marshmallow" to "Marshmallows", "meat" to "Rindfleisch", "muffin" to "Kuchen", "mussel" to "Muscheln",
        "mustard" to "Senf", "nectarine" to "Nektarine", "nut" to "Nüsse", "oatmeal" to "Haferflocken",
        "onion" to "Zwiebel", "oranges" to "Orange", "oyster" to "Muscheln", "papaya" to "Papaya",
        "passionfruit" to "Passionsfrucht", "pasta" to "Nudeln", "pastry" to "Kuchen", "pea" to "Erbsen",
        "peach" to "Pfirsich", "peanut" to "Erdnüsse", "pear" to "Birne", "pecan" to "Pekannüsse",
        "pepper_veggie" to "Paprika", "pepperoni" to "Salami", "pie" to "Kuchen", "pineapple" to "Ananas",
        "pistachio" to "Pistazien", "pizza" to "Pizza", "plum" to "Pflaume", "pomegranate" to "Granatapfel",
        "potato" to "Kartoffel", "pumpkin" to "Kürbis", "raspberry" to "Himbeeren", "rice" to "Reis",
        "salmon" to "Lachs", "sandwich" to "Brot", "sausage" to "Würstchen", "scrambled_eggs" to "Rührei",
        "seafood" to "Garnelen", "shellfish" to "Garnelen", "shellfish_prepared" to "Garnelen", "spinach" to "Spinat",
        "steak" to "Rindfleisch", "strawberry" to "Erdbeeren", "sugar_cube" to "Zucker", "sushi" to "Sushi",
        "tuna" to "Thunfisch", "waffle" to "Kuchen", "wedding_cake" to "Kuchen", "white_bread" to "Weißbrot",
        "yogurt" to "Joghurt", "zucchini" to "Zucchini", "apricot" to "Aprikose", "artichoke" to "Artischocke",
        "asparagus" to "Spargel", "bacon" to "Speck", "beer" to "Bier", "beet" to "Rote Bete",
        "blackberry" to "Brombeeren", "candy" to "Bonbons", "candy_cane" to "Bonbons", "coffee" to "Kaffee",
        "coffee_bean" to "Kaffee", "cranberry" to "Cranberry", "eggplant" to "Aubergine", "fries" to "Pommes",
        "frozen_dessert" to "Speiseeis", "hamburger" to "Burger", "honeydew" to "Honigmelone", "ice_cream" to "Speiseeis",
        "leek" to "Lauch", "lettuce" to "Blattsalat", "lollipop" to "Bonbons", "meatball" to "Frikadellen",
        "melon" to "Melone", "mushroom" to "Pilze", "pancake" to "Pfannkuchen", "popcorn" to "Popcorn",
        "pretzel" to "Brezel", "radish" to "Radieschen", "red_wine" to "Wein", "salad" to "Blattsalat",
        "sparkling_wine" to "Wein", "starfruit" to "Sternfrucht", "tea_drink" to "Tee", "tomato" to "Tomate",
        "watermelon" to "Wassermelone", "white_wine" to "Wein", "wine" to "Wein", "wine_bottle" to "Wein",
        // Begriffe, die nur ML Kit kennt
        "hot_dog" to "Würstchen", "juice" to "Fruchtsaft", "soft_drink" to "Cola", "fast_food" to "Burger",
        "dessert" to "Kuchen", "french_fries" to "Pommes",
    )

    /** Die wahrscheinlichsten Suchbegriffe (höchstens drei, ohne Doppelte). */
    fun terms(labels: List<Pair<String, Float>>, minConfidence: Float = 0.5f): List<String> =
        labels.sortedByDescending { it.second }.filter { it.second >= minConfidence }
            .mapNotNull { terms[it.first.lowercase().replace(' ', '_')] }.distinct().take(3)
}

/** Strichcode im Food-Check: Zutaten aus Open Food Facts, geprüft auf das, was Hunden gefährlich wird. */
class IngredientCheck(private val foods: List<Food>) {
    data class Hit(val name: String, val verdict: Food.Verdict, val reason: String)

    /** Kennungen von Open Food Facts („en:onion“) und Wortteile für den Zutatentext. Bei Trauben nur die Kennung – „Traubenzucker“ ist harmloser Zucker. */
    private class Rule(val food: String, val tags: List<String>, val words: List<String>, val verdict: Food.Verdict? = null, val reason: String? = null)

    private val rules = listOf(
        Rule("Xylit", listOf("en:xylitol", "en:e967"), listOf("xylit", "birkenzucker", "e967", "e 967")),
        Rule("Schokolade", listOf("en:chocolate", "en:cocoa", "en:cocoa-mass", "en:cocoa-powder", "en:fat-reduced-cocoa-powder"), listOf("schokolade", "kakao")),
        Rule("Rosinen", listOf("en:raisin", "en:sultana"), listOf("rosine", "sultanine")),
        Rule("Trauben", listOf("en:grape"), emptyList()),
        Rule("Zwiebel", listOf("en:onion", "en:onion-powder", "en:shallot"), listOf("zwiebel", "schalotte")),
        Rule("Knoblauch", listOf("en:garlic", "en:garlic-powder"), listOf("knoblauch")),
        Rule("Schnittlauch", listOf("en:chives"), listOf("schnittlauch")),
        Rule("Macadamianüsse", listOf("en:macadamia-nut"), listOf("macadamia")),
        Rule("Walnüsse", listOf("en:walnut"), listOf("walnuss", "walnüsse")),
        Rule("Pekannüsse", listOf("en:pecan-nut"), listOf("pekannuss", "pekannüsse", "pecan")),
        Rule("Avocadoöl", listOf("en:avocado"), listOf("avocado")),
        Rule("Alkohol", listOf("en:alcohol", "en:ethanol", "en:rum", "en:wine", "en:beer", "en:liqueur"),
            listOf("alkohol", "rum", "likör", "weinbrand", "branntwein"), Food.Verdict.BAD,
            app.thisdog.i18n.L.t("Alkohol ist für Hunde giftig. Schon kleine Mengen können Erbrechen, Taumeln und Unterzuckerung auslösen.")),
        Rule("Koffein", listOf("en:caffeine", "en:coffee", "en:guarana"), listOf("koffein", "kaffee", "guarana"), Food.Verdict.BAD,
            app.thisdog.i18n.L.t("Koffein ist für Hunde giftig. Es kann Herzrasen, Unruhe und Krämpfe auslösen.")),
    )

    /** Prüft Kennungen und Zutatentext. Das Schlimmste zuerst, jede Zutat nur einmal. */
    fun hits(tags: List<String>, text: String): List<Hit> {
        val tagSet = tags.map { it.lowercase() }.toSet()
        val lower = text.lowercase()
        val out = mutableListOf<Hit>()
        for (r in rules) {
            if (r.tags.none { it in tagSet } && r.words.none { containsWord(lower, it) }) continue
            val f = foods.firstOrNull { it.name == r.food }
            if (f != null) out += Hit(f.name, f.verdict, f.reason)
            else if (r.verdict != null && r.reason != null) out += Hit(app.thisdog.i18n.L.t(r.food), r.verdict, r.reason)
        }
        return out.sortedBy { when (it.verdict) { Food.Verdict.BAD -> 0; Food.Verdict.WARN -> 1; Food.Verdict.OK -> 2 } }
    }

    companion object {
        /** „rum“ zählt in „Rum“, aber nicht in „Krume“: kurze Wortteile nur am Wortanfang. Längere („kakao“) auch mitten im Wort. */
        fun containsWord(text: String, word: String): Boolean {
            if (word.length >= 5) return word in text
            var i = text.indexOf(word)
            while (i >= 0) {
                if (i == 0 || !text[i - 1].isLetter()) return true
                i = text.indexOf(word, i + 1)
            }
            return false
        }
    }
}

/** Ein Produkt aus Open Food Facts, so knapp, wie es der Food-Check braucht. */
data class ScannedProduct(val code: String, val name: String?, val brand: String?, val ingredientsText: String, val ingredientTags: List<String>) {
    val hasIngredients get() = ingredientsText.isNotEmpty() || ingredientTags.isNotEmpty()

    sealed class Result {
        data class Found(val product: ScannedProduct) : Result()
        data object NotFound : Result()
        data object Offline : Result()
    }

    @Serializable private data class Answer(val status: Int? = null, val product: P? = null)
    @Serializable private data class P(val product_name_de: String? = null, val product_name: String? = null, val brands: String? = null,
                                       val ingredients_text_de: String? = null, val ingredients_text: String? = null,
                                       val ingredients_tags: List<String>? = null, val additives_tags: List<String>? = null)

    companion object {
        private val client = OkHttpClient.Builder().callTimeout(12, TimeUnit.SECONDS).build()
        private val json = Json { ignoreUnknownKeys = true }

        /** Fragt Open Food Facts. Gesendet wird nur die Nummer des Strichcodes. */
        suspend fun lookup(code: String): Result = withContext(Dispatchers.IO) {
            val digits = code.filter { it.isDigit() }
            if (digits.isEmpty()) return@withContext Result.NotFound
            val url = "https://world.openfoodfacts.org/api/v2/product/$digits.json?fields=product_name_de,product_name,brands,ingredients_text_de,ingredients_text,ingredients_tags,additives_tags"
            val body = runCatching {
                client.newCall(Request.Builder().url(url).header("User-Agent", "ThisDog/${BuildConfig.VERSION_NAME} (Android; https://thisdog.app)").build())
                    .execute().use { if (it.code == 404) "" else if (it.isSuccessful) it.body.string() else null }
            }.getOrElse { return@withContext Result.Offline } ?: return@withContext Result.Offline
            val a = runCatching { json.decodeFromString<Answer>(body) }.getOrNull()
            val p = a?.product
            if (a?.status != 1 || p == null) return@withContext Result.NotFound
            fun clean(s: String?) = s?.trim()?.takeIf { it.isNotEmpty() }
            Result.Found(ScannedProduct(digits, clean(p.product_name_de) ?: clean(p.product_name), clean(p.brands?.substringBefore(",")),
                clean(p.ingredients_text_de) ?: clean(p.ingredients_text) ?: "", (p.ingredients_tags ?: emptyList()) + (p.additives_tags ?: emptyList())))
        }
    }
}
