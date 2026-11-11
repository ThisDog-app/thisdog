package app.thisdog

import app.thisdog.data.ThisDogJson
import app.thisdog.model.*
import java.time.LocalDateTime
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Termine über mehrere Tage mit Uhrzeiten: Format im Abgleich, Editor (Beginn/Ende) und Anzeige. */
class TerminZeitTest {
    private fun at(s: String) = LocalDateTime.parse(s)

    // MARK: Format
    @Test fun endTimeRoundTrip() {
        val ev = DogEvent(id = "evt_x", title = "Urlaub", start = "2026-11-14", end = "2026-11-16", time = "18:00", endTime = "12:00")
        val obj = ThisDogJson.encodeToJsonElement(DogEvent.serializer(), ev) as JsonObject
        assertEquals(JsonPrimitive("12:00"), obj["endTime"])
        assertEquals(ev, ThisDogJson.decodeFromJsonElement(DogEvent.serializer(), obj))
    }
    @Test fun oldRecordWithoutEndTime() {
        val ev = ThisDogJson.decodeFromString(DogEvent.serializer(), """{"id":"evt_a","title":"Tierarzt","start":"2026-11-14","time":"10:30"}""")
        assertEquals("", ev.endTime); assertEquals("10:30", ev.time)
    }

    // MARK: Editor
    @Test fun newEventNextFullHour() {
        val t = EventTiming.of(DogEvent(start = "2026-11-20"), isNew = true, now = at("2026-11-10T09:12"))
        assertFalse(t.allDay); assertEquals(at("2026-11-20T10:00"), t.begin); assertEquals(at("2026-11-20T11:00"), t.finish)
        val late = EventTiming.of(DogEvent(start = "2026-11-10"), isNew = true, now = at("2026-11-10T23:30"))
        assertEquals(at("2026-11-11T00:00"), late.begin)
    }
    @Test fun existingEvents() {
        val now = at("2026-11-10T09:12")
        val allDay = EventTiming.of(DogEvent(start = "2026-11-14", end = "2026-11-16"), isNew = false, now = now)
        assertTrue(allDay.allDay); assertEquals("2026-11-16", allDay.finish.toLocalDate().toString())
        val noEnd = EventTiming.of(DogEvent(start = "2026-11-14", time = "10:30"), isNew = false, now = now)
        assertEquals(at("2026-11-14T11:30"), noEnd.finish)
        val span = EventTiming.of(DogEvent(start = "2026-11-14", end = "2026-11-16", time = "18:00", endTime = "12:00"), isNew = false, now = now)
        assertEquals(at("2026-11-16T12:00"), span.finish)
        // Ohne Endzeit kurz vor Mitternacht wächst der Termin nicht auf den nächsten Tag.
        val late = EventTiming.of(DogEvent(start = "2026-11-14", time = "23:30"), isNew = false, now = now)
        assertEquals(at("2026-11-14T23:59"), late.finish)
        // Über mehrere Tage ohne Endzeit: am letzten Tag zur Uhrzeit des Beginns, nicht eine Stunde später.
        val spanNoEnd = EventTiming.of(DogEvent(start = "2026-11-14", end = "2026-11-16", time = "18:00"), isNew = false, now = now)
        assertEquals(at("2026-11-16T18:00"), spanNoEnd.finish)
    }
    @Test fun beginMovesEnd() {
        val t = EventTiming(false, at("2026-11-14T18:00"), at("2026-11-16T12:00")).movingBegin(at("2026-11-15T18:00"))
        assertEquals(at("2026-11-17T12:00"), t.finish)
    }
    @Test fun saveMapping() {
        val base = DogEvent(id = "evt_x", title = "T")
        val oneDay = EventTiming(false, at("2026-11-14T10:00"), at("2026-11-14T11:00")).applied(base)
        assertEquals(listOf("2026-11-14", "", "10:00", "11:00"), listOf(oneDay.start, oneDay.end, oneDay.time, oneDay.endTime))
        val span = EventTiming(false, at("2026-11-14T18:00"), at("2026-11-16T12:00")).applied(base)
        assertEquals(listOf("2026-11-14", "2026-11-16", "18:00", "12:00"), listOf(span.start, span.end, span.time, span.endTime))
        val point = EventTiming(false, at("2026-11-14T10:00"), at("2026-11-14T10:00")).applied(base)
        assertEquals("", point.endTime)
        val allDay = EventTiming(true, at("2026-11-14T18:00"), at("2026-11-16T12:00")).applied(base.copy(time = "18:00", endTime = "12:00"))
        assertEquals(listOf("2026-11-14", "2026-11-16", "", ""), listOf(allDay.start, allDay.end, allDay.time, allDay.endTime))
        assertFalse(EventTiming(false, at("2026-11-14T10:00"), at("2026-11-14T09:00")).isValid)
        assertTrue(EventTiming(true, at("2026-11-14T10:00"), at("2026-11-14T09:00")).isValid)
    }

    // MARK: Anzeige
    @Test fun texts() {
        val same = CalendarBuilder.occurrences(DogEvent(start = "2026-11-14", time = "10:00", endTime = "11:00")).single()
        assertEquals("10:00–11:00 Uhr", same.timeText)
        val span = CalendarBuilder.occurrences(DogEvent(start = "2026-11-14", end = "2026-11-16", time = "18:00", endTime = "12:00")).single()
        assertEquals("Sa 14. Nov., 18:00 – Mo 16. Nov., 12:00 Uhr", span.whenText)
        assertEquals("bis Mo 16. Nov., 12:00", span.untilText)
        // Ganztägig trägt keine Endzeit weiter.
        assertEquals("", CalendarBuilder.occurrences(DogEvent(start = "2026-11-14", endTime = "12:00")).single().endTime)
    }
}
