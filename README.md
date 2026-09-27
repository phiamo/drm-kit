# drm-kit

DRM building blocks for native players: an Android **Widevine session** for Media3 and an iOS **FairPlay session** for `AVContentKeySession` (license, token, renewal, heartbeat and stream limits), plus **DRM identifier** helpers for Android and iOS. It's a Kotlin Android library and a Swift package, with no Capacitor dependency.

[![JitPack](https://jitpack.io/v/phiamo/drm-kit.svg)](https://jitpack.io/#phiamo/drm-kit)
[![CI](https://img.shields.io/github/actions/workflow/status/phiamo/drm-kit/ci.yml?style=flat-square)](https://github.com/phiamo/drm-kit/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/W8V527Q5YX)

## Part of the DWBN media stack

| | Project | What it does |
|---|---|---|
| 🎵 | [**capacitor-plugin-playlist**](https://github.com/phiamo/capacitor-plugin-playlist) · [`@dwbn/capacitor-plugin-playlist`](https://www.npmjs.com/package/@dwbn/capacitor-plugin-playlist) | Background audio playlists, lock screen, audio↔video handoff |
| 🎬 | [**capacitor-video-player**](https://github.com/phiamo/capacitor-video-player) · [`@dwbn/capacitor-video-player`](https://www.npmjs.com/package/@dwbn/capacitor-video-player) | Native fullscreen video with Media3 / AVPlayer, PiP, Chromecast and subtitles |
| 🔐 | **drm-kit** (this repo) · Swift Package Manager / JitPack | Widevine and FairPlay sessions and DRM identifiers that the host app plugs into both plugins |

The two plugins never depend on drm-kit. Each exposes a small provider hook (`AudioDrm.setProvider`, `VideoDrm.setProvider`). The **host app** adds drm-kit and registers one session class for both. Without DRM, the plugins behave exactly as before. The [audio ↔ video handoff guide](https://github.com/phiamo/capacitor-plugin-playlist/blob/main/docs/video-handoff.md#handoff-with-drm) shows all three working together.

## Status

| | Android | iOS |
|---|---|---|
| `DrmIdentifiers` (hex, UUID, FairPlay URI, Axinom key id/value) | ✅ | ✅ |
| Widevine session for Media3 (`WidevineSession`) | ✅ 0.3.1 | — |
| FairPlay session for `AVPlayer` (`FairPlaySession`) | — | 🧪 unreleased (device pilot pending) |
| Offline / persistable keys | planned | planned |

Current release: **0.3.1** (0.3.1: license renewals work — renewal requests reuse the first request's KID). `1.0.0` will follow the first production DRM release. Minimums: Android SDK 24, iOS 15.

## Install

drm-kit is not on npm. Apps pull it straight from the git tags.

**Android**: [JitPack](https://jitpack.io/#phiamo/drm-kit). Add it to the **app** module (`android/app/build.gradle`), not to a plugin:

```gradle
repositories { maven { url 'https://jitpack.io' } }
dependencies { implementation 'com.github.phiamo:drm-kit:0.3.1' }
```

**iOS**: Swift Package Manager. Add it to the **App** target in Xcode (File → Add Package Dependencies). Don't add it to a plugin's `Package.swift` or to `CapApp-SPM`, because Capacitor regenerates that file:

```swift
.package(url: "https://github.com/phiamo/drm-kit.git", from: "0.3.1")
```

## Usage

One session class serves both Capacitor plugins. It wraps `WidevineSession` and hands its `MediaDrmCallback` to Media3:

```java
@UnstableApi
public final class AppWidevineSession implements AudioDrmSession, VideoDrmSession {
  private final WidevineSession session;
  private final DrmSessionManager drmSessionManager;

  public AppWidevineSession(JSObject drm, Consumer<String> onError) {
    WidevineSession.Config config = new WidevineSession.Config(
      Api.tokenUrl(),                                  // absolute URLs, built by the app
      drm.getString("widevineLicenseUrl"),
      Api.heartbeatUrl(drm.getString("playbackSessionId")),
      drm.getString("playbackSessionId"),
      drm.getString("renewalCredential"),
      () -> Auth.currentAccessToken(),                 // read on every request
      StreamLimits.from(drm.getJSObject("streamLimit")) // mode + renewal/heartbeat intervals
    );
    session = new WidevineSession(config, new WidevineLicenseClient(config),
      new WidevineSession.NativeTaskScheduler(), error -> onError.accept(error.name()));
    drmSessionManager = new DefaultDrmSessionManager.Builder()
      .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
      .setMultiSession(true)
      .build(session.createMediaDrmCallback());
  }

  @Override public void applyDrm(MediaItem.Builder b) {
    b.setDrmConfiguration(new MediaItem.DrmConfiguration.Builder(C.WIDEVINE_UUID).build());
  }
  @Override public DrmSessionManager getDrmSessionManager() { return drmSessionManager; }
  @Override public void start() { session.start(); }       // starts renewal / heartbeat timers
  @Override public void release() { session.release(); }   // leave the DrmSessionManager to ExoPlayer
}
```

`Api`, `Auth` and `StreamLimits` stand for your own app code. `StreamLimits.from` builds a `StreamLimit(mode, renewalIntervalSeconds, heartbeatIntervalSeconds)` and falls back to `StreamLimit.MODE_NONE`.

Register the session class once in your `Application`:

```java
AudioDrm.setProvider(AppWidevineSession::new);
VideoDrm.setProvider(AppWidevineSession::new);
```

Errors reach the plugins as one of `blockedByStreamLimit`, `notEntitled`, `expired`, `network` or `unknown` (`DrmPlaybackError`). Don't auto-retry `blockedByStreamLimit`. The token getter is called for every request, so a token your app refreshes also reaches long sessions. drm-kit never refreshes tokens itself (breaking change in 0.3.0).

### iOS (FairPlay)

`FairPlaySession` mirrors `WidevineSession`: same token, license, heartbeat and error contract, plus the descriptor's `fairplayCertificateUrl`. Route the asset's key requests through it before playback:

```swift
import DrmKit

let config = FairPlaySession.Config(
    tokenUrl: Api.tokenUrl(slug),                      // absolute URLs, built by the app
    licenseUrl: drm.fairplayLicenseUrl,
    certificateUrl: drm.fairplayCertificateUrl,
    heartbeatUrl: Api.heartbeatUrl(drm.playbackSessionId),
    playbackSessionId: drm.playbackSessionId,
    renewalCredential: drm.renewalCredential,
    authorization: { Auth.currentAccessToken() },       // read on every request
    streamLimit: StreamLimit(mode: drm.streamLimit.mode,
                             renewalIntervalSeconds: drm.streamLimit.renewalIntervalSeconds,
                             heartbeatIntervalSeconds: drm.streamLimit.heartbeatIntervalSeconds)
)
let session = FairPlaySession(config: config) { error in onError(error.rawValue) }
let asset = AVURLAsset(url: manifestUrl)
session.addContentKeyRecipient(asset)  // before the player item loads
player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
session.start()                        // renewal / heartbeat timers
// … on teardown:
session.release()
```

Each key request (initial or renewing) fetches the application certificate once per session, builds the SPC, fetches a fresh `/drm-token` for the KID in the request's `skd://` URI (never from the SPC), POSTs the SPC with `X-AxDRM-Message` and returns the CKC. `axinom_csl` / `long_license` renew with `renewExpiringResponseData` at 70% of `renewalIntervalSeconds`, then every interval; `app_heartbeat` posts the heartbeat every `heartbeatIntervalSeconds`; `none` runs no timers. `contentIdentifierForm` picks the key URI Axinom sees (`.keyUri` as in the playlist, or `.axinomGuid`); the device pilot (Story 58.2) decides which one production uses. FairPlay does not work on the simulator. The pilot app in [`pilot/`](./pilot) plays one descriptor on a device.

Plugin-side details: [playlist DRM](https://github.com/phiamo/capacitor-plugin-playlist/blob/main/docs/drm.md) · [video DRM](https://github.com/phiamo/capacitor-video-player/blob/main/docs/drm.md).

## Documentation

| | |
|---|---|
| [Key IDs and identifiers](./docs/identifiers.md) | Which KID to send to `/drm-token` on each platform, and `DrmIdentifiers` |
| [Testing](./docs/testing.md) | Unit tests, CI, and the manual device matrix before a tag |

## Contributing

Work on DRM happens on `feature/vod-drm` (merge `main` first). Tag releases as `vX.Y.Z`: JitPack and SPM both build from the tag.

## License

[MIT](./LICENSE) © Philipp Mohrenweiser. Built for the DWBN apps.
