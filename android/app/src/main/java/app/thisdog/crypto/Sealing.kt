package app.thisdog.crypto

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/**
 * Ende-zu-Ende-Verschlüsselung, genau wie in der iOS-Fassung (Sealing.swift): AES-GCM mit 256 Bit,
 * jeder Datensatz an seinen Platz gebunden (Rudel, Art, Kennung als „additional authenticated data“).
 *
 * Auf dem Server liegt ein Datensatz als `{"e": "<Base64 aus Nonce, Geheimtext, Prüfsumme>"}` – dasselbe Format
 * wie CryptoKits `combined`: 12 Byte Nonce, dann Geheimtext mit angehängter 16-Byte-Prüfsumme.
 */
object Sealing {
    class NotSealed : Exception()
    class CannotOpen : Exception()

    private const val NONCE = 12
    private const val TAG_BITS = 128
    private val random = SecureRandom()

    fun newKey(): ByteArray = ByteArray(32).also { random.nextBytes(it) }

    fun seal(value: JsonElement, key: ByteArray, context: String, nonce: ByteArray? = null): JsonElement {
        val plain = Json.encodeToString(JsonElement.serializer(), value).toByteArray()
        return JsonObject(mapOf("e" to JsonPrimitive(Base64.getEncoder().encodeToString(sealBytes(plain, key, context, nonce)))))
    }

    fun open(sealed: JsonElement, key: ByteArray, context: String): JsonElement {
        val b64 = (sealed as? JsonObject)?.get("e")?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw NotSealed()
        val data = runCatching { Base64.getDecoder().decode(b64) }.getOrElse { throw NotSealed() }
        val plain = openBytes(data, key, context)
        return runCatching { Json.parseToJsonElement(plain.decodeToString()) }.getOrElse { throw CannotOpen() }
    }

    fun isSealed(value: JsonElement?): Boolean {
        val o = value as? JsonObject ?: return false
        return o.size == 1 && (o["e"] as? JsonPrimitive)?.isString == true
    }

    /** Für Pakete an Freunde: Base64 ohne Hülle. */
    fun sealBlob(plain: ByteArray, key: ByteArray, context: String): String =
        Base64.getEncoder().encodeToString(sealBytes(plain, key, context, null))

    fun openBlob(blob: String, key: ByteArray, context: String): ByteArray =
        openBytes(runCatching { Base64.getDecoder().decode(blob) }.getOrElse { throw NotSealed() }, key, context)

    fun recordContext(pack: Int, kind: String, id: String) = "thisdog/record/$pack/$kind/$id"
    fun friendContext(what: String, from: Int, to: Int) = "thisdog/friend/$what/$from/$to"

    private fun sealBytes(plain: ByteArray, key: ByteArray, context: String, fixedNonce: ByteArray?): ByteArray {
        val nonce = fixedNonce ?: ByteArray(NONCE).also { random.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        c.updateAAD(context.toByteArray())
        return nonce + c.doFinal(plain)
    }

    private fun openBytes(data: ByteArray, key: ByteArray, context: String): ByteArray {
        if (data.size < NONCE + 16) throw CannotOpen()
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, data, 0, NONCE))
            c.updateAAD(context.toByteArray())
            c.doFinal(data, NONCE, data.size - NONCE)
        } catch (e: Exception) {
            throw CannotOpen()
        }
    }

    // Schlüssel als Text für den Einladungslink (#k=…): Base64url ohne Auffüllung.
    fun encodeKey(key: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(key)

    fun decodeKey(text: String): ByteArray? =
        runCatching { Base64.getUrlDecoder().decode(text) }.getOrNull()?.takeIf { it.size == 32 }

    fun keyFromFragment(fragment: String?): ByteArray? =
        fragment?.split("&")?.firstOrNull { it.startsWith("k=") }?.let { decodeKey(it.removePrefix("k=")) }
}
