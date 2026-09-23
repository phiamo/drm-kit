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
        } catch (e: DrmKitException) {
            session.report(e.error)
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
        } catch (e: DrmKitException) {
            session.report(e.error)
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
 * First 16-byte Widevine `key_id` in KeyRequest bytes (PSSH protobuf or raw 16-byte fixture).
 */
internal object WidevineKeyIds {
    private val PSSH = byteArrayOf(0x70, 0x73, 0x73, 0x68) // 'pssh'

    fun firstKeyId(data: ByteArray): ByteArray? {
        if (data.size == 16) {
            return data.copyOf()
        }
        return findInProtobuf(data, 0, data.size) ?: parsePssh(data, 0, data.size)
    }

    private fun findInProtobuf(data: ByteArray, start: Int, end: Int): ByteArray? {
        var i = start
        while (i < end) {
            val tagResult = readVarint(data, i, end) ?: return null
            i = tagResult.second
            val field = (tagResult.first ushr 3).toInt()
            when ((tagResult.first and 7).toInt()) {
                0 -> i = readVarint(data, i, end)?.second ?: return null
                1 -> {
                    if (i + 8 > end) return null
                    i += 8
                }
                2 -> {
                    val lenResult = readVarint(data, i, end) ?: return null
                    i = lenResult.second
                    val length = lenResult.first.toInt()
                    if (length < 0 || i + length > end) return null
                    val payloadStart = i
                    val payloadEnd = i + length
                    if (field == 2 && length == 16) {
                        return data.copyOfRange(payloadStart, payloadEnd)
                    }
                    parsePssh(data, payloadStart, payloadEnd)?.let { return it }
                    findInProtobuf(data, payloadStart, payloadEnd)?.let { return it }
                    i = payloadEnd
                }
                5 -> {
                    if (i + 4 > end) return null
                    i += 4
                }
                else -> return null
            }
        }
        return null
    }

    private fun parsePssh(data: ByteArray, start: Int, end: Int): ByteArray? {
        if (end - start < 32) return null
        if (!(data[start + 4] == PSSH[0] && data[start + 5] == PSSH[1] &&
                data[start + 6] == PSSH[2] && data[start + 7] == PSSH[3])
        ) {
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
        return findInProtobuf(data, offset, offset + dataSize)
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
