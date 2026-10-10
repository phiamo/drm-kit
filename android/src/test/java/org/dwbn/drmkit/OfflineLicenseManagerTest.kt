package org.dwbn.drmkit

import androidx.media3.common.C
import androidx.media3.common.DrmInitData
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer

@UnstableApi
class OfflineLicenseManagerTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var storeDir: File
    private lateinit var engine: FakeEngine
    private var engineCreations = 0
    private var now = 1_000_000L

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val base = tmp.newFolder()
        storeDir = File(base, "licenses")
        engine = FakeEngine()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun acquireStoresKeySetIdAndActivates() {
        enqueueTokenAndLicense()
        val result = manager().acquire("dl-1", format(), endpoints())

        assertTrue(result.isSuccess)
        assertEquals(OfflineLicenseState.ACTIVE, manager().state("dl-1"))
        assertArrayEquals(KEY_SET_1, store().get("dl-1")!!.keySetId)
        assertEquals(KID_HEX, store().get("dl-1")!!.kidHex)
        assertEquals(now, store().get("dl-1")!!.savedAtMillis)
        val tokenRequest = server.takeRequest()
        assertEquals("offline", tokenRequest.requestUrl!!.queryParameter("purpose"))
        assertEquals("download:device-1", tokenRequest.requestUrl!!.queryParameter("session"))
        assertEquals(KID_HEX, tokenRequest.requestUrl!!.queryParameter("kid"))
        assertEquals("Bearer sso", tokenRequest.getHeader("Authorization"))
        assertNull(tokenRequest.getHeader("X-Renewal-Credential"))
        val licenseRequest = server.takeRequest()
        assertEquals("offline-token", licenseRequest.getHeader("X-AxDRM-Message"))
        assertArrayEquals(CHALLENGE, licenseRequest.body.readByteArray())
        assertEquals(1, engine.releasedEngines)
    }

    @Test
    fun recordSurvivesANewManagerInstance() {
        enqueueTokenAndLicense()
        manager().acquire("dl-1", format(), endpoints())
        val restarted = manager()
        assertEquals(OfflineLicenseState.ACTIVE, restarted.state("dl-1"))
        assertFalse(restarted.needsRenewal("dl-1"))
    }

    @Test
    fun acquireWithoutWidevinePsshIsUnknownAndStoresNothing() {
        val result = manager().acquire("dl-1", Format.Builder().build(), endpoints())
        assertEquals(DrmPlaybackError.unknown, result.error)
        assertEquals(OfflineLicenseState.NONE, manager().state("dl-1"))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun acquireRefusedStoresNothing() {
        server.enqueue(MockResponse().setResponseCode(403))
        val result = manager().acquire("dl-1", format(), endpoints())
        assertEquals(DrmPlaybackError.notEntitled, result.error)
        assertEquals(OfflineLicenseState.NONE, manager().state("dl-1"))
        assertEquals(1, server.requestCount)
    }

    @Test
    fun acquireDeviceLimitIsTyped() {
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"offline_device_limit"}"""))
        assertEquals(DrmPlaybackError.offlineDeviceLimit, manager().acquire("dl-1", format(), endpoints()).error)
    }

    @Test
    fun acquireWithLapsedBearerIsExpired() {
        server.enqueue(MockResponse().setResponseCode(401))
        assertEquals(DrmPlaybackError.expired, manager().acquire("dl-1", format(), endpoints()).error)
    }

    @Test
    fun acquireOfflineIsNetwork() {
        server.shutdown()
        assertEquals(DrmPlaybackError.network, manager().acquire("dl-1", format(), endpoints()).error)
        assertEquals(OfflineLicenseState.NONE, manager().state("dl-1"))
    }

    @Test
    fun acquireLicenseServerRefusalIsNotEntitled() {
        server.enqueue(MockResponse().setBody("""{"token":"offline-token"}"""))
        server.enqueue(MockResponse().setResponseCode(403).addHeader("X-AxDrm-ErrorCode", "1"))
        assertEquals(DrmPlaybackError.notEntitled, manager().acquire("dl-1", format(), endpoints()).error)
    }

    @Test
    fun firstFailureWinsOverWrappedLaterOnes() {
        server.enqueue(MockResponse().setResponseCode(403))
        engine.wrapAndRetryCallback = true
        // The fake retries the key request once after the first failure; the first error stays.
        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals(DrmPlaybackError.notEntitled, manager().acquire("dl-1", format(), endpoints()).error)
    }

    @Test
    fun engineFailureWithoutCallbackErrorIsUnknownAndWrappedDrmKitErrorIsFound() {
        engine.failWith = RuntimeException("cdm exploded")
        assertEquals(DrmPlaybackError.unknown, manager().acquire("dl-1", format(), endpoints()).error)
        engine.failWith = RuntimeException("wrapper", DrmKitException(DrmPlaybackError.network))
        assertEquals(DrmPlaybackError.network, manager().acquire("dl-1", format(), endpoints()).error)
    }

    @Test
    fun engineCreationFailureIsTyped() {
        val manager = manager(factory = { throw IllegalStateException("no mediadrm") })
        assertEquals(DrmPlaybackError.unknown, manager.acquire("dl-1", format(), endpoints()).error)
        assertEquals(OfflineLicenseState.NONE, manager.state("dl-1"))
    }

    @Test
    fun acquireProvisioningRunsThroughTheOfflineClient() {
        server.enqueue(MockResponse().setBody("provisioned"))
        server.enqueue(MockResponse().setBody("""{"token":"offline-token"}"""))
        server.enqueue(MockResponse().setBody(okio.Buffer().write(LICENSE)))
        engine.provisionFirst = server.url("/provision").toString()
        assertTrue(manager().acquire("dl-1", format(), endpoints()).isSuccess)
        assertEquals("provisioned", String(engine.provisionResponse!!))
        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun provisioningFailureIsReported() {
        server.enqueue(MockResponse().setResponseCode(500))
        engine.provisionFirst = server.url("/provision").toString()
        assertEquals(DrmPlaybackError.unknown, manager().acquire("dl-1", format(), endpoints()).error)
    }

    @Test
    fun needsRenewalFollowsRemainingTime() {
        enqueueTokenAndLicense()
        val manager = manager()
        manager.acquire("dl-1", format(), endpoints())

        engine.remaining = 26L * 24 * 3600
        assertFalse(manager.needsRenewal("dl-1"))
        engine.remaining = 24L * 3600 + 1
        assertFalse(manager.needsRenewal("dl-1"))
        engine.remaining = 24L * 3600
        assertTrue(manager.needsRenewal("dl-1"))
        engine.remaining = 0
        assertTrue(manager.needsRenewal("dl-1"))
        engine.failWith = RuntimeException("cdm")
        assertTrue(manager.needsRenewal("dl-1"))
        assertEquals(1, server.requestCount / 2)
    }

    @Test
    fun expiresAtFollowsRemainingTime() {
        enqueueTokenAndLicense()
        val manager = manager()
        manager.acquire("dl-1", format(), endpoints())

        engine.remaining = 300
        assertEquals(now + 300_000L, manager.expiresAt("dl-1"))
        engine.remaining = 0
        assertEquals(now, manager.expiresAt("dl-1"))
        engine.failWith = RuntimeException("cdm")
        assertNull(manager.expiresAt("dl-1"))
        assertNull(manager.expiresAt("nope"))
    }

    @Test
    fun unknownDownloadIsNoneAndNoOps() {
        val manager = manager()
        assertEquals(OfflineLicenseState.NONE, manager.state("nope"))
        assertFalse(manager.needsRenewal("nope"))
        assertNull(manager.expiresAt("nope"))
        assertEquals(DrmPlaybackError.unknown, manager.renew("nope").error)
        assertNull(manager.offlineDrmConfiguration("nope"))
        assertNull(manager.createOfflineDrmSessionManager("nope"))
        manager.release("nope")
        assertEquals(0, server.requestCount)
        assertEquals(0, engineCreations)
    }

    @Test
    fun acquireTwiceReleasesThePreviousKeySetId() {
        acquireActive()
        engine.nextKeySet = KEY_SET_2
        enqueueTokenAndLicense()

        assertTrue(manager().acquire("dl-1", format(), endpoints()).isSuccess)

        assertArrayEquals(KEY_SET_2, store().get("dl-1")!!.keySetId)
        assertEquals(listOf(KEY_SET_1.toList()), engine.releasedKeySets.map { it.toList() })
    }

    @Test
    fun acquireTwiceWithSameKeySetIdReleasesNothing() {
        acquireActive()
        enqueueTokenAndLicense()

        assertTrue(manager().acquire("dl-1", format(), endpoints()).isSuccess)

        assertArrayEquals(KEY_SET_1, store().get("dl-1")!!.keySetId)
        assertTrue(engine.releasedKeySets.isEmpty())
    }

    @Test
    fun renewReplacesKeySetIdAndReleasesTheOldOne() {
        acquireActive()
        engine.renewedKeySet = KEY_SET_2
        now += 5_000
        enqueueTokenAndLicense()

        assertTrue(manager().renew("dl-1").isSuccess)

        val record = store().get("dl-1")!!
        assertArrayEquals(KEY_SET_2, record.keySetId)
        assertEquals(OfflineLicenseState.ACTIVE, record.state)
        assertEquals(now, record.savedAtMillis)
        assertEquals(listOf(KEY_SET_1.toList()), engine.releasedKeySets.map { it.toList() })
        // Renewal reached the stored endpoints with a fresh offline token, no renewal credential.
        server.takeRequest(); server.takeRequest()
        val renewToken = server.takeRequest()
        assertEquals("offline", renewToken.requestUrl!!.queryParameter("purpose"))
        assertNull(renewToken.getHeader("X-Renewal-Credential"))
    }

    @Test
    fun renewWithSameKeySetIdDoesNotRelease() {
        acquireActive()
        engine.renewedKeySet = KEY_SET_1
        enqueueTokenAndLicense()
        assertTrue(manager().renew("dl-1").isSuccess)
        assertTrue(engine.releasedKeySets.isEmpty())
    }

    @Test
    fun renewUsesStoredEndpointsOfEachDownloadAfterRestart() {
        server.enqueue(MockResponse().setBody("""{"token":"t-a"}"""))
        server.enqueue(MockResponse().setBody(okio.Buffer().write(LICENSE)))
        manager().acquire("dl-a", format(), OfflineEndpoints(server.url("/assets/a/drm-token").toString(), server.url("/lic-a").toString()))
        engine.nextKeySet = KEY_SET_2
        server.enqueue(MockResponse().setBody("""{"token":"t-b"}"""))
        server.enqueue(MockResponse().setBody(okio.Buffer().write(LICENSE)))
        manager().acquire("dl-b", format(), OfflineEndpoints(server.url("/assets/b/drm-token").toString(), server.url("/lic-b").toString()))
        repeat(4) { server.takeRequest() }

        engine.renewedKeySet = KEY_SET_2
        server.enqueue(MockResponse().setBody("""{"token":"t-a2"}"""))
        server.enqueue(MockResponse().setBody(okio.Buffer().write(LICENSE)))
        assertTrue(manager().renew("dl-a").isSuccess)
        assertEquals("/assets/a/drm-token", server.takeRequest().requestUrl!!.encodedPath)
        assertEquals("/lic-a", server.takeRequest().requestUrl!!.encodedPath)
    }

    @Test
    fun renewRefusedExpiresAndDeletesLicence() {
        acquireActive()
        val manager = manager()
        server.enqueue(MockResponse().setResponseCode(403))

        assertEquals(DrmPlaybackError.notEntitled, manager.renew("dl-1").error)

        assertEquals(OfflineLicenseState.EXPIRED, manager.state("dl-1"))
        assertNull(store().get("dl-1")!!.keySetId)
        assertNull(manager.offlineDrmConfiguration("dl-1"))
        assertTrue(manager.needsRenewal("dl-1"))
    }

    @Test
    fun renewDeviceLimitExpires() {
        acquireActive()
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"offline_device_limit"}"""))
        assertEquals(DrmPlaybackError.offlineDeviceLimit, manager().renew("dl-1").error)
        assertEquals(OfflineLicenseState.EXPIRED, manager().state("dl-1"))
    }

    @Test
    fun renewWithLapsedBearerKeepsEverything() {
        acquireActive()
        val manager = manager()
        server.enqueue(MockResponse().setResponseCode(401))

        assertEquals(DrmPlaybackError.expired, manager.renew("dl-1").error)

        assertEquals(OfflineLicenseState.ACTIVE, manager.state("dl-1"))
        assertArrayEquals(KEY_SET_1, store().get("dl-1")!!.keySetId)
    }

    @Test
    fun renewOfflineKeepsEverything() {
        acquireActive()
        val manager = manager()
        server.shutdown()

        assertEquals(DrmPlaybackError.network, manager.renew("dl-1").error)

        assertEquals(OfflineLicenseState.ACTIVE, manager.state("dl-1"))
        assertArrayEquals(KEY_SET_1, store().get("dl-1")!!.keySetId)
    }

    @Test
    fun renewLicenceServerRefusalNeverExpires() {
        acquireActive()
        server.enqueue(MockResponse().setBody("""{"token":"t"}"""))
        server.enqueue(MockResponse().setResponseCode(403))
        assertEquals(DrmPlaybackError.notEntitled, manager().renew("dl-1").error)
        assertEquals(OfflineLicenseState.ACTIVE, manager().state("dl-1"))
    }

    @Test
    fun renewOnExpiredDownloadIsExpiredWithoutNetwork() {
        acquireActive()
        server.enqueue(MockResponse().setResponseCode(403))
        manager().renew("dl-1")
        val before = server.requestCount
        assertEquals(DrmPlaybackError.expired, manager().renew("dl-1").error)
        assertEquals(before, server.requestCount)
    }

    @Test
    fun acquireDropsLeftoverWhenRemainingTimeIsLicensePolicy() {
        acquireActive()
        engine.remainingFailsWith = RuntimeException("""{"cdmError":167}: ERROR_DRM_LICENSE_POLICY""")
        engine.nextKeySet = KEY_SET_2
        enqueueTokenAndLicense()

        assertTrue(manager().acquire("dl-1", format(), endpoints()).isSuccess)

        assertEquals(OfflineLicenseState.ACTIVE, manager().state("dl-1"))
        assertArrayEquals(KEY_SET_2, store().get("dl-1")!!.keySetId)
        assertEquals(listOf(KEY_SET_1.toList()), engine.releasedKeySets.map { it.toList() })
    }

    @Test
    fun acquireRetriesAfterLicensePolicyWhenLeftoverExists() {
        acquireActive()
        engine.downloadFailCount = 1
        engine.downloadFailWith = RuntimeException("""{"cdmError":167}: ERROR_DRM_LICENSE_POLICY""")
        engine.nextKeySet = KEY_SET_2
        enqueueTokenAndLicense()

        assertTrue(manager().acquire("dl-1", format(), endpoints()).isSuccess)
        assertArrayEquals(KEY_SET_2, store().get("dl-1")!!.keySetId)
        assertEquals(listOf(KEY_SET_1.toList()), engine.releasedKeySets.map { it.toList() })
    }

    @Test
    fun renewLicensePolicyExpiresLeftover() {
        acquireActive()
        engine.failWith = RuntimeException("""{"cdmError":167}: ERROR_DRM_LICENSE_POLICY""")

        assertEquals(DrmPlaybackError.unknown, manager().renew("dl-1").error)
        assertEquals(OfflineLicenseState.EXPIRED, manager().state("dl-1"))
        assertNull(store().get("dl-1")!!.keySetId)
    }

    @Test
    fun needsRenewalLicensePolicyExpiresLeftover() {
        acquireActive()
        engine.remainingFailsWith = RuntimeException("""{"cdmError":167}: ERROR_DRM_LICENSE_POLICY""")

        assertTrue(manager().needsRenewal("dl-1"))
        assertEquals(OfflineLicenseState.EXPIRED, manager().state("dl-1"))
    }

    @Test
    fun releaseDeletesRecord() {
        acquireActive()
        val manager = manager()

        manager.release("dl-1")

        assertEquals(OfflineLicenseState.NONE, manager.state("dl-1"))
        assertEquals(listOf(KEY_SET_1.toList()), engine.releasedKeySets.map { it.toList() })
    }

    @Test
    fun releaseDeletesEvenWhenCdmReleaseFails() {
        acquireActive()
        val manager = manager()
        engine.releaseFails = true

        manager.release("dl-1")

        assertEquals(OfflineLicenseState.NONE, manager.state("dl-1"))
    }

    @Test
    fun releaseWorksOnExpiredRecord() {
        acquireActive()
        server.enqueue(MockResponse().setResponseCode(403))
        manager().renew("dl-1")
        manager().release("dl-1")
        assertEquals(OfflineLicenseState.NONE, manager().state("dl-1"))
    }

    @Test
    fun offlineDrmConfigurationUsesTheKeySetId() {
        acquireActive()
        val config = manager().offlineDrmConfiguration("dl-1")
        assertNotNull(config)
        assertEquals(C.WIDEVINE_UUID, config!!.scheme)
        assertArrayEquals(KEY_SET_1, config.keySetId)
    }

    @Test
    fun noNetworkCallbackAlwaysFails() {
        val callback = NoNetworkMediaDrmCallback()
        assertThrowsDrm { callback.executeKeyRequest(C.WIDEVINE_UUID, ExoMediaDrm.KeyRequest(CHALLENGE, "", 0)) }
        assertThrowsDrm { callback.executeProvisionRequest(C.WIDEVINE_UUID, ExoMediaDrm.ProvisionRequest(CHALLENGE, "")) }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun kidComesFromTheWidevinePsshOnly() {
        assertEquals(KID_HEX, OfflineLicenseManager.widevineKidHex(format()))
        val other = DrmInitData(DrmInitData.SchemeData(C.PLAYREADY_UUID, "audio/mp4", pssh()))
        assertNull(OfflineLicenseManager.widevineKidHex(Format.Builder().setDrmInitData(other).build()))
        assertNull(OfflineLicenseManager.widevineKidHex(Format.Builder().build()))
    }

    // --- helpers -----------------------------------------------------------------------------

    private fun assertThrowsDrm(block: () -> Unit) {
        try {
            block()
            org.junit.Assert.fail("expected exception")
        } catch (_: Exception) {
        }
    }

    private fun acquireActive() {
        enqueueTokenAndLicense()
        assertTrue(manager().acquire("dl-1", format(), endpoints()).isSuccess)
    }

    private fun enqueueTokenAndLicense() {
        server.enqueue(MockResponse().setBody("""{"token":"offline-token"}"""))
        server.enqueue(MockResponse().setBody(okio.Buffer().write(LICENSE)))
    }

    private fun endpoints() = OfflineEndpoints(
        tokenUrl = server.url("/assets/a/drm-token").toString(),
        licenseUrl = server.url("/AcquireLicense").toString(),
    )

    private fun store() = FileOfflineLicenseStore(storeDir)

    private fun manager(factory: OfflineLicenseEngineFactory = engineFactory()): OfflineLicenseManager {
        val config = OfflineLicenseConfig("device-1") { "sso" }
        return OfflineLicenseManager(
            config = config,
            store = store(),
            engineFactory = factory,
            client = WidevineOfflineLicenseClient(config),
            clock = { now },
        )
    }

    private fun engineFactory() = OfflineLicenseEngineFactory { callback ->
        engineCreations++
        engine.callback = callback
        engine
    }

    private fun format(): Format =
        Format.Builder()
            .setDrmInitData(DrmInitData(DrmInitData.SchemeData(C.WIDEVINE_UUID, "audio/mp4", pssh())))
            .build()

    /** Fake of the Media3 helper: drives the real callback like the CDM would. */
    private class FakeEngine : OfflineLicenseEngine {
        lateinit var callback: MediaDrmCallback
        var remaining: Long = 27L * 24 * 3600
        var nextKeySet: ByteArray = KEY_SET_1
        var renewedKeySet: ByteArray = KEY_SET_2
        var failWith: RuntimeException? = null
        var remainingFailsWith: RuntimeException? = null
        var downloadFailCount = 0
        var downloadFailWith: RuntimeException? = null
        var releaseFails = false
        var wrapAndRetryCallback = false
        var provisionFirst: String? = null
        var provisionResponse: ByteArray? = null
        var releasedEngines = 0
        val releasedKeySets = mutableListOf<ByteArray>()

        private fun keyRequest() {
            failWith?.let { throw it }
            provisionFirst?.let {
                provisionResponse = try {
                    callback.executeProvisionRequest(C.WIDEVINE_UUID, ExoMediaDrm.ProvisionRequest(CHALLENGE, it)).data
                } catch (e: Exception) {
                    throw RuntimeException("provisioning", e)
                }
            }
            try {
                callback.executeKeyRequest(C.WIDEVINE_UUID, ExoMediaDrm.KeyRequest(CHALLENGE, "", 0))
            } catch (e: Exception) {
                if (wrapAndRetryCallback) {
                    try {
                        callback.executeKeyRequest(C.WIDEVINE_UUID, ExoMediaDrm.KeyRequest(CHALLENGE, "", 0))
                    } catch (_: Exception) {
                    }
                }
                throw RuntimeException("session error", e)
            }
        }

        override fun downloadLicense(format: Format): ByteArray {
            if (downloadFailCount > 0) {
                downloadFailCount--
                throw downloadFailWith ?: RuntimeException("download")
            }
            keyRequest()
            return nextKeySet
        }

        override fun renewLicense(keySetId: ByteArray): ByteArray {
            keyRequest()
            return renewedKeySet
        }

        override fun releaseLicense(keySetId: ByteArray) {
            if (releaseFails) throw RuntimeException("release failed")
            releasedKeySets += keySetId
        }

        override fun remainingSeconds(keySetId: ByteArray): Long {
            remainingFailsWith?.let { throw it }
            failWith?.let { throw it }
            return remaining
        }

        override fun release() {
            releasedEngines++
        }
    }

    private companion object {
        val CONTENT_KID = ByteArray(16) { (it * 17).toByte() }
        const val KID_HEX = "00112233445566778899aabbccddeeff"
        val KEY_SET_1 = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
        val KEY_SET_2 = byteArrayOf(9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)
        val CHALLENGE = byteArrayOf(0x08, 0x01, 0x12, 0x34)
        val LICENSE = byteArrayOf(0x00, 0x7f, 0xff.toByte())

        /** Widevine PSSH v1 box with one KID. */
        fun pssh(): ByteArray {
            val system = byteArrayOf(
                0xed.toByte(), 0xef.toByte(), 0x8b.toByte(), 0xa9.toByte(), 0x79, 0xd6.toByte(), 0x4a, 0xce.toByte(),
                0xa3.toByte(), 0xc8.toByte(), 0x27, 0xdc.toByte(), 0xd5.toByte(), 0x1d, 0x21, 0xed.toByte(),
            )
            val size = 4 + 4 + 4 + 16 + 4 + 16 + 4
            val buffer = ByteBuffer.allocate(size)
            buffer.putInt(size).put("pssh".toByteArray()).putInt(0x01000000).put(system)
            buffer.putInt(1).put(CONTENT_KID).putInt(0)
            return buffer.array()
        }
    }
}
