package app.thisdog.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Wo die Rudel-Schlüssel liegen. Auf dem Gerät im Android-Keystore verschlüsselt, im Test im Speicher. */
interface KeyVault {
    fun packKey(pack: Int): ByteArray?
    fun setPackKey(key: ByteArray, pack: Int)
    fun removePackKey(pack: Int)

    class Memory : KeyVault {
        private val m = mutableMapOf<Int, ByteArray>()
        override fun packKey(pack: Int) = m[pack]
        override fun setPackKey(key: ByteArray, pack: Int) { m[pack] = key }
        override fun removePackKey(pack: Int) { m.remove(pack) }
    }
}

/**
 * Die Rudel-Schlüssel müssen sich weitergeben lassen (Einladungslink), ein Keystore-Schlüssel nicht. Deshalb liegt
 * jeder Rudel-Schlüssel mit einem Gerätschlüssel aus dem Android-Keystore verschlüsselt in den Einstellungen – der
 * Gerätschlüssel selbst verlässt die sichere Hardware nie.
 */
class AndroidKeyVault(context: Context) : KeyVault {
    private val prefs = context.getSharedPreferences("rudel-schluessel", Context.MODE_PRIVATE)
    private val alias = "thisdog-geraet"

    private fun deviceKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return gen.generateKey()
    }

    override fun packKey(pack: Int): ByteArray? {
        val stored = prefs.getString("pack-$pack", null) ?: return null
        return runCatching {
            val data = Base64.getDecoder().decode(stored)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, deviceKey(), GCMParameterSpec(128, data, 0, 12))
            c.doFinal(data, 12, data.size - 12)
        }.getOrNull()?.takeIf { it.size == 32 }
    }

    override fun setPackKey(key: ByteArray, pack: Int) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, deviceKey())
        // Sofort auf die Platte: Stirbt die App gleich danach, wäre der Schlüssel sonst weg und das Rudel nicht mehr lesbar.
        prefs.edit().putString("pack-$pack", Base64.getEncoder().encodeToString(c.iv + c.doFinal(key))).commit()
    }

    override fun removePackKey(pack: Int) { prefs.edit().remove("pack-$pack").apply() }
}
