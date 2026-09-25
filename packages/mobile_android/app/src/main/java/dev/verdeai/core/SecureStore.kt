package dev.verdeai.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

interface SecureStore {
    suspend fun get(key: String): String?
    suspend fun put(key: String, value: String)
    suspend fun delete(key: String)
}

/** Share one instance per application. DataStore commits encrypted replacements atomically. */
class AndroidSecureStore(context: Context) : SecureStore {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val store: DataStore<Map<String, String>> = DataStoreFactory.create(
        serializer = CredentialSerializer(), scope = scope,
        produceFile = { java.io.File(context.applicationContext.noBackupFilesDir, "core-credentials") },
    )
    override suspend fun get(key: String) = store.data.first()[key]
    override suspend fun put(key: String, value: String) { store.updateData { it + (key to value) } }
    override suspend fun delete(key: String) { store.updateData { it - key } }
    suspend fun close() { scope.coroutineContext[Job]!!.cancelAndJoin() }
}

/** A fresh data key per commit, wrapped by a non-exportable Android Keystore key. */
internal class CredentialSerializer(private val testMaster: (() -> SecretKey)? = null) : Serializer<Map<String, String>> {
    override val defaultValue: Map<String, String> = emptyMap()
    private fun master(): SecretKey {
        testMaster?.let { return it() }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("verde-core-store-v1", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("verde-core-store-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    private fun encrypt(key: SecretKey, bytes: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(byteArrayOf(1))
        return cipher.iv + cipher.doFinal(bytes)
    }
    private fun decrypt(key: SecretKey, bytes: ByteArray): ByteArray {
        require(bytes.size >= 28) { "invalid_store" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(byteArrayOf(1))
        return cipher.doFinal(bytes, 12, bytes.size - 12)
    }
    override suspend fun readFrom(input: InputStream): Map<String, String> {
        val bytes = input.readBytes()
        require(bytes.size >= 65 && bytes[0] == 1.toByte()) { "invalid_store" }
        val key = decrypt(master(), bytes.copyOfRange(1, 61))
        try {
            return CoreJson.decodeFromString(decrypt(SecretKeySpec(key, "AES"), bytes.copyOfRange(61, bytes.size)).decodeToString())
        } finally { key.fill(0) }
    }
    override suspend fun writeTo(t: Map<String, String>, output: OutputStream) {
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val raw = key.encoded
        try {
            output.write(byteArrayOf(1))
            output.write(encrypt(master(), raw)) // 12-byte IV + 32-byte key + 16-byte tag.
            output.write(encrypt(key, CoreJson.encodeToString(t).encodeToByteArray()))
        } finally { raw.fill(0) }
    }
}
