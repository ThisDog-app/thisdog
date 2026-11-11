package app.thisdog

import app.thisdog.data.DogStore
import app.thisdog.gassi.Heat
import app.thisdog.model.*
import java.io.File
import java.nio.file.Files
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dieselben Fälle wie die neuen Tests auf iOS: Foto, Strichcode, Erledigt, Wetter. */
class NeuTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val foods by lazy { json.decodeFromString(ListSerializer(Food.serializer()), File("src/main/assets/foods.json").readText()) }

    @Test fun photoTermsFind() {
        val search = FoodSearch(foods)
        for ((id, term) in FoodPhoto.terms) assertTrue("$id → $term findet nichts", search.search(term).isNotEmpty())
    }

    @Test fun photoTermsOrder() {
        assertEquals(listOf("Trauben", "Kuchen"), FoodPhoto.terms(listOf("Cake" to .6f, "Grape" to .9f, "Cupcake" to .7f, "Table" to .95f, "Onion" to .1f)))
    }

    @Test fun ingredientHits() {
        val check = IngredientCheck(foods)
        val hits = check.hits(listOf("en:sugar", "en:onion"), "Zucker, Röstzwiebeln, Magerkakao, Süßungsmittel: Xylit")
        assertEquals(setOf("Zwiebel", "Schokolade", "Xylit"), hits.map { it.name }.toSet())
        assertTrue(hits.all { it.verdict == Food.Verdict.BAD })
        assertEquals(listOf("Walnüsse"), check.hits(emptyList(), "Haselnüsse 13 %, Walnusskerne").map { it.name })
    }

    @Test fun ingredientFalseAlarms() {
        val check = IngredientCheck(foods)
        assertTrue(check.hits(listOf("en:dextrose"), "Weizenmehl, Traubenzucker, Brotkrume, Molkenserum").isEmpty())
        assertEquals(listOf("Alkohol"), check.hits(emptyList(), "Rum, Zucker").map { it.name })
    }

    @Test fun markDone() {
        var clock = 1_000_000.0
        val s = DogStore(File(Files.createTempDirectory("erledigt").toFile(), "thisdog.json")) { clock += 10; clock }
        val today = Day(2026, 11, 9)
        s.save(Deworming("deworming_a", "Milbemax", "2026-08-15", "2026-11-13"))
        s.save(Vaccination("vaccinations_a", "Tollwut", "", "2026-11-01"))
        s.save(Medication("meds_a", "Tabletten", "", "2026-11-01", "2026-11-12"))
        assertTrue(s.canMarkDone(s.dues.first { it.id == "due_deworming_a" }, today))
        assertFalse(s.canMarkDone(s.dues.first { it.id == "due_meds_a" }, today))
        assertTrue(s.markDone("due_deworming_a", today))
        assertTrue(s.dewormings.any { it.date == "2026-11-09" && it.next == today.addingDays(90).iso })
        assertTrue(s.markDone("due_vaccinations_a", today))
        assertTrue(s.vaccinations.any { it.date == "2026-11-09" && it.next == "2027-11-09" })
        assertFalse(s.markDone("due_meds_a", today))
        assertFalse(s.dues.any { it.id == "due_deworming_a" || it.id == "due_vaccinations_a" })
        // Ein zweiter Tipp auf dieselbe Mitteilung legt keine zweite Auffrischung an.
        val count = s.vaccinations.size + s.dewormings.size
        assertFalse(s.markDone("due_deworming_a", today)); assertFalse(s.markDone("due_vaccinations_a", today))
        assertEquals(count, s.vaccinations.size + s.dewormings.size)
    }

    @Test fun weather() {
        val body = """{"properties":{"timeseries":[{"time":"2026-07-01T12:00:00Z","data":{"instant":{"details":{"air_temperature":31.4,"cloud_area_fraction":20.0,"wind_speed":2.5}}}}]}}"""
        assertEquals(Heat.Reading(31.4, 0.2, 2.5), Heat.parse(body))
        // Wien, 1. Juli 2026: mittags hoch am Himmel, um Mitternacht unter dem Horizont.
        val wien = LatLng(48.21, 16.37)
        assertTrue(Heat.sunElevation(wien, 1782902400000L) > 50)   // 2026-07-01 10:40 UTC
        assertTrue(Heat.sunElevation(wien, 1782945600000L) < 0)    // 2026-07-01 22:40 UTC
        val hot = app.thisdog.model.Asphalt.Conditions(33.0, 0.0, 2.0, wien.lat, wien.lng)
        assertEquals(null, app.thisdog.model.Asphalt.warning(hot, 1782945600000L))
        assertEquals(Calc.Paws.BAD, app.thisdog.model.Asphalt.warning(hot, 1782902400000L))
    }
}
