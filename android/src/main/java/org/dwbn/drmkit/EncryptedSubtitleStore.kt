package org.dwbn.drmkit

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Authenticated encryption for subtitle files. The blob layout is implementation-defined and
 * includes the random IV. [aad] binds a blob to its download and name.
 */
internal interface SubtitleCipher {
    fun encrypt(plain: ByteArray, aad: ByteArray): ByteArray

    /** Returns null for a wrong key, tampered or truncated blob. */
    fun decrypt(blob: ByteArray, aad: ByteArray): ByteArray?
}

/**
 * AES-256-GCM with a non-exportable Android Keystore key and a random 96-bit IV per file
 * (blob = IV || ciphertext || tag).
 */
internal class KeystoreSubtitleCipher(private val alias: String = DEFAULT_ALIAS) : SubtitleCipher {

    override fun encrypt(plain: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(aad)
        val iv = cipher.iv
        return iv + cipher.doFinal(plain)
    }

    override fun decrypt(blob: ByteArray, aad: ByteArray): ByteArray? {
        if (blob.size <= IV_BYTES) return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES))
            cipher.updateAAD(aad)
            cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    @Synchronized
    private fun key(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        const val DEFAULT_ALIAS = "org.dwbn.drmkit.subtitles"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
    }
}

/**
 * Subtitles (VTT) for offline downloads. Only ciphertext ever reaches disk; the plaintext is
 * returned to the caller in memory by [read]. Use a directory under `Context.noBackupFilesDir`.
 * File and directory names are hashes, so neither download ids nor languages leak.
 */
class EncryptedSubtitleStore internal constructor(
    private val root: File,
    private val cipher: SubtitleCipher,
) {
    /** Production store: ciphertext in [root] (inside `noBackupFilesDir`), key in Android Keystore. */
    constructor(root: File) : this(root, KeystoreSubtitleCipher())

    /** Encrypts [plain] and stores it for [downloadId]/[name] (e.g. a language code), replacing any previous file. */
    @Synchronized
    fun put(downloadId: String, name: String, plain: ByteArray) {
        val dir = downloadDir(downloadId)
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create subtitle directory")
        val target = File(dir, sha256Hex(name) + EXTENSION)
        val tmp = File(dir, target.name + ".tmp")
        tmp.writeBytes(cipher.encrypt(plain, aad(downloadId, name)))
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IOException("cannot persist subtitle")
        }
    }

    /** Returns the original bytes, or null when missing, corrupt or not decryptable. */
    @Synchronized
    fun read(downloadId: String, name: String): ByteArray? {
        val file = File(downloadDir(downloadId), sha256Hex(name) + EXTENSION)
        if (!file.isFile) return null
        return try {
            cipher.decrypt(file.readBytes(), aad(downloadId, name))
        } catch (_: IOException) {
            null
        }
    }

    @Synchronized
    fun delete(downloadId: String, name: String) {
        File(downloadDir(downloadId), sha256Hex(name) + EXTENSION).delete()
    }

    /** Removes every subtitle of [downloadId]. */
    @Synchronized
    fun deleteAll(downloadId: String) {
        downloadDir(downloadId).deleteRecursively()
    }

    private fun downloadDir(downloadId: String) = File(root, sha256Hex(downloadId))

    private fun aad(downloadId: String, name: String) = "$downloadId\u0000$name".toByteArray(Charsets.UTF_8)

    private companion object {
        const val EXTENSION = ".sub"
    }
}
