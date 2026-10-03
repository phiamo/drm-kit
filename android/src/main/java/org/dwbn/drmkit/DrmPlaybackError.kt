package org.dwbn.drmkit

/**
 * Typed DRM playback errors. Names match app `drm-playback-messages.ts`.
 */
enum class DrmPlaybackError {
    blockedByStreamLimit,
    notEntitled,
    offlineDeviceLimit,
    expired,
    network,
    unknown,
}
