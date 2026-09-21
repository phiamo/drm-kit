package org.dwbn.drmkit

import java.util.Base64
import java.util.regex.Pattern
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object DrmIdentifiers {
    private val UUID_PATTERN: Pattern = Pattern.compile(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    @JvmStatic
    fun toHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    @JvmStatic
    fun hexToBytes(hex: String): ByteArray {
        val normalized = hex.lowercase()
        if (normalized.length != 32 || !normalized.all { it in '0'..'9' || it in 'a'..'f' }) {
            throw IllegalArgumentException("Expected 16-byte hex")
        }
        return ByteArray(16) { index ->
            normalized.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    @JvmStatic
    fun uuidToBytes(uuid: String): ByteArray = hexToBytes(uuid.replace("-", ""))

    @JvmStatic
    fun fairPlayUri(kidHex: String, ivHex: String): String =
        "skd://${kidHex.lowercase()}:${ivHex.lowercase()}"

    /**
     * RFC 4122 UUID from KID bytes (big-endian, lowercase, dashed). Not mixed-endian.
     */
    @JvmStatic
    fun axinomKeyId(kidBytes: ByteArray): String {
        val hex = toHex(kidBytes)
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }

    @JvmStatic
    fun axinomKeyValue(keyBytes: ByteArray): String =
        Base64.getEncoder().encodeToString(keyBytes)

    /**
     * AES-128-CBC without padding: first 16 bytes of the communication key, IV = KID bytes.
     */
    @JvmStatic
    fun encryptContentKeyForAxinom(
        contentKey: ByteArray,
        communicationKey: ByteArray,
        kidBytes: ByteArray,
    ): ByteArray {
        val aesKey = communicationKey.copyOfRange(0, minOf(16, communicationKey.size))
        if (contentKey.size != 16 || aesKey.size != 16 || kidBytes.size != 16) {
            throw IllegalArgumentException("Expected 16-byte AES inputs")
        }
        return cryptAes128Cbc(Cipher.ENCRYPT_MODE, contentKey, aesKey, kidBytes)
    }

    @JvmStatic
    fun communicationKeyBytes(value: String): ByteArray {
        val trimmed = value.trim()
        if (UUID_PATTERN.matcher(trimmed).matches()) {
            return uuidToBytes(trimmed)
        }
        val raw = trimmed.toByteArray(Charsets.ISO_8859_1)
        if (raw.size == 16) {
            return raw
        }
        val decoded = try {
            Base64.getDecoder().decode(trimmed)
        } catch (_: IllegalArgumentException) {
            null
        }
        if (decoded != null && (decoded.size == 16 || decoded.size == 32)) {
            return decoded
        }
        throw IllegalArgumentException("Invalid communication key")
    }

    @JvmStatic
    fun communicationKeyBytes(value: ByteArray): ByteArray {
        if (value.size != 16) {
            throw IllegalArgumentException("Invalid communication key")
        }
        return value
    }

    @JvmStatic
    fun additionalData(kidBytes: ByteArray, packageUuidBytes: ByteArray): ByteArray =
        kidBytes + packageUuidBytes

    internal fun decryptContentKeyForAxinom(
        encrypted: ByteArray,
        communicationKey: ByteArray,
        kidBytes: ByteArray,
    ): ByteArray {
        val aesKey = communicationKey.copyOfRange(0, minOf(16, communicationKey.size))
        if (encrypted.size != 16 || aesKey.size != 16 || kidBytes.size != 16) {
            throw IllegalArgumentException("Expected 16-byte AES inputs")
        }
        return cryptAes128Cbc(Cipher.DECRYPT_MODE, encrypted, aesKey, kidBytes)
    }

    private fun cryptAes128Cbc(
        mode: Int,
        data: ByteArray,
        aesKey: ByteArray,
        kidBytes: ByteArray,
    ): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        cipher.init(mode, SecretKeySpec(aesKey, "AES"), IvParameterSpec(kidBytes))
        return cipher.doFinal(data)
    }
}
