package org.dwbn.drmkit

import androidx.media3.common.util.UnstableApi
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

@UnstableApi
class WidevineOfflineLicenseClientTest {
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
    fun offlineTokenRequestHasPurposeSessionAndNoRenewalHeader() {
        server.enqueue(MockResponse().setBody("""{"token":"abc"}"""))
        assertEquals("abc", client().fetchToken(tokenUrl(), KID))
        val recorded = server.takeRequest()
        val url = recorded.requestUrl!!
        assertEquals("offline", url.queryParameter("purpose"))
        assertEquals("download:device-1", url.queryParameter("session"))
        assertEquals(KID, url.queryParameter("kid"))
        assertEquals("Bearer tok", recorded.getHeader("Authorization"))
        assertNull(recorded.getHeader("X-Renewal-Credential"))
    }

    @Test
    fun eachRequestReadsTheCurrentAccessToken() {
        var access = "first"
        server.enqueue(MockResponse().setBody("""{"token":"a"}"""))
        server.enqueue(MockResponse().setBody("""{"token":"b"}"""))
        val client = client { access }
        client.fetchToken(tokenUrl(), KID)
        access = "refreshed"
        client.fetchToken(tokenUrl(), KID)
        assertEquals("Bearer first", server.takeRequest().getHeader("Authorization"))
        assertEquals("Bearer refreshed", server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun token403WithDeviceLimitBodyIsOfflineDeviceLimit() {
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"offline_device_limit","message":"x"}"""))
        assertTokenError(DrmPlaybackError.offlineDeviceLimit)
    }

    @Test
    fun token403WithoutReasonIsNotEntitled() {
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"forbidden"}"""))
        assertTokenError(DrmPlaybackError.notEntitled)
    }

    @Test
    fun token403WithUnparseableBodyIsNotEntitled() {
        server.enqueue(MockResponse().setResponseCode(403).setBody("<html>"))
        assertTokenError(DrmPlaybackError.notEntitled)
    }

    @Test
    fun token401IsExpired() {
        server.enqueue(MockResponse().setResponseCode(401))
        assertTokenError(DrmPlaybackError.expired)
    }

    @Test
    fun token429IsRateLimited() {
        server.enqueue(MockResponse().setResponseCode(429).setBody("""{"detail":"Too many DRM token requests."}"""))
        assertTokenError(DrmPlaybackError.rateLimited)
    }

    @Test
    fun token500AndMissingTokenAreUnknown() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertTokenError(DrmPlaybackError.unknown)
        server.enqueue(MockResponse().setBody("""{"other":1}"""))
        assertTokenError(DrmPlaybackError.unknown)
    }

    @Test
    fun unreachableServerIsNetwork() {
        val url = tokenUrl()
        server.shutdown()
        try {
            client().fetchToken(url, KID)
            fail("expected DrmKitException")
        } catch (e: DrmKitException) {
            assertEquals(DrmPlaybackError.network, e.error)
        }
    }

    @Test
    fun acquireLicenseSendsChallengeAndAxinomMessage() {
        val payload = byteArrayOf(0x00, 0x7f, 0xff.toByte())
        server.enqueue(MockResponse().setBody(okio.Buffer().write(payload)))
        val got = client().acquireLicense(server.url("/AcquireLicense").toString(), byteArrayOf(0x12), "tok")
        assertArrayEquals(payload, got)
        val recorded = server.takeRequest()
        assertEquals("tok", recorded.getHeader("X-AxDRM-Message"))
        assertNull(recorded.getHeader("Authorization"))
    }

    @Test
    fun license403IsNotEntitledNeverStreamLimit() {
        server.enqueue(MockResponse().setResponseCode(403).addHeader("X-AxDrm-ErrorCode", "1"))
        try {
            client().acquireLicense(server.url("/AcquireLicense").toString(), byteArrayOf(1), "tok")
            fail("expected DrmKitException")
        } catch (e: DrmKitException) {
            assertEquals(DrmPlaybackError.notEntitled, e.error)
        }
    }

    @Test
    fun provisionPostsSignedRequestAndFailureIsUnknown() {
        server.enqueue(MockResponse().setBody("prov"))
        val got = client().provision(server.url("/provision").toString(), "signed".toByteArray())
        assertEquals("prov", String(got))
        assertEquals("signed", server.takeRequest().requestUrl!!.queryParameter("signedRequest"))
        server.enqueue(MockResponse().setResponseCode(500))
        try {
            client().provision(server.url("/provision").toString(), "signed".toByteArray())
            fail("expected DrmKitException")
        } catch (e: DrmKitException) {
            assertEquals(DrmPlaybackError.unknown, e.error)
        }
    }

    @Test
    fun invalidUrlIsUnknown() {
        try {
            client().fetchToken("not-a-url", KID)
            fail("expected DrmKitException")
        } catch (e: DrmKitException) {
            assertEquals(DrmPlaybackError.unknown, e.error)
        }
    }

    private fun assertTokenError(expected: DrmPlaybackError) {
        try {
            client().fetchToken(tokenUrl(), KID)
            fail("expected DrmKitException")
        } catch (e: DrmKitException) {
            assertEquals(expected, e.error)
        }
    }

    private fun tokenUrl() = server.url("/assets/a/drm-token").toString()

    private fun client(access: () -> String = { "tok" }) =
        WidevineOfflineLicenseClient(OfflineLicenseConfig("device-1", access))

    private companion object {
        const val KID = "00112233445566778899aabbccddeeff"
    }
}
