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

/** Per-provider AES-GCM storage backed by non-exportable Android Keystore keys. */
class ProviderSecureStorage(context: Context, private val provider: String) {
    private val preferences = context.getSharedPreferences("gather_${validatedProvider()}_auth", Context.MODE_PRIVATE)
    private val keyAlias = "gather.${validatedProvider()}.auth.v1"

    fun read(): String? {
        val encoded = preferences.getString(VALUE_KEY, null) ?: return null
        try {
            val payload = Base64.decode(encoded, Base64.NO_WRAP)
            require(payload.size > IV_BYTES) { "Stored authorization data is incomplete" }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, payload.copyOfRange(0, IV_BYTES)))
            return String(cipher.doFinal(payload.copyOfRange(IV_BYTES, payload.size)), StandardCharsets.UTF_8)
        } catch (e: Exception) {
            throw IllegalStateException("Could not decrypt saved ${providerLabel()} authorization", e)
        }
    }

    fun write(value: String) {
        require(value.length <= MAX_VALUE_LENGTH) { "${providerLabel()} authorization data is too large" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        check(preferences.edit().putString(VALUE_KEY, Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)).commit()) {
            "Could not save encrypted ${providerLabel()} authorization"
        }
    }

    fun clear() {
        check(preferences.edit().remove(VALUE_KEY).commit()) { "Could not remove ${providerLabel()} authorization" }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        val existing = keyStore.getKey(keyAlias, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
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

    private fun validatedProvider(): String {
        require(provider in SUPPORTED_PROVIDERS) { "Unsupported secure-storage provider" }
        return provider
    }

    private fun providerLabel(): String = when (provider) {
        "instagram" -> "Instagram"
        "x" -> "X"
        else -> "Platform"
    }

    private companion object {
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val VALUE_KEY = "encrypted_session"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
        const val MAX_VALUE_LENGTH = 32_768
        val SUPPORTED_PROVIDERS = setOf("instagram", "x")
    }
}
