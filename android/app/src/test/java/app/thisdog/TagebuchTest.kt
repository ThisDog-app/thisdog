package app.thisdog

import app.thisdog.data.DogStore
import app.thisdog.data.EmergencySnapshot
import app.thisdog.data.Kinds
import app.thisdog.data.SyncRecord
import app.thisdog.data.ThisDogJson
import app.thisdog.model.*
import java.nio.file.Files
import java.time.LocalDateTime
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Gesundheitstagebuch und Hund entlaufen – dieselben Fälle wie HealthNoteTests und LostDogTests auf iOS. */
class TagebuchTest {
    private fun store() = DogStore(Files.createTempFile("tagebuch", ".json").toFile())

    @Test fun notesSyncBetweenDevices() {
        val a = store()
        a.save(HealthNote(d = "2026-11-01", time = "08:15", tags = listOf("Erbrochen"), text = "nach dem Frühstück"))
        val out = a.outgoingRecords()
        assertTrue(out.any { it.kind == "notes" })
        val b = store()
        b.applyIncoming(out, 1, emptyList())
        assertEquals(listOf("Erbrochen"), b.notes.single().tags)
        assertEquals("08:15", b.notes.single().time)
        val text = HealthNote.vetSummary(b.notes, "Stella", Day.parse("2026-11-09")!!)
        assertTrue(text.contains("Stella"))
        assertTrue(text, text.contains("01.11.2026 08:15 – Erbrochen: nach dem Frühstück"))
    }

    @Test fun recordWithMissingFieldsDecodes() {
        val b = store()
        b.applyIncoming(listOf(SyncRecord("notes", "notes_1", 5.0, payload = JsonObject(mapOf("id" to JsonPrimitive("notes_1"), "d" to JsonPrimitive("2026-10-01"))))), 1, emptyList())
        val n = b.notes.single()
        assertTrue(n.tags.isEmpty() && n.text.isEmpty()); assertNull(n.photo)
    }

    /** Ein Profil vom iPhone mit Vermisst-Feldern verliert sie nicht, wenn Android es ändert und zurückschickt. */
    @Test fun profileKeepsLostFields() {
        val b = store()
        val fromIos = JsonObject(mapOf("name" to JsonPrimitive("Stella"), "lostSince" to JsonPrimitive("2026-11-09T14:05"),
            "lostWhere" to JsonPrimitive("Augarten"), "lostNote" to JsonPrimitive("Rotes Halsband"), "u" to JsonPrimitive(5.0)))
        b.applyIncoming(listOf(SyncRecord("profile", "profile", 5.0, payload = fromIos)), 1, emptyList())
        assertTrue(b.profile.isLost)
        b.save(b.profile.copy(chip = "123"))
        val sent = b.outgoingRecords().single { it.kind == "profile" }.payload!!.jsonObject
        assertEquals("2026-11-09T14:05", (sent["lostSince"] as JsonPrimitive).content)
        assertEquals("Augarten", (sent["lostWhere"] as JsonPrimitive).content)
        assertEquals("Rotes Halsband", (sent["lostNote"] as JsonPrimitive).content)
        assertFalse(ThisDogJson.decodeFromString(DogProfile.serializer(), """{"name":"Stella"}""").isLost)
    }

    @Test fun flyerHasTheEssentials() {
        val s = store()
        s.save(DogProfile(name = "Stella", breed = "Zwergpudel", ownerName = "Alex", ownerPhone = "+43 660 1",
            lostSince = "2026-11-09T14:05", lostWhere = "Augarten", lostNote = "Rotes Halsband"))
        val text = LostDog.flyer(EmergencySnapshot.from(s), "https://thisdog.app/notfall/abc", LocalDateTime.of(2026, 11, 9, 16, 0))
        assertTrue(text, text.startsWith("Stella wird vermisst!\nSeit heute, 14:05 Uhr · zuletzt gesehen: Augarten."))
        for (part in listOf("Rotes Halsband", "+43 660 1", "https://thisdog.app/notfall/abc", "Zwergpudel")) assertTrue(part, text.contains(part))
        assertEquals("2026-11-09T14:05", LostDog.stamp(LocalDateTime.of(2026, 11, 9, 14, 5)))
        assertEquals("Seit gestern, 14:05 Uhr", LostDog.since("2026-11-09T14:05", "", LocalDateTime.of(2026, 11, 10, 9, 0)))
        // Kennt der Server die Felder, landen sie im Pass.
        assertEquals("Augarten", EmergencySnapshot.from(s).lostWhere)
        assertTrue(Kinds.byName("notes") != null)
    }
}
