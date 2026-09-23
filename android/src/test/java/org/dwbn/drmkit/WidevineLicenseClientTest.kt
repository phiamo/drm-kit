package org.dwbn.drmkit

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class WidevineLicenseClientTest {
    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun fetchTokenReturnsJsonToken() {
        server.enqueue(
            MockResponse().setBody("""{"token":"abc","expiresAt":"t","renewalIntervalSeconds":7}"""),
        )
        val token = client().fetchToken("00112233445566778899aabbccddeeff")
        assertEquals("abc", token)
        val recorded = server.takeRequest()
        assertEquals("stream", recorded.requestUrl!!.queryParameter("purpose"))
        assertEquals("00112233445566778899aabbccddeeff", recorded.requestUrl!!.queryParameter("kid"))
    }

    @Test
    fun acquireLicenseReturnsRawBytes() {
        val payload = byteArrayOf(0x00, 0x7f, 0xff.toByte())
        server.enqueue(MockResponse().setBody(okio.Buffer().write(payload)))
        val got = client().acquireLicense(byteArrayOf(0x12), "tok")
        assertArrayEquals(payload, got)
        val recorded = server.takeRequest()
        assertEquals("tok", recorded.getHeader("X-AxDRM-Message"))
        assertEquals(null, recorded.getHeader("Authorization"))
    }

    @Test
    fun heartbeat409IsBlocked() {
        server.enqueue(MockResponse().setResponseCode(409))
        try {
            client().heartbeat()
            fail("expected DrmKitException")
        } catch (e: DrmKitException) {
            assertEquals(DrmPlaybackError.blockedByStreamLimit, e.error)
        }
    }

    private fun client(): WidevineLicenseClient {
        val config = WidevineSession.Config(
            tokenUrl = server.url("/drm-token").toString(),
            licenseUrl = server.url("/AcquireLicense").toString(),
            heartbeatUrl = server.url("/heartbeat").toString(),
            playbackSessionId = "sess-1",
            renewalCredential = "cred",
            authorization = "tok",
            streamLimit = StreamLimit(StreamLimit.MODE_NONE, 0, 0),
        )
        return WidevineLicenseClient(config)
    }
}
