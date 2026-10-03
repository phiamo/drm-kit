package org.dwbn.drmkit

import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

/**
 * Host-supplied identity for offline licences.
 *
 * [deviceId] is the stable per-install UUID (sent as `session=download:{deviceId}`).
 * [authorization] returns the current SSO access token and is read on every request.
 */
data class OfflineLicenseConfig(
    val deviceId: String,
    val authorization: () -> String,
)

/** Absolute per-download endpoints; [tokenUrl] is the asset's `/drm-token`. */
data class OfflineEndpoints(
    val tokenUrl: String,
    val licenseUrl: String,
)

/**
 * OkHttp client for the offline `/drm-token?purpose=offline` call, AcquireLicense and
 * provisioning. No renewal credential is sent. Never logs tokens, challenges or licences.
 */
class WidevineOfflineLicenseClient @JvmOverloads constructor(
    private val config: OfflineLicenseConfig,
    private val httpClient: OkHttpClient = DrmHttp.defaultHttpClient(),
) {
    fun fetchToken(tokenUrl: String, kidHex: String): String {
        val url = DrmHttp.parseUrl(tokenUrl).newBuilder()
            .setQueryParameter("kid", kidHex)
            .setQueryParameter("session", "$SESSION_PREFIX${config.deviceId}")
            .setQueryParameter("purpose", PURPOSE_OFFLINE)
            .build()
        val request = Request.Builder()
            .url(url)
            .get()
            .header(DrmHttp.HEADER_AUTHORIZATION, DrmHttp.bearer(config.authorization()))
            .build()
        return execute(request, CallKind.TOKEN) { body ->
            val token = JSONObject(String(body, Charsets.UTF_8)).optString("token")
            if (token.isNullOrEmpty()) {
                throw DrmKitException(DrmPlaybackError.unknown)
            }
            token
        }
    }

    fun acquireLicense(licenseUrl: String, challenge: ByteArray, token: String): ByteArray =
        execute(DrmHttp.licenseRequest(licenseUrl, challenge, token), CallKind.LICENSE) { it }

    fun provision(url: String, signedRequest: ByteArray): ByteArray =
        execute(DrmHttp.provisionRequest(url, signedRequest), CallKind.PROVISION) { it }

    private fun <T> execute(request: Request, kind: CallKind, read: (ByteArray) -> T): T =
        DrmHttp.execute(
            httpClient,
            request,
            { code, _, errorBody -> mapHttpError(kind, code, errorBody) },
            read,
        )

    private enum class CallKind { TOKEN, LICENSE, PROVISION }

    companion object {
        const val PURPOSE_OFFLINE = "offline"
        const val SESSION_PREFIX = "download:"
        const val REASON_OFFLINE_DEVICE_LIMIT = "offline_device_limit"

        private fun mapHttpError(kind: CallKind, code: Int, errorBody: () -> ByteArray?): DrmPlaybackError =
            when (kind) {
                CallKind.TOKEN -> when (code) {
                    403 -> if (isDeviceLimit(errorBody())) {
                        DrmPlaybackError.offlineDeviceLimit
                    } else {
                        DrmPlaybackError.notEntitled
                    }
                    401 -> DrmPlaybackError.expired
                    else -> DrmPlaybackError.unknown
                }
                CallKind.LICENSE -> if (code == 403) DrmPlaybackError.notEntitled else DrmPlaybackError.unknown
                CallKind.PROVISION -> DrmPlaybackError.unknown
            }

        private fun isDeviceLimit(body: ByteArray?): Boolean {
            if (body == null) return false
            return try {
                JSONObject(String(body, Charsets.UTF_8)).optString("error") == REASON_OFFLINE_DEVICE_LIMIT
            } catch (_: Exception) {
                false
            }
        }
    }
}
