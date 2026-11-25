package com.example.audiobook_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts BYOK TTS API keys at rest using an Android Keystore AES-256-GCM key.
 * Keys never leave the device except in direct HTTPS requests to the chosen provider.
 */
class SecureKeyStore(private val context: Context) {
    private var channel: MethodChannel? = null

    fun attach(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "readAll" -> result.success(readAll())
                    "write" -> {
                        val key = call.argument<String>("key")
                        val value = call.argument<String>("value")
                        if (key.isNullOrEmpty() || value == null) {
                            result.error("invalid_args", "Missing key or value", null)
                        } else {
                            write(key, value)
                            result.success(null)
                        }
                    }
                    "delete" -> {
                        val key = call.argument<String>("key")
                        if (key.isNullOrEmpty()) {
                            result.error("invalid_args", "Missing key", null)
                        } else {
                            delete(key)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("keystore_error", e.message ?: "Keystore operation failed", null)
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun prefs() = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun getOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = ks.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun encrypt(plaintext: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(iv.size + ciphertext.size)
        System.arraycopy(iv, 0, combined, 0, iv.size)
        System.arraycopy(ciphertext, 0, combined, iv.size, ciphertext.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String? {
        return try {
            val combined = Base64.decode(encoded, Base64.NO_WRAP)
            if (combined.size <= GCM_IV_LENGTH) return null
            val iv = combined.copyOfRange(0, GCM_IV_LENGTH)
            val ciphertext = combined.copyOfRange(GCM_IV_LENGTH, combined.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    private fun readAll(): Map<String, String> {
        val out = mutableMapOf<String, String>()
        for ((k, v) in prefs().all) {
            if (v is String) {
                val plain = decrypt(v)
                if (plain != null) out[k] = plain
            }
        }
        return out
    }

    private fun write(key: String, value: String) {
        if (value.isEmpty()) {
            delete(key)
            return
        }
        prefs().edit().putString(key, encrypt(value)).apply()
    }

    private fun delete(key: String) {
        prefs().edit().remove(key).apply()
    }

    companion object {
        private const val CHANNEL_NAME = "dogreader/keystore"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "dogreader_byok_aes_gcm"
        private const val PREFS_NAME = "dogreader_byok_keys"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_LENGTH = 12
        private const val GCM_TAG_BITS = 128
    }
}
