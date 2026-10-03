package org.dwbn.drmkit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** JCE AES-256-GCM with the Keystore cipher's blob layout (IV || ciphertext || tag). */
internal class JceSubtitleCipher(private val key: SecretKey = newKey()) : SubtitleCipher {
    override fun encrypt(plain: ByteArray, aad: ByteArray): ByteArray {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        return iv + cipher.doFinal(plain)
    }

    override fun decrypt(blob: ByteArray, aad: ByteArray): ByteArray? {
        if (blob.size <= 12) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, blob, 0, 12))
            cipher.updateAAD(aad)
            cipher.doFinal(blob, 12, blob.size - 12)
        } catch (_: java.security.GeneralSecurityException) {
            null
        }
    }

    companion object {
        fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    }
}

class EncryptedSubtitleStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var store: EncryptedSubtitleStore

    private val vtt = "WEBVTT\n\n00:00.000 --> 00:02.000\nGuten Morgen, Lama Ole\n".toByteArray()

    @Before
    fun setUp() {
        root = File(tmp.newFolder(), "subs")
        store = EncryptedSubtitleStore(root, JceSubtitleCipher())
    }

    @Test
    fun readReturnsTheOriginal() {
        store.put("dl-1", "de", vtt)
        assertArrayEquals(vtt, store.read("dl-1", "de"))
    }

    @Test
    fun filesOnDiskAreCiphertextWithNoPlaintextOrIdentifiers() {
        store.put("dl-secret", "de-lang", vtt)
        val files = root.walkTopDown().filter { it.isFile }.toList()
        assertEquals(1, files.size)
        val bytes = files.single().readBytes()
        assertFalse(String(bytes, Charsets.ISO_8859_1).contains("Lama Ole"))
        assertFalse(String(bytes, Charsets.ISO_8859_1).contains("WEBVTT"))
        // Relative paths (not the absolute temp path) must not reveal id or language.
        val relative = files.single().relativeTo(root).path
        assertFalse(relative.contains("dl-secret"))
        assertFalse(relative.contains("de-lang"))
        assertTrue(bytes.size > vtt.size)
    }

    @Test
    fun sameInputEncryptsDifferentlyEachTime() {
        store.put("dl-1", "de", vtt)
        val file = root.walkTopDown().first { it.isFile }
        val first = file.readBytes()
        store.put("dl-1", "de", vtt)
        assertFalse(first.contentEquals(file.readBytes()))
    }

    @Test
    fun corruptFileReadsAsNull() {
        store.put("dl-1", "de", vtt)
        val file = root.walkTopDown().first { it.isFile }
        val bytes = file.readBytes()
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 1).toByte()
        file.writeBytes(bytes)
        assertNull(store.read("dl-1", "de"))
        file.writeBytes(ByteArray(3))
        assertNull(store.read("dl-1", "de"))
    }

    @Test
    fun wrongKeyReadsAsNull() {
        store.put("dl-1", "de", vtt)
        val other = EncryptedSubtitleStore(root, JceSubtitleCipher())
        assertNull(other.read("dl-1", "de"))
    }

    @Test
    fun fileCannotBeMovedToAnotherDownloadOrName() {
        store.put("dl-1", "de", vtt)
        val file = root.walkTopDown().first { it.isFile }
        store.put("dl-2", "en", "x".toByteArray())
        val target = root.walkTopDown().first { it.isFile && it != file }
        file.copyTo(target, overwrite = true)
        assertNull(store.read("dl-2", "en"))
    }

    @Test
    fun missingReadsAsNull() {
        assertNull(store.read("never", "de"))
    }

    @Test
    fun deleteRemovesOneNameDeleteAllRemovesDownload() {
        store.put("dl-1", "de", vtt)
        store.put("dl-1", "en", vtt)
        store.put("dl-2", "de", vtt)
        store.delete("dl-1", "de")
        assertNull(store.read("dl-1", "de"))
        assertArrayEquals(vtt, store.read("dl-1", "en"))
        store.deleteAll("dl-1")
        assertNull(store.read("dl-1", "en"))
        assertArrayEquals(vtt, store.read("dl-2", "de"))
        store.deleteAll("unknown")
    }

    @Test
    fun jceCipherRoundTripAndTagCheck() {
        val cipher = JceSubtitleCipher()
        val blob = cipher.encrypt(vtt, byteArrayOf(1))
        assertArrayEquals(vtt, cipher.decrypt(blob, byteArrayOf(1)))
        assertNull(cipher.decrypt(blob, byteArrayOf(2)))
    }
}
