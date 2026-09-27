# Testing

Vector: `testdata/identifiers-test-vector.json`. Tests ignore `kdfCiphertext`.

Android Widevine tests use OkHttp MockWebServer (JVM, no real CDM, no decrypt).

```bash
cd android && ./gradlew test
xcodebuild test -scheme DrmKit -destination 'platform=iOS Simulator,name=<any iPhone>'
xcodebuild build -project pilot/DrmKitPilot.xcodeproj -scheme DrmKitPilot -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

iOS FairPlay tests (`FairPlaySessionTests`) stub HTTP with a `URLProtocol`, fake the key request and drive timers with a fake scheduler. They cover the certificate, SPC, token and license order, KID parsing from `skd://`, the error map, renewal, heartbeat, `none` and release. **No decrypt.**

CI (`.github/workflows/ci.yml`) runs the Android job and iOS unit tests on iOS 16, 17, 18 and 26 simulators, and builds the package and the pilot app for the iOS 15 deployment target (Apple no longer serves the iOS 15 simulator runtime). **No device lab, no decrypt.** Simulators are unit-only — **never FairPlay**. Android `./gradlew test` is JVM.

Client DRM playback, stream-cap, and FairPlay-on-device are **manual-before-tag**. Floors: iPhone 7 (`iPhone9,3`, iOS 15.8.5) is the iOS floor device; the SE (`iPhone12,8`, iOS 26.x) is the current-iOS FairPlay phone; Android API 24–28 = AVD `DRM_QA_API28` (`ANDROID_AVD_HOME=$HOME/.config/.android/avd`). Pixel 7a is Widevine L1.

## FairPlay pilot app

`pilot/DrmKitPilot.xcodeproj` (SwiftUI, iOS 15) uses the local package. Open it in Xcode, pick your team, run it on the device:

1. Enter the API base (default ferrix `https://awareness.ferrix.dwbn.org/api/v2`), the slug (`test-1`) and an SSO access token.
2. **Fetch descriptor** (or paste the `/assets/{slug}/playback` JSON), choose the key URI form (`keyUri` = the playlist's `skd://` as is, `axinomGuid` = `skd://<GUID>:<IV>`), then **Play**.
3. The screen shows the key URIs seen and the certificate / token / license / heartbeat requests for this playback; **Stop** logs the totals. It never shows the token, SPC or CKC.

Record in the story: whether `keyUri` decrypts (Shaka's form accepted) or only `axinomGuid`, and the license requests per playback.
