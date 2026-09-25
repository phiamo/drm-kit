package org.dwbn.drmkit

import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import androidx.media3.exoplayer.drm.MediaDrmCallbackException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

@UnstableApi
class WidevineMediaDrmCallback(
    private val session: WidevineSession,
    private val client: WidevineLicenseClient,
) : MediaDrmCallback {
    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest,
    ): MediaDrmCallback.Response {
        session.throwIfBlocked()
        val url = request.defaultUrl
        if (url.isNullOrEmpty()) {
            session.report(DrmPlaybackError.unknown)
            throw drmCallbackException("", DrmKitException(DrmPlaybackError.unknown))
        }
        return try {
            MediaDrmCallback.Response(client.provision(url, request.data))
        } catch (e: Exception) {
            val error = if (e is DrmKitException) e.error else DrmPlaybackError.unknown
            session.report(error)
            throw drmCallbackException(url, e)
        }
    }

    override fun executeKeyRequest(
        uuid: UUID,
        request: ExoMediaDrm.KeyRequest,
    ): MediaDrmCallback.Response {
        session.throwIfBlocked()
        val challenge = request.data
        val kid = WidevineKeyIds.firstKeyId(challenge)
        if (kid == null) {
            session.report(DrmPlaybackError.unknown)
            throw drmCallbackException(session.licenseUrl, DrmKitException(DrmPlaybackError.unknown))
        }
        return try {
            val token = client.fetchToken(DrmIdentifiers.toHex(kid))
            val license = client.acquireLicense(challenge, token)
            session.rememberChallenge(challenge)
            MediaDrmCallback.Response(license)
        } catch (e: Exception) {
            val error = if (e is DrmKitException) e.error else DrmPlaybackError.unknown
            session.report(error)
            throw drmCallbackException(session.licenseUrl, e)
        }
    }
}

internal fun drmCallbackException(url: String, cause: Throwable): Exception {
    try {
        val uri = Uri.parse(url)
        if (uri != null) {
            return MediaDrmCallbackException(
                DataSpec.Builder().setUri(uri).build(),
                uri,
                emptyMap(),
                0L,
                cause,
            )
        }
    } catch (_: Throwable) {
        // android.jar JVM stubs: Uri.parse is null / DataSpec cannot be built.
    }
    return if (cause is RuntimeException) cause else RuntimeException(cause)
}

/**
 * Content key ID for `/drm-token?kid=`.
 *
 * Same 32-hex as HLS `#EXT-X-KEY` / `content_key.kid`. A Widevine LicenseRequest
 * field 1 is ClientIdentification and often contains a 16-byte blob — that is not the KID.
 */
internal object WidevineKeyIds {
    private val PSSH = byteArrayOf(0x70, 0x73, 0x73, 0x68) // 'pssh'
    private val WIDEVINE_SYSTEM_ID = byteArrayOf(
        0xed.toByte(), 0xef.toByte(), 0x8b.toByte(), 0xa9.toByte(),
        0x79, 0xd6.toByte(), 0x4a, 0xce.toByte(),
        0xa3.toByte(), 0xc8.toByte(), 0x27, 0xdc.toByte(),
        0xd5.toByte(), 0x1d, 0x21, 0xed.toByte(),
    )

    fun firstKeyId(data: ByteArray): ByteArray? {
        if (data.size == 16) {
            return data.copyOf()
        }
        findWidevinePsshKeyId(data)?.let { return it }
        return fromContentProtobuf(data, 0, data.size)
    }

    private fun findWidevinePsshKeyId(data: ByteArray): ByteArray? {
        var i = 0
        while (i + 16 <= data.size) {
            if (regionEquals(data, i, WIDEVINE_SYSTEM_ID)) {
                val boxStart = i - 12
                if (boxStart >= 0) {
                    parsePssh(data, boxStart, data.size)?.let { return it }
                }
            }
            i++
        }
        i = 4
        while (i + 4 <= data.size) {
            if (regionEquals(data, i, PSSH)) {
                parsePssh(data, i - 4, data.size)?.let { return it }
            }
            i++
        }
        return null
    }

    /**
     * Prefer protobuf field 2 (ContentIdentification / CencId.key_id / WidevineCencHeader.key_id).
     * Do not walk field 1 unless it is a PSSH box — LicenseRequest field 1 is client_id.
     */
    private fun fromContentProtobuf(data: ByteArray, start: Int, end: Int): ByteArray? {
        var i = start
        var field1Start = -1
        var field1End = -1
        var field2Start = -1
        var field2End = -1
        while (i < end) {
            val tagResult = readVarint(data, i, end) ?: break
            i = tagResult.second
            val field = (tagResult.first ushr 3).toInt()
            when ((tagResult.first and 7).toInt()) {
                0 -> i = readVarint(data, i, end)?.second ?: break
                1 -> {
                    if (i + 8 > end) break
                    i += 8
                }
                2 -> {
                    val lenResult = readVarint(data, i, end) ?: break
                    i = lenResult.second
                    val length = lenResult.first.toInt()
                    if (length < 0 || i + length > end) break
                    if (field == 1 && field1Start < 0) {
                        field1Start = i
                        field1End = i + length
                    }
                    if (field == 2 && field2Start < 0) {
                        field2Start = i
                        field2End = i + length
                    }
                    i += length
                }
                5 -> {
                    if (i + 4 > end) break
                    i += 4
                }
                else -> break
            }
        }
        if (field2Start >= 0) {
            if (field2End - field2Start == 16) {
                return data.copyOfRange(field2Start, field2End)
            }
            parsePssh(data, field2Start, field2End)?.let { return it }
            return fromContentProtobuf(data, field2Start, field2End)
        }
        if (field1Start >= 0) {
            parsePssh(data, field1Start, field1End)?.let { return it }
            return fromContentProtobuf(data, field1Start, field1End)
        }
        return null
    }

    private fun parsePssh(data: ByteArray, start: Int, end: Int): ByteArray? {
        if (end - start < 32) return null
        if (!regionEquals(data, start + 4, PSSH)) {
            return null
        }
        val size = ByteBuffer.wrap(data, start, 4).order(ByteOrder.BIG_ENDIAN).int
        if (size <= 0 || start + size > end) return null
        val version = data[start + 8].toInt() and 0xff
        var offset = start + 28 // size + type + version/flags + systemId
        if (version > 0) {
            if (offset + 4 > start + size) return null
            val kidCount = ByteBuffer.wrap(data, offset, 4).order(ByteOrder.BIG_ENDIAN).int
            offset += 4
            if (kidCount > 0) {
                if (offset + 16 > start + size) return null
                return data.copyOfRange(offset, offset + 16)
            }
        }
        if (offset + 4 > start + size) return null
        val dataSize = ByteBuffer.wrap(data, offset, 4).order(ByteOrder.BIG_ENDIAN).int
        offset += 4
        if (dataSize < 0 || offset + dataSize > start + size) return null
        return fromContentProtobuf(data, offset, offset + dataSize)
    }

    private fun regionEquals(data: ByteArray, offset: Int, needle: ByteArray): Boolean {
        if (offset < 0 || offset + needle.size > data.size) return false
        for (index in needle.indices) {
            if (data[offset + index] != needle[index]) return false
        }
        return true
    }

    private fun readVarint(data: ByteArray, start: Int, end: Int): Pair<Long, Int>? {
        var result = 0L
        var shift = 0
        var i = start
        while (i < end) {
            val b = data[i].toInt() and 0xff
            i++
            result = result or ((b and 0x7f).toLong() shl shift)
            if (b and 0x80 == 0) {
                return result to i
            }
            shift += 7
            if (shift > 63) return null
        }
        return null
    }
}
