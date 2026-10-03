package org.dwbn.drmkit

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.DrmSessionManager
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import java.io.File
import java.util.concurrent.TimeUnit

/** Outcome of an offline licence operation: success, or the typed [error]. */
class OfflineLicenseResult private constructor(val error: DrmPlaybackError?) {
    val isSuccess: Boolean get() = error == null

    companion object {
        @JvmStatic fun success() = OfflineLicenseResult(null)

        @JvmStatic fun failure(error: DrmPlaybackError) = OfflineLicenseResult(error)
    }
}

/**
 * Offline Widevine licences (persisted `keySetId` per download) for the host's download manager.
 *
 * All methods block (network, CDM): call them from a background thread. One instance serves all
 * downloads; the token and licence URLs are given per download in [acquire] and persisted.
 * Never logs tokens, challenges, licences or subtitle contents.
 */
@UnstableApi
class OfflineLicenseManager internal constructor(
    private val config: OfflineLicenseConfig,
    private val store: OfflineLicenseStore,
    /** Encrypted subtitles of the downloads; deleted together with their licence. */
    val subtitles: EncryptedSubtitleStore,
    private val engineFactory: OfflineLicenseEngineFactory,
    private val client: WidevineOfflineLicenseClient,
    private val clock: () -> Long,
) {
    /**
     * Acquires an offline licence for the audio [format] of [downloadId] (its `drmInitData` must
     * hold the Widevine PSSH) and stores the `keySetId`. Existing state is untouched on failure.
     */
    @Synchronized
    fun acquire(downloadId: String, format: Format, endpoints: OfflineEndpoints): OfflineLicenseResult {
        val kidHex = widevineKidHex(format) ?: return OfflineLicenseResult.failure(DrmPlaybackError.unknown)
        val previous = store.get(downloadId)
        val callback = OfflineMediaDrmCallback(client, endpoints, kidHex)
        val keySetId = try {
            withEngine(callback) { it.downloadLicense(format) }
        } catch (e: Exception) {
            return OfflineLicenseResult.failure(errorOf(callback, e))
        }
        store.put(
            OfflineLicenseRecord(downloadId, OfflineLicenseState.ACTIVE, keySetId, kidHex, endpoints, clock()),
        )
        previous?.keySetId?.takeIf { !it.contentEquals(keySetId) }?.let { bestEffortRelease(callback, it) }
        return OfflineLicenseResult.success()
    }

    /** True when the licence is expired, or has [RENEWAL_THRESHOLD_SECONDS] or less left. */
    @Synchronized
    fun needsRenewal(downloadId: String): Boolean {
        val record = store.get(downloadId) ?: return false
        val keySetId = record.keySetId
        if (record.state != OfflineLicenseState.ACTIVE || keySetId == null) return true
        return try {
            withEngine(NoNetworkMediaDrmCallback()) { it.remainingSeconds(keySetId) } <= RENEWAL_THRESHOLD_SECONDS
        } catch (_: Exception) {
            true
        }
    }

    /**
     * Fetches a fresh offline token and renews the licence; the new `keySetId` replaces the stored
     * one. A refused token (403, incl. device limit) expires the download and deletes its licence
     * and subtitles. A lapsed SSO token (`expired`), network or other failures leave all state
     * unchanged so the host can refresh and retry.
     */
    @Synchronized
    fun renew(downloadId: String): OfflineLicenseResult {
        val record = store.get(downloadId) ?: return OfflineLicenseResult.failure(DrmPlaybackError.unknown)
        val oldKeySetId = record.keySetId
        if (record.state != OfflineLicenseState.ACTIVE || oldKeySetId == null) {
            return OfflineLicenseResult.failure(DrmPlaybackError.expired)
        }
        val callback = OfflineMediaDrmCallback(client, record.endpoints, record.kidHex)
        val newKeySetId = try {
            withEngine(callback) { it.renewLicense(oldKeySetId) }
        } catch (e: Exception) {
            val error = errorOf(callback, e)
            if (callback.tokenRefused) expire(record)
            return OfflineLicenseResult.failure(error)
        }
        store.put(
            OfflineLicenseRecord(downloadId, OfflineLicenseState.ACTIVE, newKeySetId, record.kidHex, record.endpoints, clock()),
        )
        if (!newKeySetId.contentEquals(oldKeySetId)) bestEffortRelease(callback, oldKeySetId)
        return OfflineLicenseResult.success()
    }

    /**
     * Forgets [downloadId]: releases the CDM licence (best effort, may fail offline) and always
     * deletes the stored `keySetId` and the subtitles.
     */
    @Synchronized
    fun release(downloadId: String) {
        val record = store.get(downloadId)
        record?.keySetId?.let { bestEffortRelease(OfflineMediaDrmCallback(client, record.endpoints, record.kidHex), it) }
        store.delete(downloadId)
        subtitles.deleteAll(downloadId)
    }

    @Synchronized
    fun state(downloadId: String): OfflineLicenseState = store.get(downloadId)?.state ?: OfflineLicenseState.NONE

    /**
     * `MediaItem.DrmConfiguration` that plays [downloadId] from its stored `keySetId`, or null when
     * there is no active licence. Pair it with [createOfflineDrmSessionManager]. Check
     * [needsRenewal] / [state] first: an elapsed CDM licence fails at playback time.
     */
    @Synchronized
    fun offlineDrmConfiguration(downloadId: String): MediaItem.DrmConfiguration? {
        val keySetId = activeKeySetId(downloadId) ?: return null
        return MediaItem.DrmConfiguration.Builder(C.WIDEVINE_UUID).setKeySetId(keySetId).build()
    }

    /** `DrmSessionManager` for offline playback of [downloadId]; it never makes a network call. */
    @Synchronized
    fun createOfflineDrmSessionManager(downloadId: String): DrmSessionManager? {
        val keySetId = activeKeySetId(downloadId) ?: return null
        return DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
            .build(NoNetworkMediaDrmCallback())
            .also { it.setMode(DefaultDrmSessionManager.MODE_PLAYBACK, keySetId) }
    }

    private fun activeKeySetId(downloadId: String): ByteArray? {
        val record = store.get(downloadId) ?: return null
        return if (record.state == OfflineLicenseState.ACTIVE) record.keySetId else null
    }

    private fun expire(record: OfflineLicenseRecord) {
        store.put(
            OfflineLicenseRecord(
                record.downloadId, OfflineLicenseState.EXPIRED, null, record.kidHex, record.endpoints, record.savedAtMillis,
            ),
        )
        subtitles.deleteAll(record.downloadId)
    }

    private fun bestEffortRelease(callback: MediaDrmCallback, keySetId: ByteArray) {
        try {
            withEngine(callback) { it.releaseLicense(keySetId) }
        } catch (_: Exception) {
            // Best effort: the CDM entry lapses with the licence.
        }
    }

    private fun <T> withEngine(callback: MediaDrmCallback, block: (OfflineLicenseEngine) -> T): T {
        val engine = engineFactory.create(callback)
        try {
            return block(engine)
        } finally {
            engine.release()
        }
    }

    private fun errorOf(callback: OfflineMediaDrmCallback, e: Exception): DrmPlaybackError {
        callback.firstError?.let { return it }
        var cause: Throwable? = e
        while (cause != null) {
            if (cause is DrmKitException) return cause.error
            cause = cause.cause?.takeIf { it !== cause }
        }
        return DrmPlaybackError.unknown
    }

    companion object {
        /** Renewal is due when a day or less of the licence remains. */
        val RENEWAL_THRESHOLD_SECONDS: Long = TimeUnit.DAYS.toSeconds(1)

        /**
         * Production manager. State lives under `noBackupFilesDir` (excluded from backups); subtitle
         * keys live in Android Keystore.
         */
        @JvmStatic
        fun create(context: Context, config: OfflineLicenseConfig): OfflineLicenseManager {
            val root = File(context.noBackupFilesDir, "drm-kit")
            return OfflineLicenseManager(
                config = config,
                store = FileOfflineLicenseStore(File(root, "offline-licenses")),
                subtitles = EncryptedSubtitleStore(File(root, "subtitles")),
                engineFactory = Media3OfflineLicenseEngine.FACTORY,
                client = WidevineOfflineLicenseClient(config),
                clock = System::currentTimeMillis,
            )
        }

        /** Hex content KID from the Widevine PSSH in [format]`.drmInitData`, or null. */
        internal fun widevineKidHex(format: Format): String? {
            val initData = format.drmInitData ?: return null
            for (i in 0 until initData.schemeDataCount) {
                val scheme = initData.get(i)
                val data = scheme.data ?: continue
                if (!scheme.matches(C.WIDEVINE_UUID)) continue
                WidevineKeyIds.firstKeyId(data)?.let { return DrmIdentifiers.toHex(it) }
            }
            return null
        }
    }
}
