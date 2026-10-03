package org.dwbn.drmkit

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest

enum class OfflineLicenseState { NONE, ACTIVE, EXPIRED }

/**
 * Persisted offline licence for one download. [keySetId] is null once the licence is [OfflineLicenseState.EXPIRED].
 */
internal class OfflineLicenseRecord(
    val downloadId: String,
    val state: OfflineLicenseState,
    val keySetId: ByteArray?,
    val kidHex: String,
    val endpoints: OfflineEndpoints,
    val savedAtMillis: Long,
)

internal interface OfflineLicenseStore {
    fun get(downloadId: String): OfflineLicenseRecord?
    fun put(record: OfflineLicenseRecord)
    fun delete(downloadId: String)
}

/**
 * One small JSON file per download, written atomically. Pass `Context.noBackupFilesDir`-based
 * directories only: the key set ids must never reach a backup.
 */
internal class FileOfflineLicenseStore(private val dir: File) : OfflineLicenseStore {

    @Synchronized
    override fun get(downloadId: String): OfflineLicenseRecord? {
        val file = fileFor(downloadId)
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText(Charsets.UTF_8))
            if (json.getString(KEY_DOWNLOAD_ID) != downloadId) return null
            OfflineLicenseRecord(
                downloadId = downloadId,
                state = OfflineLicenseState.valueOf(json.getString(KEY_STATE)),
                keySetId = if (json.has(KEY_KEY_SET_ID)) hexToBytes(json.getString(KEY_KEY_SET_ID)) else null,
                kidHex = json.getString(KEY_KID),
                endpoints = OfflineEndpoints(json.getString(KEY_TOKEN_URL), json.getString(KEY_LICENSE_URL)),
                savedAtMillis = json.getLong(KEY_SAVED_AT),
            )
        } catch (_: Exception) {
            null
        }
    }

    @Synchronized
    override fun put(record: OfflineLicenseRecord) {
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create store directory")
        val json = JSONObject()
            .put(KEY_DOWNLOAD_ID, record.downloadId)
            .put(KEY_STATE, record.state.name)
            .put(KEY_KID, record.kidHex)
            .put(KEY_TOKEN_URL, record.endpoints.tokenUrl)
            .put(KEY_LICENSE_URL, record.endpoints.licenseUrl)
            .put(KEY_SAVED_AT, record.savedAtMillis)
        record.keySetId?.let { json.put(KEY_KEY_SET_ID, bytesToHex(it)) }
        val target = fileFor(record.downloadId)
        val tmp = File(dir, target.name + ".tmp")
        tmp.writeText(json.toString(), Charsets.UTF_8)
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IOException("cannot persist offline licence record")
        }
    }

    @Synchronized
    override fun delete(downloadId: String) {
        fileFor(downloadId).delete()
    }

    private fun fileFor(downloadId: String): File = File(dir, sha256Hex(downloadId) + ".json")

    private companion object {
        const val KEY_DOWNLOAD_ID = "downloadId"
        const val KEY_STATE = "state"
        const val KEY_KEY_SET_ID = "keySetId"
        const val KEY_KID = "kid"
        const val KEY_TOKEN_URL = "tokenUrl"
        const val KEY_LICENSE_URL = "licenseUrl"
        const val KEY_SAVED_AT = "savedAt"
    }
}

internal fun sha256Hex(value: String): String =
    bytesToHex(MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)))

/** Variable-length hex (a Widevine `keySetId` is not 16 bytes, so `DrmIdentifiers` does not apply). */
internal fun bytesToHex(bytes: ByteArray): String {
    val out = StringBuilder(bytes.size * 2)
    for (b in bytes) {
        out.append(HEX[(b.toInt() shr 4) and 0xf]).append(HEX[b.toInt() and 0xf])
    }
    return out.toString()
}

internal fun hexToBytes(hex: String): ByteArray {
    require(hex.length % 2 == 0)
    return ByteArray(hex.length / 2) { i ->
        val high = Character.digit(hex[2 * i], 16)
        val low = Character.digit(hex[2 * i + 1], 16)
        require(high >= 0 && low >= 0)
        ((high shl 4) or low).toByte()
    }
}

private val HEX = "0123456789abcdef".toCharArray()
