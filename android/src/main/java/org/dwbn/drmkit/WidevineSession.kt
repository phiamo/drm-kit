package org.dwbn.drmkit

import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.MediaDrmCallback
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@UnstableApi
class WidevineSession(
    private val config: Config,
    private val client: WidevineLicenseClient = WidevineLicenseClient(config),
    private val scheduler: TaskScheduler = NativeTaskScheduler(),
    private val onError: ErrorListener,
) {
    /**
     * Host-built playback endpoints and credentials.
     *
     * [tokenUrl], [licenseUrl], and [heartbeatUrl] must be absolute; drm-kit does not invent
     * `/api/v2`. [authorization] is the current SSO access token (drm-kit does not refresh it).
     */
    data class Config(
        val tokenUrl: String,
        val licenseUrl: String,
        val heartbeatUrl: String,
        val playbackSessionId: String,
        val renewalCredential: String,
        val authorization: String,
        val streamLimit: StreamLimit,
    )

    fun interface ErrorListener {
        fun onError(error: DrmPlaybackError)
    }

    fun interface TaskScheduler {
        fun scheduleAtFixedRate(periodSeconds: Long, command: Runnable): ScheduledFuture<*>
        fun shutdown() {}
    }

    class NativeTaskScheduler(
        private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "drm-kit-widevine").apply { isDaemon = true }
        },
    ) : TaskScheduler {
        override fun scheduleAtFixedRate(periodSeconds: Long, command: Runnable): ScheduledFuture<*> =
            executor.scheduleAtFixedRate(command, periodSeconds, periodSeconds, TimeUnit.SECONDS)

        override fun shutdown() {
            executor.shutdownNow()
        }
    }

    private val callback = WidevineMediaDrmCallback(this, client)
    private val released = AtomicBoolean(false)
    private val terminalError = AtomicReference<DrmPlaybackError?>(null)
    private val lastChallenge = AtomicReference<ByteArray?>(null)
    private val scheduled = mutableListOf<ScheduledFuture<*>>()

    val licenseUrl: String get() = config.licenseUrl

    fun createMediaDrmCallback(): MediaDrmCallback = callback

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
                        scheduled += scheduler.scheduleAtFixedRate(period, Runnable { renewOnTimer() })
                    }
                }
                StreamLimit.MODE_APP_HEARTBEAT -> {
                    val period = config.streamLimit.heartbeatIntervalSeconds.toLong()
                    if (period > 0) {
                        scheduled += scheduler.scheduleAtFixedRate(period, Runnable { heartbeatOnTimer() })
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
        scheduler.shutdown()
    }

    internal fun rememberChallenge(challenge: ByteArray) {
        lastChallenge.set(challenge)
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
        val challenge = lastChallenge.get() ?: return
        val kid = WidevineKeyIds.firstKeyId(challenge) ?: return
        try {
            val token = client.fetchToken(DrmIdentifiers.toHex(kid))
            client.acquireLicense(challenge, token)
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
}

private val DrmPlaybackError.isTerminal: Boolean
    get() = this == DrmPlaybackError.blockedByStreamLimit ||
        this == DrmPlaybackError.notEntitled ||
        this == DrmPlaybackError.expired
