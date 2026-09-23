package org.dwbn.drmkit

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

internal class DrmKitException(val error: DrmPlaybackError) : RuntimeException(error.name)

/**
 * OkHttp client for `/drm-token`, Axinom AcquireLicense, and playback-session heartbeat.
 * Never logs tokens, JWTs, entitlement messages, or license bodies.
 */
class WidevineLicenseClient(
    private val config: WidevineSession.Config,
    private val httpClient: OkHttpClient = defaultHttpClient(),
) {
    fun fetchToken(kidHex: String): String {
        val url = config.tokenUrl.toHttpUrl().newBuilder()
            .setQueryParameter("kid", kidHex)
            .setQueryParameter("session", config.playbackSessionId)
            .setQueryParameter("purpose", PURPOSE_STREAM)
            .build()
        val request = Request.Builder()
            .url(url)
            .get()
            .header(HEADER_AUTHORIZATION, bearer(config.authorization))
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
        val request = Request.Builder()
            .url(config.licenseUrl.toHttpUrl())
            .post(challenge.toRequestBody(OCTET_STREAM))
            .header(HEADER_AXINOM_MESSAGE, token)
            .build()
        return execute(request, CallKind.LICENSE) { it }
    }

    fun heartbeat() {
        val request = Request.Builder()
            .url(config.heartbeatUrl.toHttpUrl())
            .post(ByteArray(0).toRequestBody(null))
            .header(HEADER_AUTHORIZATION, bearer(config.authorization))
            .header(HEADER_RENEWAL_CREDENTIAL, config.renewalCredential)
            .build()
        execute(request, CallKind.HEARTBEAT) { }
    }

    fun provision(url: String, signedRequest: ByteArray): ByteArray {
        val json = ByteArray(JSON_PREFIX.size + signedRequest.size + JSON_SUFFIX.size).also { dest ->
            JSON_PREFIX.copyInto(dest)
            signedRequest.copyInto(dest, JSON_PREFIX.size)
            JSON_SUFFIX.copyInto(dest, JSON_PREFIX.size + signedRequest.size)
        }
        val request = Request.Builder()
            .url(url)
            .post(json.toRequestBody(JSON))
            .build()
        return execute(request, CallKind.PROVISION) { it }
    }

    private fun <T> execute(
        request: Request,
        kind: CallKind,
        read: (ByteArray) -> T,
    ): T {
        val response = try {
            httpClient.newCall(request).execute()
        } catch (_: IOException) {
            throw DrmKitException(DrmPlaybackError.network)
        }
        response.use { http ->
            val errorCode = http.header(HEADER_AXINOM_ERROR_CODE)
            if (!http.isSuccessful) {
                throw DrmKitException(mapHttpError(kind, http.code, errorCode))
            }
            val body = try {
                http.body?.bytes() ?: ByteArray(0)
            } catch (_: IOException) {
                throw DrmKitException(DrmPlaybackError.network)
            }
            return try {
                read(body)
            } catch (e: DrmKitException) {
                throw e
            } catch (_: Exception) {
                throw DrmKitException(DrmPlaybackError.unknown)
            }
        }
    }

    private enum class CallKind { TOKEN, HEARTBEAT, LICENSE, PROVISION }

    companion object {
        const val PURPOSE_STREAM = "stream"
        const val HEADER_AUTHORIZATION = "Authorization"
        const val HEADER_RENEWAL_CREDENTIAL = "X-Renewal-Credential"
        const val HEADER_AXINOM_MESSAGE = "X-AxDRM-Message"
        const val HEADER_AXINOM_ERROR_CODE = "X-AxDrm-ErrorCode"

        private val OCTET_STREAM = "application/octet-stream".toMediaType()
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val JSON_PREFIX = "{\"signedRequest\":\"".toByteArray(Charsets.UTF_8)
        private val JSON_SUFFIX = "\"}".toByteArray(Charsets.UTF_8)

        fun defaultHttpClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(15, TimeUnit.SECONDS)
                .writeTimeout(15, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false)
                .build()

        internal fun bearer(accessToken: String): String =
            if (accessToken.startsWith("Bearer ")) accessToken else "Bearer $accessToken"

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
