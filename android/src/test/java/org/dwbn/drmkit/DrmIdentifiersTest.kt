package org.dwbn.drmkit

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class DrmIdentifiersTest {
    @Test
    fun encodingsMatchCommittedVector() {
        val vector = loadVector()
        val encodings = vector.getJSONObject("encodings")

        val kidHex = vector.getString("kidHex")
        val ivHex = vector.getString("ivHex")
        val keyHex = vector.getString("keyHex")
        val kidBytes = DrmIdentifiers.hexToBytes(kidHex)
        val ivBytes = DrmIdentifiers.hexToBytes(ivHex)
        val keyBytes = DrmIdentifiers.hexToBytes(keyHex)
        val packageUuidBytes = DrmIdentifiers.uuidToBytes(vector.getString("packageUuid"))

        assertNotEquals(kidHex, keyHex)
        assertNotEquals(ivHex, keyHex)

        assertEquals(encodings.getString("shakaKidHex"), DrmIdentifiers.toHex(kidBytes))
        assertEquals(encodings.getString("shakaIvHex"), DrmIdentifiers.toHex(ivBytes))
        assertEquals(encodings.getString("shakaKeyHex"), DrmIdentifiers.toHex(keyBytes))
        assertEquals(
            encodings.getString("fairPlayUri"),
            DrmIdentifiers.fairPlayUri(kidHex, ivHex),
        )
        assertEquals(encodings.getString("axinomKeyId"), DrmIdentifiers.axinomKeyId(kidBytes))
        assertEquals(encodings.getString("axinomKeyValue"), DrmIdentifiers.axinomKeyValue(keyBytes))

        val commKey = DrmIdentifiers.communicationKeyBytes("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        val encrypted = DrmIdentifiers.encryptContentKeyForAxinom(keyBytes, commKey, kidBytes)
        assertEquals(16, encrypted.size)
        assertArrayEquals(keyBytes, decryptAes128CbcNoPadding(encrypted, commKey, kidBytes))

        assertEquals(
            vector.getString("adHex"),
            DrmIdentifiers.toHex(DrmIdentifiers.additionalData(kidBytes, packageUuidBytes)),
        )

        val commKey32 = DrmIdentifiers.communicationKeyBytes(
            Base64.getEncoder().encodeToString(ByteArray(32) { 0x02 }),
        )
        assertEquals(32, commKey32.size)
        val encrypted128 = DrmIdentifiers.encryptContentKeyForAxinom(keyBytes, commKey32, kidBytes)
        assertEquals(16, encrypted128.size)
        assertArrayEquals(
            keyBytes,
            decryptAes128CbcNoPadding(encrypted128, commKey32.copyOfRange(0, 16), kidBytes),
        )

        val fairPlayUri = encodings.getString("fairPlayUri")
        assertTrue(fairPlayUri.startsWith("skd://"))
        assertFalse(fairPlayUri.contains("skd://" + Base64.getEncoder().encodeToString(kidBytes)))
        assertEquals("00112233-4455-6677-8899-aabbccddeeff", encodings.getString("axinomKeyId"))
        assertNotEquals("33221100-5544-7766-8899-aabbccddeeff", encodings.getString("axinomKeyId"))
    }

    @Test
    fun hexAndUriAreLowercase() {
        val vector = loadVector()
        val encodings = vector.getJSONObject("encodings")
        val upperKid = vector.getString("kidHex").uppercase()
        val upperIv = vector.getString("ivHex").uppercase()
        assertEquals(
            encodings.getString("shakaKidHex"),
            DrmIdentifiers.toHex(DrmIdentifiers.hexToBytes(upperKid)),
        )
        assertEquals(
            encodings.getString("fairPlayUri"),
            DrmIdentifiers.fairPlayUri(upperKid, upperIv),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun badHexThrows() {
        DrmIdentifiers.hexToBytes("not-hex")
    }

    @Test(expected = IllegalArgumentException::class)
    fun shortHexThrows() {
        DrmIdentifiers.hexToBytes("00112233")
    }

    @Test(expected = IllegalArgumentException::class)
    fun emptyHexThrows() {
        DrmIdentifiers.hexToBytes("")
    }

    @Test(expected = IllegalArgumentException::class)
    fun extraLongHexThrows() {
        DrmIdentifiers.hexToBytes("00112233445566778899aabbccddeeff00")
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidCommunicationKeyThrows() {
        DrmIdentifiers.communicationKeyBytes("not-a-key")
    }

    private fun decryptAes128CbcNoPadding(
        ciphertext: ByteArray,
        key: ByteArray,
        iv: ByteArray,
    ): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        return cipher.doFinal(ciphertext)
    }

    private fun loadVector(): JSONObject {
        val stream = javaClass.getResourceAsStream("/identifiers-test-vector.json")
            ?: error("missing identifiers-test-vector.json")
        return JSONObject(stream.bufferedReader().use { it.readText() })
    }
}
