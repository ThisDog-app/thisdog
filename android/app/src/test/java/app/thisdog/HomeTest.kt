package app.thisdog

import app.thisdog.gassi.CheckIn
import app.thisdog.gassi.Place
import app.thisdog.model.CalendarEntry
import app.thisdog.model.Day
import app.thisdog.model.DogProfile
import app.thisdog.model.EntryKind
import app.thisdog.model.LeashLayout
import app.thisdog.model.Saying
import app.thisdog.ui.DogFacts
import app.thisdog.ui.Home
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Dieselben Fälle wie HomeTests.swift und die Hund-Tests in DogTests.swift. */
class HomeTest {
    private fun place(name: String) = Place(name, "park", "Park", 0, 48.2, 16.4, serverID = "way/$name")

    @Test fun unvisited() {
        val all = listOf("a", "b", "c", "d", "e").map(::place)
        assertEquals(listOf("b", "d", "e"), Home.unvisited(all, listOf(CheckIn.of(all[0]), CheckIn.of(all[2]))).map { it.name })
    }

    @Test fun dogLine() {
        val today = Day.today()
        fun line(walking: Boolean, walked: Boolean, last: Day?, seed: Int) = Home.dogLine(walking, walked, last, today, 9, seed)
        assertEquals("Hier riecht's super!", line(true, false, today, 0))
        assertEquals("Schön war's. Jetzt Sofa?", line(false, true, today, 0))
        assertEquals("Unsere erste Runde! Ich bin so bereit.", line(false, false, null, 0))
        assertEquals("Hallo? Die Leine vermisst mich.", line(false, false, today.addingDays(-3), 0))
        assertEquals("Aufstehen! Die Wiese wartet.", line(false, false, today.addingDays(-1), 0))
        assertNotEquals(line(false, true, today, 0), line(false, true, today, 1))
        assertEquals(line(false, true, today, 0), line(false, true, today, 3))
    }

    @Test fun headline() {
        assertEquals("Zeit für eine Runde?", Home.headline(false, false))
        assertEquals("Schön, ihr wart heute schon draußen.", Home.headline(false, true))
        assertEquals("Ihr seid unterwegs.", Home.headline(true, true))
    }

    @Test fun dogFunFact() {
        val today = Day.today()
        var p = DogProfile(name = "Stella")
        assertNull(DogFacts.funFact(p, today))
        p = p.copy(birthdate = today.addingYears(-2).iso)
        assertEquals("Heute ist Geburtstag! Alles Gute, Stella!", DogFacts.funFact(p, today))
        p = p.copy(birthdate = today.addingDays(1).addingYears(-2).iso)
        assertEquals("Morgen ist Geburtstag. Schon was besorgt?", DogFacts.funFact(p, today))
        p = p.copy(birthdate = today.addingDays(30).addingYears(-2).iso)
        assertEquals("Noch 30 Tage bis zum Geburtstag.", DogFacts.funFact(p, today))
        p = p.copy(birthdate = today.addingDays(-100).addingYears(-3).iso, weightKg = 6.0)
        assertEquals("In Menschenjahren etwa 29.", DogFacts.funFact(p, today))
    }

    /** Wie `running` in CalendarTests.swift: Was vorher begonnen hat und noch läuft, hängt am ersten Knoten. */
    @Test fun leashRunning() {
        fun entry(title: String, from: Day, to: Day) = CalendarEntry(title, null, title, from, to, "", "", EntryKind.SEASONAL, null, "")
        val s = Day(2026, 12, 25)
        val l = LeashLayout(s, listOf(entry("Weihnachten", s, Day(2026, 12, 26)), entry("Vorbei", Day(2026, 12, 20), Day(2026, 12, 22))), 13f, 20f, 46f, 18f)
        assertEquals(listOf("Weihnachten"), l.nodes.first().entries.map { it.title })
        val later = LeashLayout(Day(2026, 12, 26), listOf(entry("Weihnachten", s, Day(2026, 12, 26))), 13f, 20f, 46f, 18f)
        assertEquals(listOf("Weihnachten"), later.nodes.first().entries.map { it.title })
    }

    @Test fun humanYears() {
        assertEquals(8, DogFacts.humanYears(6.0, 6.0))
        assertEquals(24, DogFacts.humanYears(24.0, 6.0))
        assertEquals(32, DogFacts.humanYears(48.0, 6.0))
        assertEquals(38, DogFacts.humanYears(48.0, 40.0))
    }

    @Test fun eigeneBewertungZaehltNurMitInhalt() {
        assertFalse(app.thisdog.gassi.PlaceService.Mine().isRated)
        assertFalse(app.thisdog.gassi.PlaceService.Mine(sizes = app.thisdog.gassi.PlaceService.Sizes()).isRated)
        assertTrue(app.thisdog.gassi.PlaceService.Mine(votes = mapOf("water" to 0)).isRated)
        assertTrue(app.thisdog.gassi.PlaceService.Mine(sizes = app.thisdog.gassi.PlaceService.Sizes(large = true)).isRated)
    }
}

class SayingTest {
    @Test fun rotates() {
        val day = Day(java.time.LocalDate.of(2026, 11, 11))
        org.junit.Assert.assertNotEquals(Saying.of(day), Saying.of(day.addingDays(1)))
        org.junit.Assert.assertEquals(Saying.of(day), Saying.of(day.addingDays(Saying.all.size)))
        org.junit.Assert.assertEquals(Saying.all.size, Saying.all.toSet().size)
        org.junit.Assert.assertTrue(Saying.of(Day(java.time.LocalDate.of(2025, 6, 1))).isNotEmpty())
    }
}
