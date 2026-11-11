package app.thisdog.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.thisdog.model.Food
import app.thisdog.model.FoodSearch
import app.thisdog.model.SeasonalHint
import app.thisdog.model.Tip
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer

/**
 * Inhalte, die die App mitbringt und vom Server aktualisiert (wie ContentStore.swift): zuletzt geladene Fassung,
 * sonst die mitgelieferte. Eine Datei vom Server wird erst übernommen, wenn sie sich vollständig lesen lässt.
 */
class Content(private val context: Context) {
    private val folder = File(context.filesDir, "Inhalte").apply { mkdirs() }
    private val prefs = context.getSharedPreferences("inhalte", Context.MODE_PRIVATE)

    var foods by mutableStateOf<List<Food>>(emptyList()); private set
    var tips by mutableStateOf<List<Tip>>(emptyList()); private set
    var seasonal by mutableStateOf<List<SeasonalHint>>(emptyList()); private set
    var search by mutableStateOf(FoodSearch(emptyList())); private set

    init { forgetOutdatedDownloads(); reload() }

    /**
     * Bringt ein Update der App eine andere Fassung mit als beim letzten Start, ist die früher vom Server geladene
     * vermutlich älter: Sie wird verworfen und beim nächsten Abgleich sofort neu gefragt. Sonst verdeckte eine alte
     * Liste vom Server die neue mitgelieferte, bis zu sechs Stunden lang.
     */
    private fun forgetOutdatedDownloads() {
        for (name in listOf("public_events", "foods", "tips")) {
            val bundled = runCatching { context.assets.open("$name.json").use { it.readBytes() } }.getOrNull() ?: continue
            val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bundled).joinToString("") { "%02x".format(it) }
            if (prefs.getString("$name.mitgeliefert", null) == hash) continue
            File(folder, "$name.json").delete()
            prefs.edit().remove("$name.etag").remove("$name.geprueft").putString("$name.mitgeliefert", hash).apply()
        }
    }

    private fun text(name: String): String =
        // Vom Server kommen bisher nur die deutschen Inhalte. Übersetzte liegen als foods.en.json in assets; fehlt die Sprache, bleibt es Deutsch.
        File(folder, "$name.json").takeIf { app.thisdog.i18n.L.isGerman && it.exists() }?.readText()
            ?: context.assets.open(if (!app.thisdog.i18n.L.isGerman && "$name.${app.thisdog.i18n.L.tag}.json" in context.assets.list("").orEmpty()) "$name.${app.thisdog.i18n.L.tag}.json" else "$name.json").bufferedReader().readText()

    private fun reload() {
        foods = runCatching { ThisDogJson.decodeFromString(ListSerializer(Food.serializer()), text("foods")) }.getOrDefault(emptyList())
        tips = runCatching { ThisDogJson.decodeFromString(ListSerializer(Tip.serializer()), text("tips")) }.getOrDefault(emptyList())
        seasonal = runCatching { ThisDogJson.decodeFromString(ListSerializer(SeasonalHint.serializer()), text("public_events")) }.getOrDefault(emptyList())
        search = FoodSearch(foods)
    }

    private fun readable(name: String, body: String): Boolean = runCatching {
        when (name) {
            "foods" -> ThisDogJson.decodeFromString(ListSerializer(Food.serializer()), body).size >= 50
            "tips" -> ThisDogJson.decodeFromString(ListSerializer(Tip.serializer()), body).isNotEmpty()
            else -> ThisDogJson.decodeFromString(ListSerializer(SeasonalHint.serializer()), body).isNotEmpty()
        }
    }.getOrDefault(false)

    /** Fragt höchstens alle sechs Stunden nach neuen Fassungen (mit ETag). */
    suspend fun refresh(force: Boolean = false) = withContext(Dispatchers.IO) {
        var changed = false
        for (name in listOf("public_events", "foods", "tips")) {
            val last = prefs.getLong("$name.geprueft", 0)
            if (!force && System.currentTimeMillis() - last < 6 * 3600_000L) continue
            runCatching {
                val c = URL("https://thisdog.app/data/$name.json").openConnection() as HttpURLConnection
                c.connectTimeout = 20_000; c.readTimeout = 20_000
                prefs.getString("$name.etag", null)?.let { c.setRequestProperty("If-None-Match", it) }
                prefs.edit().putLong("$name.geprueft", System.currentTimeMillis()).apply()
                if (c.responseCode == 200) {
                    val body = c.inputStream.bufferedReader().readText()
                    if (readable(name, body)) {
                        File(folder, "$name.json").writeText(body)
                        c.getHeaderField("ETag")?.let { prefs.edit().putString("$name.etag", it).apply() }
                        changed = true
                    }
                }
                c.disconnect()
            }
        }
        if (changed) withContext(Dispatchers.Main) { reload() }
    }
}
