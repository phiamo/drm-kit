package org.dwbn.drmkit

import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.ExoMediaDrm
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.util.concurrent.Delayed
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@UnstableApi
class WidevineSessionTest {
    private lateinit var server: MockWebServer
    private val errors = mutableListOf<DrmPlaybackError>()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        errors.clear()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun licenseAndCdmRenewalFetchFreshTokenAndPostAxinomHeaderOnly() {
        enqueueToken("token-one")
        enqueueLicense("lic-one")
        enqueueToken("token-two")
        enqueueLicense("lic-two")

        val fixture = widevineKeyIdProtobuf(VECTOR_KID)
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0))
        val callback = session.createMediaDrmCallback()

        val first = callback.executeKeyRequest(C.WIDEVINE_UUID, keyRequest(fixture))
        assertArrayEquals("lic-one".toByteArray(), first.data)
        val second = callback.executeKeyRequest(C.WIDEVINE_UUID, keyRequest(fixture))
        assertArrayEquals("lic-two".toByteArray(), second.data)

        val token1 = server.takeRequest()
        assertTokenRequest(token1, VECTOR_KID)
        val license1 = server.takeRequest()
        assertLicenseRequest(license1, fixture, "token-one")
        val token2 = server.takeRequest()
        assertTokenRequest(token2, VECTOR_KID)
        val license2 = server.takeRequest()
        assertLicenseRequest(license2, fixture, "token-two")
        assertEquals(4, server.requestCount)
        assertTrue(errors.isEmpty())
    }

    @Test
    fun kidComesFromRequestProtobufNeverHardcoded() {
        enqueueToken("token-one")
        enqueueLicense("lic-one")
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0))
        session.createMediaDrmCallback().executeKeyRequest(
            C.WIDEVINE_UUID,
            keyRequest(widevineKeyIdProtobuf(VECTOR_KID)),
        )
        assertTokenRequest(server.takeRequest(), VECTOR_KID)
    }

    @Test
    fun kidParseFailureIsUnknownAndDoesNotHitNetwork() {
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0))
        try {
            session.createMediaDrmCallback().executeKeyRequest(
                C.WIDEVINE_UUID,
                keyRequest(byteArrayOf(0x01, 0x02, 0x03)),
            )
            fail("expected DRM callback failure")
        } catch (e: Exception) {
            assertEquals(DrmPlaybackError.unknown, errorFrom(e))
            assertFalse(e.message?.contains(VECTOR_KID) == true)
        }
        assertEquals(listOf(DrmPlaybackError.unknown), errors)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun noneModeHasNoTimersButStillFetchesToken() {
        enqueueToken("token-one")
        enqueueLicense("lic-one")
        val scheduler = FakeScheduler()
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0), scheduler)
        session.start()
        assertTrue(scheduler.periods.isEmpty())
        session.createMediaDrmCallback().executeKeyRequest(
            C.WIDEVINE_UUID,
            keyRequest(widevineKeyIdProtobuf(VECTOR_KID)),
        )
        assertEquals(2, server.requestCount)
        scheduler.runPending()
        assertEquals(2, server.requestCount)
        session.release()
    }

    @Test
    fun axinomCslRenewsAtConfiguredIntervalNotHardcoded300() {
        enqueueToken("token-one")
        enqueueLicense("lic-one")
        enqueueToken("token-renew")
        enqueueLicense("lic-renew")
        val scheduler = FakeScheduler()
        val fixture = widevineKeyIdProtobuf(VECTOR_KID)
        val session = session(StreamLimit(StreamLimit.MODE_AXINOM_CSL, 7, 0), scheduler)
        session.start()
        assertEquals(listOf(7L), scheduler.periods)
        session.createMediaDrmCallback().executeKeyRequest(C.WIDEVINE_UUID, keyRequest(fixture))
        server.takeRequest()
        server.takeRequest()
        scheduler.runPending()
        val tokenRenew = server.takeRequest()
        assertTokenRequest(tokenRenew, VECTOR_KID)
        assertLicenseRequest(server.takeRequest(), fixture, "token-renew")
        session.release()
    }

    @Test
    fun longLicenseRenewsAtConfiguredInterval() {
        val scheduler = FakeScheduler()
        session(StreamLimit(StreamLimit.MODE_LONG_LICENSE, 11, 0), scheduler).start()
        assertEquals(listOf(11L), scheduler.periods)
    }

    @Test
    fun appHeartbeatPostsEveryConfiguredIntervalAndMaps409() {
        server.enqueue(MockResponse().setResponseCode(204))
        server.enqueue(MockResponse().setResponseCode(409))
        val scheduler = FakeScheduler()
        val session = session(StreamLimit(StreamLimit.MODE_APP_HEARTBEAT, 0, 4), scheduler)
        session.start()
        assertEquals(listOf(4L), scheduler.periods)
        scheduler.runPending()
        val first = server.takeRequest()
        assertHeartbeat(first)
        scheduler.runPending()
        val blocked = server.takeRequest()
        assertHeartbeat(blocked)
        assertEquals(listOf(DrmPlaybackError.blockedByStreamLimit), errors)
        val before = server.requestCount
        scheduler.runPending()
        assertEquals(before, server.requestCount)
        session.release()
    }

    @Test
    fun heartbeat204Continues() {
        server.enqueue(MockResponse().setResponseCode(204))
        server.enqueue(MockResponse().setResponseCode(204))
        val scheduler = FakeScheduler()
        val session = session(StreamLimit(StreamLimit.MODE_APP_HEARTBEAT, 0, 2), scheduler)
        session.start()
        scheduler.runPending()
        scheduler.runPending()
        assertEquals(2, server.requestCount)
        assertTrue(errors.isEmpty())
        session.release()
    }

    @Test
    fun token409IsBlockedByStreamLimitAndNotRetried() {
        server.enqueue(MockResponse().setResponseCode(409))
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0))
        val callback = session.createMediaDrmCallback()
        try {
            callback.executeKeyRequest(C.WIDEVINE_UUID, keyRequest(widevineKeyIdProtobuf(VECTOR_KID)))
            fail("expected DRM callback failure")
        } catch (e: Exception) {
            assertEquals(DrmPlaybackError.blockedByStreamLimit, errorFrom(e))
        }
        assertEquals(1, server.requestCount)
        try {
            callback.executeKeyRequest(C.WIDEVINE_UUID, keyRequest(widevineKeyIdProtobuf(VECTOR_KID)))
            fail("expected DRM callback failure")
        } catch (e: Exception) {
            assertEquals(DrmPlaybackError.blockedByStreamLimit, errorFrom(e))
        }
        assertEquals(1, server.requestCount)
        assertEquals(listOf(DrmPlaybackError.blockedByStreamLimit), errors)
    }

    @Test
    fun acquireLicenseCslDenyIsBlockedAndNotRetried() {
        enqueueToken("token-one")
        server.enqueue(
            MockResponse()
                .setResponseCode(403)
                .setHeader("X-AxDrm-ErrorCode", "1")
                .setBody(""),
        )
        val session = session(StreamLimit(StreamLimit.MODE_AXINOM_CSL, 7, 0))
        val callback = session.createMediaDrmCallback()
        try {
            callback.executeKeyRequest(C.WIDEVINE_UUID, keyRequest(widevineKeyIdProtobuf(VECTOR_KID)))
            fail("expected DRM callback failure")
        } catch (e: Exception) {
            assertEquals(DrmPlaybackError.blockedByStreamLimit, errorFrom(e))
        }
        assertEquals(2, server.requestCount)
        try {
            callback.executeKeyRequest(C.WIDEVINE_UUID, keyRequest(widevineKeyIdProtobuf(VECTOR_KID)))
            fail("expected DRM callback failure")
        } catch (e: Exception) {
            assertEquals(DrmPlaybackError.blockedByStreamLimit, errorFrom(e))
        }
        assertEquals(2, server.requestCount)
        assertEquals(listOf(DrmPlaybackError.blockedByStreamLimit), errors)
    }

    @Test
    fun license403WithoutCslHeaderIsUnknown() {
        enqueueToken("token-one")
        server.enqueue(MockResponse().setResponseCode(403).setBody(""))
        expectError(DrmPlaybackError.unknown)
    }

    @Test
    fun token403IsNotEntitled() {
        server.enqueue(MockResponse().setResponseCode(403))
        expectError(DrmPlaybackError.notEntitled)
    }

    @Test
    fun token401IsExpired() {
        server.enqueue(MockResponse().setResponseCode(401))
        expectError(DrmPlaybackError.expired)
    }

    @Test
    fun ioFailureIsNetwork() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        expectError(DrmPlaybackError.network)
    }

    @Test
    fun token500IsUnknown() {
        server.enqueue(MockResponse().setResponseCode(500))
        expectError(DrmPlaybackError.unknown)
    }

    @Test
    fun heartbeat403IsNotEntitled() {
        server.enqueue(MockResponse().setResponseCode(403))
        val scheduler = FakeScheduler()
        session(StreamLimit(StreamLimit.MODE_APP_HEARTBEAT, 0, 1), scheduler).start()
        scheduler.runPending()
        assertEquals(listOf(DrmPlaybackError.notEntitled), errors)
    }

    @Test
    fun heartbeat401IsExpired() {
        server.enqueue(MockResponse().setResponseCode(401))
        val scheduler = FakeScheduler()
        session(StreamLimit(StreamLimit.MODE_APP_HEARTBEAT, 0, 1), scheduler).start()
        scheduler.runPending()
        assertEquals(listOf(DrmPlaybackError.expired), errors)
    }

    @Test
    fun errorsAndExceptionsDoNotContainTokenBytes() {
        val jwt = "eyJhbGciOiJIUzI1NiJ9.payload.signature"
        enqueueToken(jwt)
        enqueueLicense("secret-license-body")
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0))
        session.createMediaDrmCallback().executeKeyRequest(
            C.WIDEVINE_UUID,
            keyRequest(widevineKeyIdProtobuf(VECTOR_KID)),
        )
        errors.forEach { assertFalse(it.name.contains(jwt)) }
    }

    private fun expectError(expected: DrmPlaybackError) {
        val session = session(StreamLimit(StreamLimit.MODE_NONE, 300, 0))
        try {
            session.createMediaDrmCallback().executeKeyRequest(
                C.WIDEVINE_UUID,
                keyRequest(widevineKeyIdProtobuf(VECTOR_KID)),
            )
            fail("expected DRM callback failure")
        } catch (e: Exception) {
            assertEquals(expected, errorFrom(e))
            assertFalse(e.message?.contains("eyJ") == true)
        }
        assertEquals(listOf(expected), errors)
    }

    private fun session(
        streamLimit: StreamLimit,
        scheduler: FakeScheduler = FakeScheduler(),
    ): WidevineSession {
        val config = WidevineSession.Config(
            tokenUrl = server.url("/drm-token").toString(),
            licenseUrl = server.url("/AcquireLicense").toString(),
            heartbeatUrl = server.url("/playback-sessions/sess-1/heartbeat").toString(),
            playbackSessionId = "sess-1",
            renewalCredential = "renew-cred",
            authorization = "access-token",
            streamLimit = streamLimit,
        )
        return WidevineSession(
            config = config,
            client = WidevineLicenseClient(config),
            scheduler = scheduler,
            onError = { error -> errors += error },
        )
    }

    private fun enqueueToken(token: String) {
        server.enqueue(
            MockResponse().setBody(
                """{"token":"$token","expiresAt":"2026-01-01T00:00:00Z","renewalIntervalSeconds":7}""",
            ),
        )
    }

    private fun enqueueLicense(body: String) {
        server.enqueue(MockResponse().setBody(body))
    }

    private fun assertTokenRequest(request: RecordedRequest, kid: String) {
        assertEquals("GET", request.method)
        val url = request.requestUrl!!
        assertEquals("/drm-token", url.encodedPath)
        assertEquals(kid, url.queryParameter("kid"))
        assertEquals("sess-1", url.queryParameter("session"))
        assertEquals("stream", url.queryParameter("purpose"))
        assertEquals("Bearer access-token", request.getHeader("Authorization"))
        assertEquals("renew-cred", request.getHeader("X-Renewal-Credential"))
        assertNull(request.getHeader("X-AxDRM-Message"))
    }

    private fun assertLicenseRequest(request: RecordedRequest, challenge: ByteArray, token: String) {
        assertEquals("POST", request.method)
        assertEquals("/AcquireLicense", request.requestUrl!!.encodedPath)
        assertEquals(token, request.getHeader("X-AxDRM-Message"))
        assertNull(request.getHeader("Authorization"))
        assertNull(request.getHeader("X-Renewal-Credential"))
        assertArrayEquals(challenge, request.body.readByteArray())
    }

    private fun assertHeartbeat(request: RecordedRequest) {
        assertEquals("POST", request.method)
        assertEquals("/playback-sessions/sess-1/heartbeat", request.requestUrl!!.encodedPath)
        assertEquals("Bearer access-token", request.getHeader("Authorization"))
        assertEquals("renew-cred", request.getHeader("X-Renewal-Credential"))
        assertNull(request.getHeader("X-AxDRM-Message"))
    }

    companion object {
        const val VECTOR_KID = "00112233445566778899aabbccddeeff"

        fun widevineKeyIdProtobuf(kidHex: String): ByteArray {
            val kid = DrmIdentifiers.hexToBytes(kidHex)
            return byteArrayOf(0x12, 0x10) + kid
        }

        fun keyRequest(data: ByteArray): ExoMediaDrm.KeyRequest =
            ExoMediaDrm.KeyRequest(data, "")

        fun errorFrom(e: Throwable): DrmPlaybackError {
            var current: Throwable? = e
            while (current != null) {
                if (current is DrmKitException) return current.error
                current = current.cause
            }
            return DrmPlaybackError.unknown
        }
    }
}

internal class FakeScheduler : WidevineSession.TaskScheduler {
    val periods = mutableListOf<Long>()
    private val commands = mutableListOf<Runnable>()
    private val futures = mutableListOf<CancelHandle>()

    override fun scheduleAtFixedRate(periodSeconds: Long, command: Runnable): ScheduledFuture<*> {
        periods += periodSeconds
        commands += command
        val handle = CancelHandle()
        futures += handle
        return handle
    }

    fun runPending() {
        commands.indices.forEach { index ->
            if (!futures[index].isCancelled) {
                commands[index].run()
            }
        }
    }

    private class CancelHandle : ScheduledFuture<Unit> {
        private val cancelled = AtomicBoolean(false)
        override fun cancel(mayInterruptIfRunning: Boolean): Boolean = cancelled.compareAndSet(false, true)
        override fun isCancelled(): Boolean = cancelled.get()
        override fun isDone(): Boolean = cancelled.get()
        override fun get() = Unit
        override fun get(timeout: Long, unit: TimeUnit) = Unit
        override fun getDelay(unit: TimeUnit): Long = 0
        override fun compareTo(other: Delayed): Int = 0
    }
}
