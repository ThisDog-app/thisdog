package app.thisdog.i18n

import android.content.Context
import android.icu.text.PluralRules
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Übersetzungen. Der deutsche Text ist zugleich der Schlüssel, wie im String-Katalog der iOS-Fassung: `L.t("Noch %1$d Tage", n)`.
 * Jede Sprache ist eine Datei `assets/i18n/<sprache>.json`: `{"Runde starten": "Start a walk", "Noch %1$d Tage": {"one": "…", "other": "…"}}`.
 * Fehlt die Sprache oder ein Text, bleibt es Deutsch. Mehrzahl richtet sich nach der ersten Zahl in den Werten.
 */
object L {
    private var table: JsonObject = JsonObject(emptyMap())
    private var plural: PluralRules? = null

    /** Die Sprache, in der die App läuft. Daten und Zahlen folgen ihr, auch wenn das System etwas anderes eingestellt hat. */
    var locale: Locale = Locale.GERMANY; private set
    val isGerman get() = locale.language == "de"
    /** Für Dateinamen wie `foods.en.json`. */
    val tag get() = locale.toLanguageTag()

    fun init(context: Context) {
        val want = Locale.getDefault()
        // Es zählt nur, wofür es wirklich eine Datei gibt. Sonst bliebe der Text deutsch, Datum und Zahlen aber nicht.
        val file = context.assets.list("i18n").orEmpty().map { it.removeSuffix(".json") }.filter { it != "vorlage" }
            .firstOrNull { Locale.forLanguageTag(it).language == want.language } ?: return
        table = runCatching { Json.parseToJsonElement(context.assets.open("i18n/$file.json").bufferedReader().use { it.readText() }).jsonObject }
            .getOrDefault(JsonObject(emptyMap()))
        locale = Locale.forLanguageTag(file)
        plural = PluralRules.forLocale(locale)
    }

    fun t(source: String, vararg args: Any?): String {
        val entry = table[source]
        val text = when (entry) {
            is JsonPrimitive -> entry.contentOrNull
            is JsonObject -> {
                val n = args.firstOrNull { it is Number } as Number?
                val form = if (n != null) plural?.select(n.toDouble()) else null
                (entry[form ?: "other"] ?: entry["other"])?.jsonPrimitive?.contentOrNull
            }
            else -> null
        } ?: source
        return if (args.isEmpty()) text else String.format(locale, text, *args)
    }
}
