package app.thisdog

import app.thisdog.crypto.Sealing
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SealingTest {
    // Erzeugt mit CryptoKit (iOS), siehe Sealing.swift: fester Schlüssel und feste Nonce.
    private val key = Sealing.decodeKey("AAcOFRwjKjE4P0ZNVFtiaXB3foWMk5qhqK-2vcTL0tk")!!
    private val context = "thisdog/record/1/event/evt_vektor"
    private val sealedByIos = "oKGio6SlpqeoqaqrowoGK5RJR4kpsVd0cOg8cyflCsMaB0XSqTIn5TslZ6A0oKQevbMoV4FuXD2VkByato9sSHte+SMj"
    private val plain = """{"start":"2026-10-20","title":"Tierarzt"}"""

    @Test fun opensWhatIosSealed() {
        val opened = Sealing.open(JsonObject(mapOf("e" to JsonPrimitive(sealedByIos))), key, context)
        assertEquals(Json.parseToJsonElement(plain), opened)
    }

    @Test fun sealsExactlyLikeIos() {
        val nonce = ByteArray(12) { (0xA0 + it).toByte() }
        val sealed = Sealing.seal(Json.parseToJsonElement(plain), key, context, nonce) as JsonObject
        assertEquals(sealedByIos, (sealed["e"] as JsonPrimitive).content)
    }

    @Test fun refusesWrongKeyPlaceOrTampering() {
        val box = JsonObject(mapOf("e" to JsonPrimitive(sealedByIos)))
        assertTrue(runCatching { Sealing.open(box, Sealing.newKey(), context) }.exceptionOrNull() is Sealing.CannotOpen)
        assertTrue(runCatching { Sealing.open(box, key, "thisdog/record/1/event/anderer") }.exceptionOrNull() is Sealing.CannotOpen)
        val bytes = Base64.getDecoder().decode(sealedByIos).also { it[20] = (it[20].toInt() xor 1).toByte() }
        val broken = JsonObject(mapOf("e" to JsonPrimitive(Base64.getEncoder().encodeToString(bytes))))
        assertTrue(runCatching { Sealing.open(broken, key, context) }.exceptionOrNull() is Sealing.CannotOpen)
        assertFalse(Sealing.isSealed(Json.parseToJsonElement(plain)))
    }

    @Test fun keyTravelsInLinkFragment() {
        val k = Sealing.newKey()
        assertTrue(k.contentEquals(Sealing.keyFromFragment("k=" + Sealing.encodeKey(k))!!))
        assertEquals(null, Sealing.keyFromFragment("k=kurz"))
    }
}

class RecoveryCodeTest {
    private val vector = "000G4-0R40M-30E20-9185G-R38E1-W8124-GK2GA-HC5RR-34D1P-70X3R-FSCSG"

    @org.junit.Test fun gleichesFormatWieIOS() {
        val key = ByteArray(32) { it.toByte() }
        assertEquals(vector, app.thisdog.crypto.RecoveryCode.encode(key))
        assertTrue(key.contentEquals(app.thisdog.crypto.RecoveryCode.decode(vector.lowercase().replace("-", " "))))
    }

    @org.junit.Test fun tippfehlerFallenAuf() {
        assertEquals(null, app.thisdog.crypto.RecoveryCode.decode(vector.dropLast(1)))
        assertEquals(null, app.thisdog.crypto.RecoveryCode.decode(""))
        val chars = vector.toCharArray()
        for (i in chars.indices) if (chars[i] != '-') {
            val c = chars.copyOf(); c[i] = if (c[i] == 'A') 'B' else 'A'
            assertEquals(null, app.thisdog.crypto.RecoveryCode.decode(String(c)))
        }
    }

    @org.junit.Test fun passtNurZumRichtigenRudel() {
        val key = Sealing.newKey()
        val payload = Sealing.seal(JsonPrimitive("Tierarzt"), key, Sealing.recordContext(7, "event", "a"))
        val records = listOf(app.thisdog.data.SyncRecord("event", "a", 1.0, payload = payload))
        assertTrue(app.thisdog.crypto.RecoveryCode.fits(key, records, 7))
        assertFalse(app.thisdog.crypto.RecoveryCode.fits(Sealing.newKey(), records, 7))
        assertFalse(app.thisdog.crypto.RecoveryCode.fits(key, records, 8))
        assertTrue(app.thisdog.crypto.RecoveryCode.fits(key, emptyList(), 7))
    }

    @org.junit.Test fun startseiteUndTitel() {
        assertEquals("Zeit für eine Runde?", app.thisdog.ui.Home.headline(walking = false, walkedToday = false))
        assertEquals("Ihr seid unterwegs.", app.thisdog.ui.Home.headline(walking = true, walkedToday = true))
        assertEquals("Guten Morgen", app.thisdog.ui.Home.salute(7))
        val d = app.thisdog.model.Day.today()
        val e = app.thisdog.model.CalendarEntry("a", null, "🐶 Fellwechsel", d, d, "", "", app.thisdog.model.EntryKind.SEASONAL, null, "")
        assertEquals("Fellwechsel", e.plainTitle)
    }
}
