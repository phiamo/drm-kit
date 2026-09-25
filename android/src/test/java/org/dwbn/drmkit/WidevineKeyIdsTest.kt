package org.dwbn.drmkit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WidevineKeyIdsTest {
    @Test
    fun rawSixteenBytesAreTheKid() {
        assertArrayEquals(CONTENT_KID, WidevineKeyIds.firstKeyId(CONTENT_KID.copyOf()))
    }

    @Test
    fun bareCencHeaderField2IsTheKid() {
        assertArrayEquals(CONTENT_KID, WidevineKeyIds.firstKeyId(cencKeyId(CONTENT_KID)))
    }

    @Test
    fun licenseRequestSkipsClientIdSixteenByteField2() {
        val request = licenseRequest(
            clientId = cencKeyId(DECOY_KID),
            contentId = cencKeyId(CONTENT_KID),
        )
        assertArrayEquals(CONTENT_KID, WidevineKeyIds.firstKeyId(request))
    }

    @Test
    fun licenseRequestReadsCencIdNestedUnderContentIdField1() {
        val request = licenseRequest(
            clientId = cencKeyId(DECOY_KID),
            contentId = lengthDelimited(1, cencKeyId(CONTENT_KID)),
        )
        assertArrayEquals(CONTENT_KID, WidevineKeyIds.firstKeyId(request))
    }

    @Test
    fun licenseRequestUsesPsshV1KidNotClientId() {
        val request = licenseRequest(
            clientId = cencKeyId(DECOY_KID),
            contentId = lengthDelimited(1, psshV1(CONTENT_KID)),
        )
        assertArrayEquals(CONTENT_KID, WidevineKeyIds.firstKeyId(request))
    }

    @Test
    fun licenseRequestUsesPsshV0HeaderKidNotClientId() {
        val request = licenseRequest(
            clientId = cencKeyId(DECOY_KID),
            contentId = lengthDelimited(1, psshV0(CONTENT_KID)),
        )
        assertArrayEquals(CONTENT_KID, WidevineKeyIds.firstKeyId(request))
    }

    @Test
    fun garbageIsUnknown() {
        assertNull(WidevineKeyIds.firstKeyId(byteArrayOf(0x01, 0x02, 0x03)))
    }

    companion object {
        val DECOY_KID = DrmIdentifiers.hexToBytes("382442e96f67dc390a6fcbe5034dae44")
        val CONTENT_KID = DrmIdentifiers.hexToBytes("7e6304b35235be83155ff16e9d18120c")
        private val WIDEVINE_SYSTEM_ID = DrmIdentifiers.hexToBytes("edef8ba979d64acea3c827dcd51d21ed")
        private val PSSH = byteArrayOf(0x70, 0x73, 0x73, 0x68)

        fun cencKeyId(kid: ByteArray): ByteArray = lengthDelimited(2, kid)

        fun licenseRequest(clientId: ByteArray, contentId: ByteArray): ByteArray =
            lengthDelimited(1, clientId) + lengthDelimited(2, contentId)

        fun lengthDelimited(field: Int, payload: ByteArray): ByteArray {
            val tag = (field shl 3) or 2
            return varint(tag) + varint(payload.size) + payload
        }

        fun psshV1(kid: ByteArray): ByteArray {
            val size = 32 + 4 + 16 + 4
            val buffer = ByteBuffer.allocate(size).order(ByteOrder.BIG_ENDIAN)
            buffer.putInt(size)
            buffer.put(PSSH)
            buffer.putInt(1 shl 24)
            buffer.put(WIDEVINE_SYSTEM_ID)
            buffer.putInt(1)
            buffer.put(kid)
            buffer.putInt(0)
            return buffer.array()
        }

        fun psshV0(kid: ByteArray): ByteArray {
            val header = cencKeyId(kid)
            val size = 32 + header.size
            val buffer = ByteBuffer.allocate(size).order(ByteOrder.BIG_ENDIAN)
            buffer.putInt(size)
            buffer.put(PSSH)
            buffer.putInt(0)
            buffer.put(WIDEVINE_SYSTEM_ID)
            buffer.putInt(header.size)
            buffer.put(header)
            return buffer.array()
        }

        fun varint(value: Int): ByteArray {
            var current = value
            val bytes = ArrayList<Byte>(2)
            while (current > 0x7f) {
                bytes += ((current and 0x7f) or 0x80).toByte()
                current = current ushr 7
            }
            bytes += current.toByte()
            return bytes.toByteArray()
        }
    }
}
