package org.dwbn.drmkit

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

/**
 * OkHttp client for `/drm-token`, Axinom AcquireLicense, and playback-session heartbeat.
 * Never logs tokens, JWTs, entitlement messages, or license bodies.
 */
class WidevineLicenseClient @JvmOverloads constructor(
    private val config: WidevineSession.Config,
    private val httpClient: OkHttpClient = defaultHttpClient(),
) {
    fun fetchToken(kidHex: String): String {
        val url = DrmHttp.parseUrl(config.tokenUrl).newBuilder()
            .setQueryParameter("kid", kidHex)
            .setQueryParameter("session", config.playbackSessionId)
            .setQueryParameter("purpose", PURPOSE_STREAM)
            .build()
        val request = Request.Builder()
            .url(url)
            .get()
            .header(HEADER_AUTHORIZATION, bearer(config.authorization()))
            .header(HEADER_RENEWAL_CREDENTIAL, config.renewalCredential)
            .build()
        return execute(request, CallKind.TOKEN) { body ->
            val token = JSONObject(String(body, Charsets.UTF_8)).optString("token")
            if (token.isNullOrEmpty()) {
                throw DrmKitException(DrmPlaybackError.unknown)
            }
            token
        }
    }

    fun acquireLicense(challenge: ByteArray, token: String): ByteArray {
        val request = DrmHttp.licenseRequest(config.licenseUrl, challenge, token)
        return execute(request, CallKind.LICENSE) { it }
    }

    fun heartbeat() {
        val request = Request.Builder()
            .url(DrmHttp.parseUrl(config.heartbeatUrl))
            .post(ByteArray(0).toRequestBody(null))
            .header(HEADER_AUTHORIZATION, bearer(config.authorization()))
            .header(HEADER_RENEWAL_CREDENTIAL, config.renewalCredential)
            .build()
        execute(request, CallKind.HEARTBEAT) { }
    }

    fun provision(url: String, signedRequest: ByteArray): ByteArray =
        execute(DrmHttp.provisionRequest(url, signedRequest), CallKind.PROVISION) { it }

    private fun <T> execute(request: Request, kind: CallKind, read: (ByteArray) -> T): T =
        DrmHttp.execute(
            httpClient,
            request,
            { code, axinomErrorCode, _ -> mapHttpError(kind, code, axinomErrorCode) },
            read,
        )

    private enum class CallKind { TOKEN, HEARTBEAT, LICENSE, PROVISION }

    companion object {
        const val PURPOSE_STREAM = "stream"
        const val HEADER_AUTHORIZATION = DrmHttp.HEADER_AUTHORIZATION
        const val HEADER_RENEWAL_CREDENTIAL = "X-Renewal-Credential"
        const val HEADER_AXINOM_MESSAGE = DrmHttp.HEADER_AXINOM_MESSAGE
        const val HEADER_AXINOM_ERROR_CODE = DrmHttp.HEADER_AXINOM_ERROR_CODE

        fun defaultHttpClient(): OkHttpClient = DrmHttp.defaultHttpClient()

        internal fun bearer(accessToken: String): String = DrmHttp.bearer(accessToken)

        private fun mapHttpError(kind: CallKind, code: Int, axinomErrorCode: String?): DrmPlaybackError {
            return when (kind) {
                CallKind.TOKEN, CallKind.HEARTBEAT -> when (code) {
                    409 -> DrmPlaybackError.blockedByStreamLimit
                    403 -> DrmPlaybackError.notEntitled
                    401 -> DrmPlaybackError.expired
                    else -> DrmPlaybackError.unknown
                }
                CallKind.LICENSE -> when {
                    code == 403 && axinomErrorCode == "1" -> DrmPlaybackError.blockedByStreamLimit
                    else -> DrmPlaybackError.unknown
                }
                CallKind.PROVISION -> DrmPlaybackError.unknown
            }
        }
    }
}
