package org.dwbn.drmkit

import androidx.media3.common.DrmInitData
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import java.util.HashMap
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@UnstableApi
class WidevineSession @JvmOverloads constructor(
    private val config: Config,
    private val client: WidevineLicenseClient = WidevineLicenseClient(config),
    private val scheduler: TaskScheduler = NativeTaskScheduler(),
    private val onError: ErrorListener,
    private val licenseSink: ((ByteArray) -> Unit)? = null,
) {
    /**
     * Host-built playback endpoints and credentials.
     *
     * [tokenUrl], [licenseUrl], and [heartbeatUrl] must be absolute; drm-kit does not invent
     * `/api/v2`. [authorization] returns the current SSO access token and is read on every
     * request, so a host refresh reaches long sessions (drm-kit does not refresh it itself).
     */
    data class Config(
        val tokenUrl: String,
        val licenseUrl: String,
        val heartbeatUrl: String,
        val playbackSessionId: String,
        val renewalCredential: String,
        val authorization: () -> String,
        val streamLimit: StreamLimit,
    )

    fun interface ErrorListener {
        fun onError(error: DrmPlaybackError)
    }

    fun interface TaskScheduler {
        fun scheduleAtFixedRate(
            initialDelaySeconds: Long,
            periodSeconds: Long,
            command: Runnable,
        ): ScheduledFuture<*>
        fun shutdown() {}
    }

    class NativeTaskScheduler(
        private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "drm-kit-widevine").apply { isDaemon = true }
        },
    ) : TaskScheduler {
        override fun scheduleAtFixedRate(
            initialDelaySeconds: Long,
            periodSeconds: Long,
            command: Runnable,
        ): ScheduledFuture<*> =
            executor.scheduleAtFixedRate(command, initialDelaySeconds, periodSeconds, TimeUnit.SECONDS)

        override fun shutdown() {
            executor.shutdownNow()
        }
    }

    private class TrackedCdmSession(
        val drm: ExoMediaDrm,
        val sessionId: ByteArray,
        val challenge: AtomicReference<ByteArray?> = AtomicReference(null),
    )

    private inner class TrackingExoMediaDrm(
        private val delegate: ExoMediaDrm,
    ) : ExoMediaDrm by delegate {
        private var hostListener: ExoMediaDrm.OnEventListener? = null

        init {
            installEventListener(null)
        }

        override fun openSession(): ByteArray {
            val id = delegate.openSession()
            trackedSessions.add(TrackedCdmSession(delegate, id))
            return id
        }

        override fun closeSession(sessionId: ByteArray) {
            trackedSessions.removeAll { it.sessionId.contentEquals(sessionId) }
            delegate.closeSession(sessionId)
        }

        override fun getKeyRequest(
            scope: ByteArray,
            schemeDatas: MutableList<DrmInitData.SchemeData>?,
            keyType: Int,
            optionalParameters: HashMap<String, String>?,
        ): ExoMediaDrm.KeyRequest {
            val request = delegate.getKeyRequest(scope, schemeDatas, keyType, optionalParameters)
            val match = trackedSessions.firstOrNull { it.sessionId.contentEquals(scope) }
            match?.challenge?.set(request.data)
            rememberChallenge(request.data)
            return request
        }

        override fun setOnEventListener(listener: ExoMediaDrm.OnEventListener?) {
            installEventListener(listener)
        }

        override fun release() {
            trackedSessions.removeAll { it.drm === delegate }
            delegate.release()
        }

        private fun installEventListener(listener: ExoMediaDrm.OnEventListener?) {
            hostListener = listener
            delegate.setOnEventListener { mediaDrm, sessionId, event, extra, data ->
                if (event == ExoMediaDrm.EVENT_KEY_EXPIRED) {
                    renewOnTimer()
                }
                hostListener?.onEvent(mediaDrm, sessionId, event, extra, data)
            }
        }
    }

    private val callback = WidevineMediaDrmCallback(this, client)
    private val released = AtomicBoolean(false)
    private val terminalError = AtomicReference<DrmPlaybackError?>(null)
    private val lastChallenge = AtomicReference<ByteArray?>(null)
    private val lastKeyId = AtomicReference<ByteArray?>(null)
    private val trackedSessions = CopyOnWriteArrayList<TrackedCdmSession>()
    private val renewing = AtomicBoolean(false)
    private val scheduled = mutableListOf<ScheduledFuture<*>>()

    val licenseUrl: String get() = config.licenseUrl

    fun createMediaDrmCallback(): MediaDrmCallback = callback

    /**
     * Wraps [FrameworkMediaDrm] so timer / KEY_EXPIRED renewal can [ExoMediaDrm.provideKeyResponse]
     * on the open CDM session. The host must pass this to [androidx.media3.exoplayer.drm.DefaultDrmSessionManager.Builder].
     */
    fun createMediaDrmProvider(): ExoMediaDrm.Provider = ExoMediaDrm.Provider { uuid: UUID ->
        TrackingExoMediaDrm(FrameworkMediaDrm.DEFAULT_PROVIDER.acquireExoMediaDrm(uuid))
    }

    /**
     * Starts stream-limit timers. The host must call this when playback starts.
     * [StreamLimit.MODE_NONE] schedules nothing; CDM license requests still fetch a token.
     */
    fun start() {
        if (released.get()) return
        synchronized(scheduled) {
            if (scheduled.isNotEmpty()) return
            when (config.streamLimit.mode) {
                StreamLimit.MODE_NONE -> Unit
                StreamLimit.MODE_AXINOM_CSL, StreamLimit.MODE_LONG_LICENSE -> {
                    val period = config.streamLimit.renewalIntervalSeconds.toLong()
                    if (period > 0) {
                        scheduled += scheduler.scheduleAtFixedRate(
                            firstRenewalDelaySeconds(period),
                            period,
                            Runnable { renewOnTimer() },
                        )
                    }
                }
                StreamLimit.MODE_APP_HEARTBEAT -> {
                    val period = config.streamLimit.heartbeatIntervalSeconds.toLong()
                    if (period > 0) {
                        scheduled += scheduler.scheduleAtFixedRate(period, period, Runnable { heartbeatOnTimer() })
                    }
                }
                else -> report(DrmPlaybackError.unknown)
            }
        }
    }

    fun release() {
        if (!released.compareAndSet(false, true)) {
            return
        }
        synchronized(scheduled) {
            scheduled.forEach { it.cancel(false) }
            scheduled.clear()
        }
        trackedSessions.clear()
        scheduler.shutdown()
    }

    internal fun rememberChallenge(challenge: ByteArray) {
        lastChallenge.set(challenge)
    }

    /**
     * Content KID for `/drm-token`: parsed from [challenge] when it carries one (initial license
     * request), otherwise the KID remembered from an earlier request. Widevine renewal challenges
     * only reference the existing license, so they never contain the PSSH / KID.
     */
    internal fun contentKeyId(challenge: ByteArray): ByteArray? {
        val parsed = WidevineKeyIds.firstKeyId(challenge)
        if (parsed != null) {
            lastKeyId.set(parsed)
            return parsed
        }
        return lastKeyId.get()
    }

    internal fun throwIfBlocked() {
        val terminal = terminalError.get()
        if (terminal != null) {
            throw drmCallbackException(config.licenseUrl, DrmKitException(terminal))
        }
        if (released.get()) {
            onError.onError(DrmPlaybackError.unknown)
            throw drmCallbackException(config.licenseUrl, DrmKitException(DrmPlaybackError.unknown))
        }
    }

    internal fun report(error: DrmPlaybackError) {
        if (released.get()) return
        if (error.isTerminal) {
            if (terminalError.compareAndSet(null, error)) {
                try {
                    onError.onError(error)
                } finally {
                    release()
                }
            }
            return
        }
        onError.onError(error)
    }

    private fun renewOnTimer() {
        if (released.get()) return
        if (!renewing.compareAndSet(false, true)) return
        try {
            val sessions = trackedSessions.toList()
            if (sessions.isNotEmpty()) {
                for (session in sessions) {
                    val challenge = session.challenge.get() ?: lastChallenge.get() ?: continue
                    renewOne(challenge, session)
                }
                return
            }
            val challenge = lastChallenge.get() ?: return
            renewOne(challenge, null)
        } finally {
            renewing.set(false)
        }
    }

    private fun renewOne(challenge: ByteArray, session: TrackedCdmSession?) {
        if (released.get()) return
        val kid = contentKeyId(challenge) ?: return
        try {
            val token = client.fetchToken(DrmIdentifiers.toHex(kid))
            val license = client.acquireLicense(challenge, token)
            licenseSink?.invoke(license)
            if (session != null) {
                session.drm.provideKeyResponse(session.sessionId, license)
            }
        } catch (e: DrmKitException) {
            report(e.error)
        } catch (_: Exception) {
            report(DrmPlaybackError.unknown)
        }
    }

    private fun heartbeatOnTimer() {
        if (released.get()) return
        try {
            client.heartbeat()
        } catch (e: DrmKitException) {
            report(e.error)
        } catch (_: Exception) {
            report(DrmPlaybackError.unknown)
        }
    }

    companion object {
        /**
         * First CSL / long-license renew before the Axinom TTL so CDM keys stay alive.
         * Period 300s → 210s; never later than [periodSeconds], never below 1s.
         */
        internal fun firstRenewalDelaySeconds(periodSeconds: Long): Long {
            if (periodSeconds <= 1L) {
                return periodSeconds.coerceAtLeast(1L)
            }
            return ((periodSeconds * 7L) / 10L).coerceAtLeast(1L)
        }
    }
}

private val DrmPlaybackError.isTerminal: Boolean
    get() = this == DrmPlaybackError.blockedByStreamLimit ||
        this == DrmPlaybackError.notEntitled ||
        this == DrmPlaybackError.expired
