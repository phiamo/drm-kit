package org.dwbn.drmkit

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.DrmSessionEventListener
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import androidx.media3.exoplayer.drm.OfflineLicenseHelper
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import java.util.UUID

/** Seam over Media3's [OfflineLicenseHelper] (needs a real CDM, so it is faked in JVM tests). */
internal interface OfflineLicenseEngine {
    /** Returns the new `keySetId`. */
    fun downloadLicense(format: Format): ByteArray

    /** Returns the (possibly new) `keySetId`. */
    fun renewLicense(keySetId: ByteArray): ByteArray

    fun releaseLicense(keySetId: ByteArray)

    /** Remaining licence time in seconds (the smaller of licence and playback duration). */
    fun remainingSeconds(keySetId: ByteArray): Long

    fun release()
}

internal fun interface OfflineLicenseEngineFactory {
    fun create(callback: MediaDrmCallback): OfflineLicenseEngine
}

@UnstableApi
internal class Media3OfflineLicenseEngine(callback: MediaDrmCallback) : OfflineLicenseEngine {
    private val helper: OfflineLicenseHelper

    init {
        val manager = DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
            // No automatic retries: every retry would spend another offline token.
            .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(0))
            .build(callback)
        helper = OfflineLicenseHelper(manager, DrmSessionEventListener.EventDispatcher())
    }

    override fun downloadLicense(format: Format): ByteArray = helper.downloadLicense(format)

    override fun renewLicense(keySetId: ByteArray): ByteArray = helper.renewLicense(keySetId)

    override fun releaseLicense(keySetId: ByteArray) = helper.releaseLicense(keySetId)

    override fun remainingSeconds(keySetId: ByteArray): Long {
        val remaining = helper.getLicenseDurationRemainingSec(keySetId)
        return minOf(remaining.first, remaining.second)
    }

    override fun release() = helper.release()

    companion object {
        val FACTORY = OfflineLicenseEngineFactory { Media3OfflineLicenseEngine(it) }
    }
}

/**
 * Key and provisioning requests for the offline licence of one download. The content [kidHex] is
 * fixed: renewal and release challenges carry no PSSH. Remembers the first failure so the manager
 * can report a typed error whatever Media3 wraps around it.
 */
@UnstableApi
internal class OfflineMediaDrmCallback(
    private val client: WidevineOfflineLicenseClient,
    private val endpoints: OfflineEndpoints,
    private val kidHex: String,
) : MediaDrmCallback {
    @Volatile
    var firstError: DrmPlaybackError? = null
        private set

    /** True when the token endpoint refused (403): the grant is gone, not merely unreachable. */
    @Volatile
    var tokenRefused: Boolean = false
        private set

    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest,
    ): MediaDrmCallback.Response {
        val url = request.defaultUrl
        if (url.isNullOrEmpty()) {
            throw fail(DrmKitException(DrmPlaybackError.unknown), "")
        }
        return try {
            MediaDrmCallback.Response(client.provision(url, request.data))
        } catch (e: Exception) {
            throw fail(e, url)
        }
    }

    override fun executeKeyRequest(
        uuid: UUID,
        request: ExoMediaDrm.KeyRequest,
    ): MediaDrmCallback.Response {
        val token = try {
            client.fetchToken(endpoints.tokenUrl, kidHex)
        } catch (e: Exception) {
            val error = errorOf(e)
            if (error == DrmPlaybackError.notEntitled || error == DrmPlaybackError.offlineDeviceLimit) {
                tokenRefused = true
            }
            throw fail(e, endpoints.licenseUrl)
        }
        return try {
            MediaDrmCallback.Response(client.acquireLicense(endpoints.licenseUrl, request.data, token))
        } catch (e: Exception) {
            throw fail(e, endpoints.licenseUrl)
        }
    }

    private fun fail(cause: Exception, url: String): Exception {
        if (firstError == null) firstError = errorOf(cause)
        return drmCallbackException(url, cause)
    }

    private fun errorOf(e: Exception): DrmPlaybackError =
        if (e is DrmKitException) e.error else DrmPlaybackError.unknown
}

/** Playback by `keySetId` must never touch the network: any request is a hard failure. */
@UnstableApi
internal class NoNetworkMediaDrmCallback : MediaDrmCallback {
    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest,
    ): MediaDrmCallback.Response =
        throw drmCallbackException("", DrmKitException(DrmPlaybackError.network))

    override fun executeKeyRequest(
        uuid: UUID,
        request: ExoMediaDrm.KeyRequest,
    ): MediaDrmCallback.Response =
        throw drmCallbackException("", DrmKitException(DrmPlaybackError.network))
}
