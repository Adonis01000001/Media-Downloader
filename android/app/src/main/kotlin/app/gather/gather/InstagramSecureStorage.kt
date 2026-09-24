package app.gather.gather

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypts the short-lived OAuth handoff and Instagram session with a non-exportable Keystore key. */
class InstagramSecureStorage(context: Context) {
    private val preferences = context.getSharedPreferences("gather_instagram_auth", Context.MODE_PRIVATE)

    fun read(): String? {
        val encoded = preferences.getString(VALUE_KEY, null) ?: return null
        try {
            val payload = Base64.decode(encoded, Base64.NO_WRAP)
            require(payload.size > IV_BYTES) { "Stored Instagram authorization data is incomplete" }
            val iv = payload.copyOfRange(0, IV_BYTES)
            val encrypted = payload.copyOfRange(IV_BYTES, payload.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
            return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
        } catch (e: Exception) {
            throw IllegalStateException("Could not decrypt saved Instagram authorization", e)
        }
    }

    fun write(value: String) {
        require(value.length <= MAX_VALUE_LENGTH) { "Instagram authorization data is too large" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val payload = cipher.iv + encrypted
        check(preferences.edit().putString(VALUE_KEY, Base64.encodeToString(payload, Base64.NO_WRAP)).commit()) {
            "Could not save encrypted Instagram authorization"
        }
    }

    fun clear() {
        check(preferences.edit().remove(VALUE_KEY).commit()) { "Could not remove Instagram authorization" }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val KEY_ALIAS = "gather.instagram.auth.v1"
        const val VALUE_KEY = "encrypted_session"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
        const val MAX_VALUE_LENGTH = 32_768
    }
}
