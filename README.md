# drm-kit

Shared DRM identifiers and Android Widevine session logic for the DWBN Awareness app. Swift package + Kotlin Android library. No Capacitor dependency.

Public repo: [phiamo/drm-kit](https://github.com/phiamo/drm-kit). Work DRM stories on `feature/vod-drm` (merge `main` first). Commits name the story.

**Now (`v0.2.0`):** `DrmIdentifiers` plus an Android `WidevineSession` (custom Media3 `MediaDrmCallback`, native token/license/heartbeat, stream-limit timers). Do not invent a second KID mapping.

### KID for `/drm-token`

`kid` must be the 32-hex `content_key.kid` (same bytes as HLS `#EXT-X-KEY` / Shaka `keyId`). Backend `TokenService` looks that hex up; anything else is `403 Unknown content key`.

| Surface | KID source | Status |
| --- | --- | --- |
| Web PWA (`web-drm-hls.ts`) | hls.js `keyContext.keyId` | Correct |
| Catalog Twig (`web-drm-hls.js`) | same HLS `keyId` | Correct |
| Android (`WidevineKeyIds.firstKeyId`) | Widevine PSSH / LicenseRequest **content_id**, never ClientIdentification | Fixed in this tree — do not take the first protobuf field 2 of length 16 (that is often a 16-byte client blob) |
| iOS FairPlay (`v0.3.0`) | HLS `skd://kid:iv` via `DrmIdentifiers.fairPlayUri` — not the SPC blob | Not implemented yet; same hex as web |

**Later (same repo, later tags):** FairPlay `AVContentKeySession` (`v0.3.0`, Story 58.2), offline / persistable keys (`v0.4.0` / `v0.5.0`, Epic 59). `1.0.0` waits for the DRM release.

## Consume

The **host app** that needs DRM adds this library. The Capacitor video and playlist plugins do **not** depend on it: without `drm` they behave as today. With `drm`, the host registers a provider implemented with this library.

- Android: `implementation` in `android/app/build.gradle` (not the plugin).
- iOS: SPM on the **App** target. Do not add it to plugin `Package.swift` or to `CapApp-SPM` (Capacitor regenerates that file).

iOS ≥ 18:

```swift
.package(url: "https://github.com/phiamo/drm-kit.git", from: "0.2.0")
```

Android, minSdk 24:

```gradle
implementation 'com.github.phiamo:drm-kit:0.2.0'
```

Plugins never pin this tag. During DRM work the Awareness app pins plugins to `#feature/vod-drm` and, from Story 57.6, pins this library by tag.

## Tests

Vector: `testdata/identifiers-test-vector.json`. Tests ignore `kdfCiphertext`.

Android Widevine tests use OkHttp MockWebServer (JVM, no real CDM, no decrypt).

```bash
cd android && ./gradlew test
xcodebuild test -scheme DrmKit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'
```

CI (`.github/workflows/ci.yml`) is those two jobs on `main` / `feature/vod-drm` / tags. **No device lab, no decrypt.** iPhone 16 Simulator OS 18.5 is unit-only — **never FairPlay**. Android `./gradlew test` is JVM.

Client DRM playback, stream-cap, and FairPlay-on-device are **manual-before-tag**. Floors: USB iOS 18.x physical (not the SE on 26.5.2; not the simulator); Android API 24–28 = AVD `DRM_QA_API28` (`ANDROID_AVD_HOME=$HOME/.config/.android/avd`). Pixel 7a is Widevine L1.
