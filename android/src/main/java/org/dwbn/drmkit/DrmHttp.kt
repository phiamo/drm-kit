package org.dwbn.drmkit

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

internal class DrmKitException(val error: DrmPlaybackError) : RuntimeException(error.name)

/**
 * HTTP plumbing shared by the streaming and offline Widevine clients.
 * Never logs tokens, JWTs, entitlement messages, or license bodies.
 */
internal object DrmHttp {
    const val HEADER_AUTHORIZATION = "Authorization"
    const val HEADER_AXINOM_MESSAGE = "X-AxDRM-Message"
    const val HEADER_AXINOM_ERROR_CODE = "X-AxDrm-ErrorCode"

    val OCTET_STREAM = "application/octet-stream".toMediaType()

    fun defaultHttpClient(): OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build()

    fun bearer(accessToken: String): String =
        if (accessToken.startsWith("Bearer ")) accessToken else "Bearer $accessToken"

    fun parseUrl(url: String): HttpUrl =
        try {
            url.toHttpUrl()
        } catch (_: IllegalArgumentException) {
            throw DrmKitException(DrmPlaybackError.unknown)
        }

    fun provisionRequest(url: String, signedRequest: ByteArray): Request {
        val provisionUrl = parseUrl(url).newBuilder()
            .setQueryParameter("signedRequest", String(signedRequest, Charsets.UTF_8))
            .build()
        return Request.Builder()
            .url(provisionUrl)
            .post(ByteArray(0).toRequestBody(null))
            .build()
    }

    fun licenseRequest(url: String, challenge: ByteArray, token: String): Request =
        Request.Builder()
            .url(parseUrl(url))
            .post(challenge.toRequestBody(OCTET_STREAM))
            .header(HEADER_AXINOM_MESSAGE, token)
            .build()

    /**
     * Runs [request]. Transport failures map to [DrmPlaybackError.network]; non-2xx responses go
     * through [mapError] (status, Axinom error code, lazily read response body).
     */
    fun <T> execute(
        httpClient: OkHttpClient,
        request: Request,
        mapError: (code: Int, axinomErrorCode: String?, errorBody: () -> ByteArray?) -> DrmPlaybackError,
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
                val errorBody = {
                    try {
                        http.body?.bytes()
                    } catch (_: IOException) {
                        null
                    }
                }
                throw DrmKitException(mapError(http.code, errorCode, errorBody))
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
}
