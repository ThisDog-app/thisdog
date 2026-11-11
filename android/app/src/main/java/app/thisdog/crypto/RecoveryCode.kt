package app.thisdog.crypto

import app.thisdog.data.SyncRecord
import java.security.MessageDigest

/**
 * Der Wiederherstellungsschlüssel (wie RecoveryCode.swift, gleiches Format auf beiden Systemen): der Schlüssel des
 * Rudels als Crockford-Base32 mit zwei Prüfbytes, in Fünfergruppen. Der Server kennt ihn nicht.
 */
object RecoveryCode {
    sealed class Failure : Exception() {
        /** Tippfehler: falsche Länge, falsche Zeichen oder falsche Prüfsumme. */
        object Invalid : Failure() { private fun readResolve(): Any = Invalid }
        /** Richtig geschrieben, öffnet aber die Daten dieses Rudels nicht. */
        object WrongPack : Failure() { private fun readResolve(): Any = WrongPack }
    }

    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private const val CHECK_BYTES = 2
    private const val LENGTH = 55

    fun encode(key: ByteArray): String {
        val bytes = key + check(key)
        val out = StringBuilder()
        var buffer = 0; var bits = 0
        for (b in bytes) {
            buffer = (buffer shl 8) or (b.toInt() and 255); bits += 8
            while (bits >= 5) { bits -= 5; out.append(ALPHABET[(buffer shr bits) and 31]) }
            buffer = buffer and ((1 shl bits) - 1)
        }
        if (bits > 0) out.append(ALPHABET[(buffer shl (5 - bits)) and 31])
        return out.chunked(5).joinToString("-")
    }

    /** Großschreibung, Leerzeichen und Bindestriche sind egal; O gilt als 0, I und L als 1. */
    fun decode(text: String): ByteArray? {
        val clean = text.uppercase().filter { !it.isWhitespace() && it != '-' }
            .map { when (it) { 'O' -> '0'; 'I', 'L' -> '1'; else -> it } }
        if (clean.size != LENGTH) return null
        val out = ArrayList<Byte>(34)
        var buffer = 0; var bits = 0
        for (c in clean) {
            val v = ALPHABET.indexOf(c); if (v < 0) return null
            buffer = (buffer shl 5) or v; bits += 5
            if (bits >= 8) { bits -= 8; out.add(((buffer shr bits) and 255).toByte()) }
            buffer = buffer and ((1 shl bits) - 1)
        }
        // Die letzte Stelle hat drei ungenutzte Bits. Sie müssen null sein, sonst bliebe ein Tippfehler dort unbemerkt.
        if (out.size != 32 + CHECK_BYTES || buffer != 0) return null
        val all = out.toByteArray()
        val key = all.copyOfRange(0, 32)
        return if (all.copyOfRange(32, 34).contentEquals(check(key))) key else null
    }

    private fun check(key: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest("thisdog/recovery".toByteArray() + key).copyOf(CHECK_BYTES)

    /** Passt der Schlüssel zu den Daten des Rudels? Ja, wenn er etwas öffnet oder noch nichts verschlüsselt ist. */
    fun fits(key: ByteArray, records: List<SyncRecord>, pack: Int): Boolean {
        val sealed = records.filter { Sealing.isSealed(it.payload) }
        if (sealed.isEmpty()) return true
        return sealed.any { r -> runCatching { Sealing.open(r.payload!!, key, Sealing.recordContext(pack, r.kind, r.id)) }.isSuccess }
    }
}
