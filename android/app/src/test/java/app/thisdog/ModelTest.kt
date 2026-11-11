package app.thisdog

import app.thisdog.model.*
import java.io.File
import kotlin.math.abs
import kotlin.math.pow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dieselben Fälle wie in den iOS-Tests (CalendarTests, FoodTests, DogTests, WalkTests, TipTests). */
class ModelTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    // MARK: Wiederholungen
    @Test fun monthEnd() {
        val s = Day(2026, 1, 31)
        assertEquals(Day(2026, 2, 28), Repetition.MONTHLY.step(s, 1))
        assertEquals(Day(2026, 3, 31), Repetition.MONTHLY.step(s, 2))
        assertEquals(Day(2026, 4, 30), Repetition.MONTHLY.step(s, 3))
    }
    @Test fun leapDay() {
        assertEquals(Day(2029, 2, 28), Repetition.YEARLY.step(Day(2028, 2, 29), 1))
        assertEquals(Day(2032, 2, 29), Repetition.YEARLY.step(Day(2028, 2, 29), 4))
    }
    @Test fun intervals() {
        assertEquals(Day(2026, 10, 31), Repetition.BIWEEKLY.step(Day(2026, 10, 17), 1))
        assertEquals(Day(2027, 2, 28), Repetition.QUARTERLY.step(Day(2026, 11, 30), 1))
    }
    @Test fun until() {
        val ev = DogEvent(title = "Krallen", start = "2026-10-01", repetition = "weekly", repeatUntil = "2026-10-15")
        assertEquals(listOf(Day(2026, 10, 1), Day(2026, 10, 8), Day(2026, 10, 15)), CalendarBuilder.occurrences(ev, Day(2026, 10, 17)).map { it.start })
    }
    @Test fun firstStays() {
        val list = CalendarBuilder.occurrences(DogEvent(title = "Entwurmung", start = "2020-01-10", repetition = "quarterly"), Day(2026, 10, 17))
        assertEquals(Day(2020, 1, 10), list.first().start)
        assertTrue(list.drop(1).all { it.start >= Day(2025, 10, 1) })
    }
    /** Eine wöchentliche Serie seit Jahren erreicht heute trotz Höchstzahl; der Beginn bleibt sichtbar. */
    @Test fun oldWeeklyReachesToday() {
        val today = Day(2026, 11, 10)
        val list = CalendarBuilder.occurrences(DogEvent(title = "Hundeschule", start = "2015-01-06", repetition = "weekly"), today)
        assertEquals(Day(2015, 1, 6), list.first().start)
        assertTrue(list.any { it.start >= today && it.start < today.addingDays(7) })
        val rest = list.drop(1).map { it.start }
        assertTrue(rest.first() >= Day(2025, 11, 1) && rest.first() < Day(2025, 11, 8))
        assertTrue(rest.zipWithNext().all { (x, y) -> x.daysUntil(y) == 7 })
        // Die Kennungen zählen weiter vom Beginn der Serie, wie ohne Sprung.
        assertEquals("${list[1].eventID}#${Day(2015, 1, 6).daysUntil(list[1].start) / 7}", list[1].id)
    }
    @Test fun oldMonthlyNoGap() {
        val list = CalendarBuilder.occurrences(DogEvent(title = "Floh", start = "1990-01-31", repetition = "monthly"), Day(2026, 11, 10))
        assertEquals(Day(2025, 11, 30), list[1].start)
        assertEquals(Day(2028, 11, 30), list.last().start)
    }
    @Test fun spanKept() {
        val second = CalendarBuilder.occurrences(DogEvent(title = "Läufigkeit", start = "2026-03-01", end = "2026-03-21", repetition = "halfyearly"), Day(2026, 10, 17))[1]
        assertEquals(Day(2026, 9, 1), second.start); assertEquals(Day(2026, 9, 21), second.end)
    }

    // MARK: Datenformat
    @Test fun webFormat() {
        val ev = json.decodeFromString(DogEvent.serializer(), """{"id":"evt_abc","title":"Tierarzt","start":"2026-10-20","end":"","notes":"","kind":"personal","repeat":"monthly","repeatUntil":"","u":1760000000000}""")
        assertEquals(Repetition.MONTHLY, ev.rule); assertEquals("", ev.time)
        val back = json.encodeToJsonElement(DogEvent.serializer(), ev).jsonObject
        assertEquals(JsonPrimitive("monthly"), back["repeat"]); assertNull(back["repetition"])
    }
    @Test fun seasonalEnd() {
        val hint = json.decodeFromString(ListSerializer(SeasonalHint.serializer()), """[{"title":"Zecken","start":"2026-03-01","end":"2026-11-01","classNames":["fc-event-warning"]}]""")[0]
        val e = hint.entry!!
        assertEquals(Day(2026, 10, 31), e.end); assertEquals(EntryKind.WARNING, e.kind); assertTrue(e.isPeriod)
    }
    @Test fun bundledFilesReadable() {
        val foods = json.decodeFromString(ListSerializer(Food.serializer()), File("src/main/assets/foods.json").readText())
        assertTrue(foods.size > 200)
        assertTrue(json.decodeFromString(ListSerializer(Tip.serializer()), File("src/main/assets/tips.json").readText()).isNotEmpty())
        assertTrue(json.decodeFromString(ListSerializer(SeasonalHint.serializer()), File("src/main/assets/public_events.json").readText()).isNotEmpty())
    }

    // MARK: Food-Check
    private val search by lazy { FoodSearch(json.decodeFromString(ListSerializer(Food.serializer()), File("src/main/assets/foods.json").readText())) }
    private fun top(q: String) = search.search(q).firstOrNull()?.food?.name
    @Test fun german() { assertEquals("Trauben", top("Trauben")); assertEquals("Trauben", top("Weintrauben")); assertEquals("Aioli", top("Knoblauchdip")) }
    @Test fun umlauts() { for (q in listOf("Käse", "kaese", "kase")) assertTrue(q, top(q)?.startsWith("Käse") == true) }
    @Test fun typos() { assertEquals("Banane", top("Bananne")); assertTrue(search.search("xqzv").isEmpty()) }
    @Test fun parts() {
        assertEquals("aepfel roh", FoodSearch.norm("Äpfel, roh")); assertEquals("traub", FoodSearch.stem("trauben")); assertEquals(1, FoodSearch.editDistance("hund", "hand"))
    }

    // MARK: Hund und Rechner
    @Test fun ageAndStage() {
        var p = DogProfile(birthdate = "2023-06-20")
        assertEquals("3 Jahre, 3 Monate", p.age(Day(2026, 10, 18))); assertEquals("1 Monat", p.age(Day(2023, 7, 20)))
        assertEquals("Welpe", p.stage(Day(2024, 1, 1)))
        p = p.copy(weightKg = 45.0); assertEquals("Senior", p.stage(Day(2029, 7, 1)))
        p = p.copy(weightKg = 8.0); assertEquals("Erwachsen", p.stage(Day(2029, 7, 1)))
    }
    @Test fun energy() {
        val e = Calc.energy(DogProfile(weightKg = 21.4, birthdate = "2023-06-20"), today = Day(2026, 10, 18))!!
        assertTrue(abs(e.rer - 70 * 21.4.pow(0.75)) < 0.001); assertEquals(1.8, e.factor.value, 0.0)
        assertTrue(abs(Calc.grams(e.kcal, 350.0)!! - e.kcal / 3.5) < 0.001)
    }
    @Test fun stellaFood() {
        // Stella: Zwergpudel, 16 Monate, 6 kg, nicht kastriert, normal aktiv → 138 g Trockenfutter (wie die iOS-App zeigt).
        val p = DogProfile(weightKg = 6.0, birthdate = Day(2026, 10, 18).addingMonths(-16).iso)
        assertEquals(138, Math.round(Calc.grams(Calc.energy(p, today = Day(2026, 10, 18))!!.kcal, 350.0)!!).toInt())
    }
    @Test fun factors() {
        var p = DogProfile(weightKg = 30.0, birthdate = "2026-08-01"); val t = Day(2026, 10, 18)
        assertEquals(3.0, Calc.factor(p, t).value, 0.0)
        p = p.copy(birthdate = "2026-01-01"); assertEquals(2.0, Calc.factor(p, t).value, 0.0)
        p = p.copy(birthdate = "2019-01-01", neutered = true, activity = "low"); assertEquals(1.2, Calc.factor(p, t).value, 0.0)
        p = p.copy(neutered = false, activity = "high", birthdate = "2023-01-01"); assertEquals(2.2, Calc.factor(p, t).value, 0.0)
    }
    @Test fun asphaltAndWater() {
        // Wien: Juli 13 Uhr klar wie die Messreihen (25 → 51, 30 → 60), November und Nacht nahe der Luft.
        fun s(air: Double, cloud: Double, wind: Double, iso: String) =
            app.thisdog.model.Asphalt.surface(app.thisdog.model.Asphalt.Conditions(air, cloud, wind, 48.21, 16.37), java.time.Instant.parse(iso).toEpochMilli())
        assertEquals(51.0, s(25.0, 0.0, 3.0, "2026-07-15T11:00:00Z"), 4.0); assertEquals(60.0, s(30.0, 0.0, 3.0, "2026-07-15T11:00:00Z"), 4.0)
        assertTrue(s(30.0, 1.0, 3.0, "2026-07-15T11:00:00Z") < 43); assertTrue(s(5.0, 0.9, 3.0, "2026-11-11T11:00:00Z") < 13)
        assertTrue(s(5.0, 0.0, 3.0, "2026-11-11T20:00:00Z") <= 5)
        assertEquals(Calc.Paws.WARN, Calc.paws(51.0)); assertEquals(Calc.Paws.BAD, Calc.paws(52.0)); assertEquals(Calc.Paws.OK, Calc.paws(42.0))
        assertEquals(100.0, Calc.treats(1000.0).first, 0.0); assertEquals(1000.0..1200.0, Calc.water(20.0))
    }
    @Test fun profileFromWebWithMissingFields() {
        val p = json.decodeFromString(DogProfile.serializer(), """{"name":"Stella","u":5}""")
        assertEquals("Stella", p.name); assertEquals("normal", p.activity); assertEquals(5.0, p.u, 0.0)
    }

    // MARK: Gassi
    private val wien = LatLng(48.2082, 16.3738)
    @Test fun polyline() {
        val pts = listOf(wien, LatLng(48.22513, 16.37944), LatLng(48.2301, 16.3702))
        val back = Polyline.decode(Polyline.encode(pts))
        assertEquals(3, back.size); pts.zip(back).forEach { (a, b) -> assertTrue(Track.distance(a, b) < 1.5) }
    }
    @Test fun polylineMatchesGoogle() {
        // Das Beispiel aus Googles Beschreibung des Verfahrens.
        assertEquals("_p~iF~ps|U_ulLnnqC_mqNvxq`@", Polyline.encode(listOf(LatLng(38.5, -120.2), LatLng(40.7, -120.95), LatLng(43.252, -126.453))))
    }
    @Test fun simplify() {
        val straight = (0..20).map { LatLng(wien.lat + it * 0.0001, wien.lng) }
        assertEquals(2, Track.simplify(straight).size)
        assertEquals(3, Track.simplify(straight + LatLng(straight.last().lat, wien.lng + 0.002)).size)
    }
    @Test fun texts() {
        assertEquals("640 m", WalkText.distance(640.0)); assertEquals("1,84 km", WalkText.distance(1843.0))
        assertEquals("23:41", WalkText.clock(1421.0)); assertEquals("1:05:12", WalkText.clock(3912.0)); assertEquals("12:52", WalkText.pace(12.87))
    }

    // MARK: Ratgeber
    @Test fun tipText() {
        val b = TipText.blocks("### Warum\n\nErster Satz.\nZweiter.\n\n* Punkt eins\n- Punkt zwei")
        assertEquals(listOf(TipText.Block.Heading("Warum"), TipText.Block.Paragraph("Erster Satz.\nZweiter."), TipText.Block.Bullet("Punkt eins"), TipText.Block.Bullet("Punkt zwei")), b)
    }
    @Test fun checksFormat() {
        val c = json.decodeFromString(TipChecks.serializer(), """{"hitze":[true,false],"u":7}""")
        assertEquals(listOf(true, false), c.bySlug["hitze"]); assertEquals(7.0, c.u, 0.0)
        val back = json.encodeToJsonElement(TipChecks.serializer(), c) as JsonObject
        assertEquals(setOf("hitze", "u"), back.keys)
    }
}
