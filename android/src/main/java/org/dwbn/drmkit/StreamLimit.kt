package org.dwbn.drmkit

/**
 * Client stream-limit policy from the playback descriptor / client-config.
 * Cadence comes from the interval fields; callers must not hardcode 300.
 */
data class StreamLimit(
    val mode: String,
    val renewalIntervalSeconds: Int,
    val heartbeatIntervalSeconds: Int,
) {
    companion object {
        const val MODE_NONE = "none"
        const val MODE_AXINOM_CSL = "axinom_csl"
        const val MODE_LONG_LICENSE = "long_license"
        const val MODE_APP_HEARTBEAT = "app_heartbeat"
    }
}
