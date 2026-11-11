package app.thisdog

import app.thisdog.data.DogStore
import app.thisdog.data.Kinds
import app.thisdog.data.SyncRecord
import app.thisdog.data.ThisDogJson
import app.thisdog.model.Avatar
import app.thisdog.model.DogEvent
import app.thisdog.model.DogProfile
import java.io.File
import java.nio.file.Files
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dieselben Fälle wie SyncTests.swift. */
class StoreTest {
    private var clock = 1_000_000.0
    private fun fresh() = DogStore(File(Files.createTempDirectory("store").toFile(), "thisdog.json")) { clock += 10; clock }
    private fun record(id: String, title: String?, at: Double, by: Int? = null) = SyncRecord("event", id, at, by,
        title?.let { ThisDogJson.encodeToJsonElement(DogEvent.serializer(), DogEvent(id = id, title = it, start = "2026-10-20", u = at)) })

    /** Beitreten: Profil des Rudels gilt, nicht das beim Einrichten getippte; ein Hundebild, das das Rudel nicht hat, kommt dazu. */
    @Test fun joinKeepsPackDog() {
        val s = fresh()
        s.save(DogProfile(name = "stella"))
        s.upsert(Kinds.avatar, Avatar(Avatar.DOG, "AAAA"))
        s.save(DogEvent(id = "evt_mein", title = "Tierarzt", start = "2026-11-12"))
        s.joinPack(7)
        val out = s.outgoingRecords().map { it.kind }.toSet()
        assertTrue("event" in out); assertTrue("profile" !in out && "avatar" !in out)
        val pack = ThisDogJson.encodeToJsonElement(DogProfile.serializer(), DogProfile(name = "Stella", chip = "276"))
        s.applyIncoming(listOf(SyncRecord("profile", "profile", 10.0, payload = pack)), 3, emptyList())
        s.claimUnanswered()
        assertEquals("Stella", s.profile.name); assertEquals("276", s.profile.chip)
        val after = s.outgoingRecords()
        assertTrue(after.any { it.kind == "avatar" && it.id == Avatar.DOG && it.updatedAt > 0 })
        assertTrue(after.none { it.kind == "profile" })
    }

    /** Beitreten: Schlüssel von Hundefreundschaften gehören zum alten Rudel und wandern nicht mit. */
    @Test fun joinLeavesFriendKeys() {
        val s = fresh()
        s.upsert(Kinds.friendKey, app.thisdog.model.FriendKey("inv_a", "AAAA"))
        s.save(DogEvent(id = "evt_mein", title = "Tierarzt", start = "2026-11-12"))
        s.joinPack(7)
        val out = s.outgoingRecords().map { it.kind }.toSet()
        assertTrue("event" in out); assertTrue("friendkey" !in out)
    }

    /** Ein offener Notfallpass schreibt nur seine eigenen Änderungen zurück, nicht den veralteten Rest. */
    @Test fun profileEditsMergeOntoCurrent() {
        val base = DogProfile(name = "Anna")                       // was beim Öffnen da war (falsch, vom Einrichten)
        val draft = base.copy(chip = "276")                        // hier geändert: nur die Chipnummer
        val current = DogProfile(name = "Stella", vetName = "Dr. Huber", u = 50.0)  // inzwischen vom Rudel
        val merged = current.applying(draft, base)
        assertEquals("Stella", merged.name); assertEquals("276", merged.chip); assertEquals("Dr. Huber", merged.vetName)
    }

    @Test fun outgoing() {
        val s = fresh()
        s.save(DogEvent(id = "evt_a", title = "Tierarzt", start = "2026-10-20"))
        val out = s.outgoingRecords()
        assertEquals(1, out.size); assertEquals("event", out[0].kind)
        assertEquals("Tierarzt", ThisDogJson.decodeFromJsonElement(DogEvent.serializer(), out[0].payload!!).title)
        assertEquals(JsonPrimitive("monthly").let { "repeat" }, (out[0].payload as JsonObject).keys.first { it == "repeat" })
    }

    @Test fun clearedAfterSync() {
        val s = fresh(); s.save(DogEvent(id = "evt_a", title = "Tierarzt", start = "2026-10-20"))
        s.applyIncoming(emptyList(), 3, s.outgoingRecords())
        assertTrue(s.outgoingRecords().isEmpty()); assertEquals(3, s.rev)
    }

    @Test fun editDuringSync() {
        val s = fresh(); s.save(DogEvent(id = "evt_a", title = "Tierarzt", start = "2026-10-20"))
        val sent = s.outgoingRecords()
        s.save(s.event("evt_a")!!.copy(title = "Tierarzt, 10:30"))
        s.applyIncoming(emptyList(), 3, sent)
        assertEquals(listOf("evt_a"), s.outgoingRecords().map { it.id })
    }

    @Test fun incoming() {
        val s = fresh(); s.save(DogEvent(id = "evt_a", title = "Meins", start = "2026-10-20"))
        val mine = s.event("evt_a")!!
        s.applyIncoming(listOf(record("evt_a", "Älter", mine.u - 1000, 7)), 1, emptyList())
        assertEquals("Meins", s.event("evt_a")!!.title)
        s.applyIncoming(listOf(record("evt_a", "Neuer", mine.u + 1000, 7), record("evt_b", "Von Anna", 5.0, 7)), 2, emptyList())
        assertEquals("Neuer", s.event("evt_a")!!.title); assertEquals("Von Anna", s.event("evt_b")!!.title)
        assertEquals(7, s.changedBy["event:evt_b"])
    }

    @Test fun incomingDelete() {
        val s = fresh()
        s.applyIncoming(listOf(record("evt_b", "Von Anna", 5.0)), 1, emptyList())
        s.applyIncoming(listOf(record("evt_b", null, 9.0)), 2, emptyList())
        assertNull(s.event("evt_b")); assertTrue(s.outgoingRecords().isEmpty())
    }

    @Test fun ownDelete() {
        val s = fresh()
        s.applyIncoming(listOf(record("evt_b", "Von Anna", 5.0)), 1, emptyList())
        s.deleteEvent("evt_b")
        val out = s.outgoingRecords()
        assertEquals(listOf("evt_b"), out.map { it.id }); assertNull(out[0].payload)
    }

    @Test fun switching() {
        val s = fresh(); s.save(DogEvent(id = "evt_a", title = "Meins", start = "2026-10-20"))
        s.applyIncoming(emptyList(), 4, s.outgoingRecords())
        s.switchPack(9, keepLocal = true)
        assertEquals(0, s.rev); assertEquals(listOf("evt_a"), s.outgoingRecords().map { it.id })
        s.switchPack(null, keepLocal = false)
        assertTrue(s.events.isEmpty()); assertTrue(s.outgoingRecords().isEmpty())
    }

    @Test fun webRecordWithoutStamp() {
        val s = fresh()
        s.applyIncoming(listOf(SyncRecord("favorite", "Nudeln (gekocht, ohne Salz)", 1_755_000_000_000.0, 2,
            JsonObject(mapOf("name" to JsonPrimitive("Nudeln (gekocht, ohne Salz)"))))), 1, emptyList())
        assertEquals(listOf("Nudeln (gekocht, ohne Salz)"), s.favorites.map { it.name })
    }

    @Test fun survivesRestart() {
        val dir = Files.createTempDirectory("store").toFile()
        val a = DogStore(File(dir, "thisdog.json"))
        a.save(DogEvent(id = "evt_a", title = "Tierarzt", start = "2026-10-20")); a.saveWeight(6.0)
        val b = DogStore(File(dir, "thisdog.json"))
        assertEquals("Tierarzt", b.event("evt_a")!!.title); assertEquals(6.0, b.profile.weightKg!!, 0.0)
        assertEquals(a.outgoingRecords().map { it.id }.toSet(), b.outgoingRecords().map { it.id }.toSet())
        assertTrue(b.list(Kinds.weight).isNotEmpty())
    }
}
