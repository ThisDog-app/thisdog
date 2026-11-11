package app.thisdog

import app.thisdog.gassi.*
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaceTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun readsServerFormat() {
        val p = json.decodeFromString(Place.serializer(), """{"id":"way/1","name":"Hundezone Augarten","kind":"dog_park","label":"Hundezone","rank":0,"lat":48.22,"lon":16.37,
            "facts":{"fenced":{"v":2,"src":"wien"},"area":{"v":1809,"src":"wien"},"bags":{"v":1,"src":"osm"}},"votes":{"water":[4,1]},"voters":5,"sizes":[3,2,0]}""")
        assertEquals("way/1", p.id)
        assertEquals(1809, p.area)
        // Kotbeutel sind ein Merkmal: Solange es wenig Stimmen gibt, gilt der Fakt aus der Karte – nicht doppelt bei den extras.
        assertTrue(p.extras.isEmpty())
        assertEquals(PlaceVerdict.Yes("osm"), p.verdict(PlaceFeature.BAGS))
        assertEquals(PlaceVerdict.Yes(null), p.verdict(PlaceFeature.WATER))
        assertEquals(PlaceVerdict.Partly("wien"), p.verdict(PlaceFeature.FENCED))
        assertEquals("Aus OpenStreetMap, ergänzt mit Daten der Stadt Wien (CC BY 4.0)", p.sourceNote)
    }

    @Test fun threeQuartersYesOneQuarterNo() {
        val p = Place("Wiese", "meadow", "Wiese", 3, 48.2, 16.4, serverID = "eigen/1", voters = 4,
            votes = mapOf("water" to listOf(3, 1), "shade" to listOf(1, 3), "clean" to listOf(2, 2)))
        assertEquals(PlaceVerdict.Yes(null), p.verdict(PlaceFeature.WATER))
        assertEquals(PlaceVerdict.No(null), p.verdict(PlaceFeature.SHADE))
        assertEquals(PlaceVerdict.Unsure(2, 4), p.verdict(PlaceFeature.CLEAN))
    }

    @Test fun belowThreeVotersTheMapCounts() {
        val p = Place("Park", "park", "Park", 1, 48.2, 16.4, serverID = "way/2", voters = 2,
            facts = mapOf("bench" to Place.Fact(1, "osm")), votes = mapOf("bench" to listOf(0, 2), "water" to listOf(2, 0)))
        assertEquals(PlaceVerdict.Yes("osm"), p.verdict(PlaceFeature.BENCH))
        assertNull(p.verdict(PlaceFeature.WATER))
    }

    @Test fun newFeaturesAndDogZoneFilter() {
        assertEquals(listOf("off_leash", "fenced", "water", "clean", "grass", "shade", "bench", "bags", "split"), PlaceFeature.entries.map { it.key })
        assertEquals("Kotbeutel", PlaceFeature.BAGS.short)
        assertEquals("Groß und klein getrennt", PlaceFeature.SPLIT.short)
        val zone = Place("Zone", "dog_park", "Hundezone", 0, 48.22, 16.39, serverID = "way/1")
        val park = Place("Park", "park", "Park", 1, 48.2, 16.4, serverID = "way/2")
        assertTrue(PlaceFeature.SPLIT in zone.features && PlaceFeature.BAGS in zone.features)
        assertTrue(PlaceFeature.SPLIT !in park.features && PlaceFeature.BAGS in park.features)
        assertEquals(PlaceFeature.entries.size - 1, PlaceFeature.forPlace(false).size)
        // Prüfung vor Ort: Pflicht sind dieselben sieben Merkmale wie CHECK_REQUIRED in api/place.php.
        assertEquals(listOf("off_leash", "fenced", "water", "clean", "grass", "shade", "bench"), PlaceFeature.entries.filter { it.requiredForCheck }.map { it.key })
        val voted = zone.copy(voters = 4, votes = mapOf("split" to listOf(3, 1), "bags" to listOf(0, 4)))
        assertEquals(PlaceVerdict.Yes(null), voted.verdict(PlaceFeature.SPLIT))
        assertEquals(PlaceVerdict.No(null), voted.verdict(PlaceFeature.BAGS))
    }

    private fun at(day: String, hour: Int = 9) = LocalDate.parse(day).atTime(hour, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()

    @Test fun checkInOnlyNearAndNotTwiceInTwoHours() {
        val p = Place("Zone", "dog_park", "Hundezone", 0, 48.22, 16.39, serverID = "way/1")
        assertTrue(CheckIns.inReach(p, app.thisdog.model.LatLng(48.2210, 16.39)))
        assertTrue(!CheckIns.inReach(p, app.thisdog.model.LatLng(48.2300, 16.39)))
        val c = CheckIn.of(p, at("2026-10-18", 9))
        assertEquals(c, CheckIns.recent(p, listOf(c), at("2026-10-18", 10)))
        assertNull(CheckIns.recent(p, listOf(c), at("2026-10-18", 12)))
    }

    @Test fun badges() {
        val p = Place("Zone", "dog_park", "Hundezone", 0, 48.22, 16.39, serverID = "way/1")
        val nine = (1..9).map { CheckIn.of(p, at("2026-10-0$it")) }
        assertEquals("noch 1 Besuche in Zone", Revier(nine, LocalDate.parse("2026-10-18")).next?.detail)
        assertEquals(listOf("stammgast"), Revier(nine + CheckIn.of(p, at("2026-10-12")), LocalDate.parse("2026-10-18")).badges.map { it.id })
        val sundays = listOf("2026-10-11", "2026-10-04", "2026-09-27", "2026-09-20").map { CheckIn.of(p, at(it)) }
        assertEquals(4, Revier.sundayStreak(sundays, LocalDate.parse("2026-10-18")))
        assertEquals(0, Revier.sundayStreak(sundays.drop(1), LocalDate.parse("2026-10-18")))
        assertEquals("Stellas Revier", CheckIns.revierTitle("Stella")); assertEquals("Max’ Revier", CheckIns.revierTitle("Max"))
    }

    @Test fun checkedBeatsVotes() {
        val p = json.decodeFromString(Place.serializer(), """{"id":"way/3","name":"Zone","kind":"dog_park","label":"Hundezone","rank":0,"lat":48.2,"lon":16.4,
            "facts":{"water":{"v":0,"src":"thisdog"}},"checkedAt":1792000000,"photos":[{"id":7,"w":1600,"h":1200}],"voters":5,"votes":{"water":[5,0]}}""")
        assertEquals(PlaceVerdict.No("thisdog"), p.verdict(PlaceFeature.WATER))
        assertEquals("https://thisdog.app/api/photo.php?id=7&klein=1", p.photos[0].thumb)
        assertEquals(1792000000L, p.checkedAt)
    }
}

class DeviceCodeTest {
    /** Dieselben Werte wie tests/support-test.sh und DeviceCodeTests auf iOS. */
    @Test fun sameAsServer() {
        assertEquals("0V5-H00-0CG", app.thisdog.help.DeviceCode.encode(0, 27, 1, 3, 1, 0, 12))
        assertEquals("4GP-110-AS9", app.thisdog.help.DeviceCode.encode(2, 16, 5, 4, 1, 2, 345))
    }
}
