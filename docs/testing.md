# Testing

Vector: `testdata/identifiers-test-vector.json`. Tests ignore `kdfCiphertext`.

Android Widevine tests use OkHttp MockWebServer (JVM, no real CDM, no decrypt).

```bash
cd android && ./gradlew test
xcodebuild test -scheme DrmKit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'
```

CI (`.github/workflows/ci.yml`) is those two jobs on `main` / `feature/vod-drm` / tags. **No device lab, no decrypt.** iPhone 16 Simulator OS 18.5 is unit-only — **never FairPlay**. Android `./gradlew test` is JVM.

Client DRM playback, stream-cap, and FairPlay-on-device are **manual-before-tag**. Floors: USB iOS 18.x physical (not the SE on 26.5.2; not the simulator); Android API 24–28 = AVD `DRM_QA_API28` (`ANDROID_AVD_HOME=$HOME/.config/.android/avd`). Pixel 7a is Widevine L1.
