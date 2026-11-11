package app.thisdog

import app.thisdog.model.Day
import app.thisdog.model.DogEvent
import app.thisdog.model.Repetition
import app.thisdog.system.Reminders
import app.thisdog.system.SystemCalendar
import java.time.LocalDate
import java.time.LocalDateTime
import org.junit.Assert.assertEquals
import org.junit.Test

class RemindersTest {
    private val now = LocalDateTime.of(2026, 10, 18, 9, 0)

    @Test fun timedEventsOneHourBeforeAllDayAtEight() {
        val plan = Reminders.upcoming(listOf(
            DogEvent(id = "a", title = "Tierarzt", start = "2026-10-20", time = "10:30"),
            DogEvent(id = "b", title = "Krallen", start = "2026-10-19"),
            DogEvent(id = "c", title = "Vorbei", start = "2026-10-18"),  // heute 8 Uhr ist schon vorbei
        ), emptyList(), now)
        assertEquals(listOf("Krallen" to LocalDateTime.of(2026, 10, 19, 8, 0), "Tierarzt" to LocalDateTime.of(2026, 10, 20, 9, 30)),
            plan.map { it.second.title to it.first })
        assertEquals("Um 10:30 Uhr", Reminders.body(plan[1].second))
        assertEquals("Heute", Reminders.body(plan[0].second))
    }

    @Test fun seriesRuleUntilEndOfDay() {
        assertEquals("FREQ=WEEKLY;INTERVAL=2;UNTIL=20261231T235959Z", SystemCalendar.rrule(Repetition.BIWEEKLY, Day(LocalDate.of(2026, 12, 31))))
        assertEquals("FREQ=MONTHLY;INTERVAL=3", SystemCalendar.rrule(Repetition.QUARTERLY, null))
    }

    @Test fun clockParsing() {
        assertEquals(9 to 5, Reminders.clock("09:05")); assertEquals(null, Reminders.clock("24:00")); assertEquals(null, Reminders.clock(""))
    }
}
