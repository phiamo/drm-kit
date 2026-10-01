# Capacitor host adapter

The player plugins never depend on drm-kit. Each exposes a provider hook (`AudioDrm.setProvider`, `VideoDrm.setProvider`). The **host app** adds drm-kit, holds the bearer and token/heartbeat URLs, and registers one session class that wraps `WidevineSession` / `FairPlaySession`.

This page is the Capacitor copy-paste for that host layer. For a non-Capacitor `AVPlayer`, use the FairPlay snippet in the [README](../README.md#ios-fairplay). Plugin option shape: [playlist DRM](https://github.com/phiamo/capacitor-plugin-playlist/blob/main/docs/drm.md) · [video DRM](https://github.com/phiamo/capacitor-video-player/blob/main/docs/drm.md).

Replace the URL builders with your API. Placeholders here are `{apiBase}/your/token` and `{apiBase}/your/sessions/{id}/heartbeat`. myrecordings uses `/api/v2/assets/{slug}/drm-token` and `/api/v2/playback-sessions/{id}/heartbeat`.

drm-kit does not refresh SSO. Read the bearer on every request (`authorization: { DrmHost.getAccessToken() }`).

## 1. DrmHost holder

Process-wide Bearer, `apiBase`, and active slug. Token and heartbeat URLs are built here, not passed through the JS `drm` object.

### Swift

```swift
import Foundation

public final class DrmHost {
    private static let lock = NSLock()
    private static var accessToken = ""
    private static var apiBase = ""
    private static var activeSlug = ""

    private init() {}

    public static func setAuthorization(_ token: String?) {
        lock.lock()
        accessToken = token ?? ""
        lock.unlock()
    }

    public static func getAccessToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        return accessToken
    }

    public static func setApiBase(_ base: String?) {
        lock.lock()
        guard let base, !base.isEmpty else {
            apiBase = ""
            lock.unlock()
            return
        }
        apiBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        lock.unlock()
    }

    public static func getApiBase() -> String {
        lock.lock()
        defer { lock.unlock() }
        return apiBase
    }

    public static func setActiveSlug(_ slug: String?) {
        lock.lock()
        activeSlug = slug ?? ""
        lock.unlock()
    }

    public static func getActiveSlug() -> String {
        lock.lock()
        defer { lock.unlock() }
        return activeSlug
    }

    public static func tokenUrl() -> String {
        "\(getApiBase())/your/token"  // include getActiveSlug() if your path needs it
    }

    public static func heartbeatUrl(playbackSessionId: String) -> String {
        "\(getApiBase())/your/sessions/\(playbackSessionId)/heartbeat"
    }
}
```

### Java

```java
public final class DrmHost {
  private static volatile String accessToken = "";
  private static volatile String apiBase = "";
  private static volatile String activeSlug = "";

  private DrmHost() {}

  public static void setAuthorization(String token) {
    accessToken = token == null ? "" : token;
  }

  public static String getAccessToken() {
    return accessToken;
  }

  public static void setApiBase(String base) {
    if (base == null || base.isEmpty()) {
      apiBase = "";
      return;
    }
    apiBase = base.endsWith("/") ? base.substring(0, base.length() - 1) : base;
  }

  public static String getApiBase() {
    return apiBase;
  }

  public static void setActiveSlug(String slug) {
    activeSlug = slug == null ? "" : slug;
  }

  public static String getActiveSlug() {
    return activeSlug;
  }

  public static String tokenUrl() {
    return getApiBase() + "/your/token";  // include getActiveSlug() if your path needs it
  }

  public static String heartbeatUrl(String playbackSessionId) {
    return getApiBase() + "/your/sessions/" + playbackSessionId + "/heartbeat";
  }
}
```

## 2. DrmHost Capacitor plugin

JS cannot see native statics. A local 3-method plugin (`DrmHost`) pushes token, slug, and API base from your web layer.

Do **not** add this to `CapApp-SPM` — Capacitor regenerates that package. Put the Swift/Java files in the **App** target and register them yourself.

### TypeScript

```typescript
import { Capacitor, registerPlugin } from '@capacitor/core';

interface DrmHostPlugin {
  setAuthorization(options: { token: string }): Promise<void>;
  setActiveSlug(options: { slug: string }): Promise<void>;
  setApiBase(options: { apiBase: string }): Promise<void>;
}

const DrmHost = registerPlugin<DrmHostPlugin>('DrmHost');

function isNative(): boolean {
  const platform = Capacitor.getPlatform();
  return Capacitor.isNativePlatform() && (platform === 'android' || platform === 'ios');
}

export async function pushDrmHostAuthorization(token: string | null | undefined): Promise<void> {
  if (!isNative()) return;
  await DrmHost.setAuthorization({ token: token ?? '' });
}

export async function pushDrmHostActiveSlug(slug: string | null | undefined): Promise<void> {
  if (!isNative()) return;
  await DrmHost.setActiveSlug({ slug: slug ?? '' });
}

export async function pushDrmHostApiBase(apiBase: string): Promise<void> {
  if (!isNative()) return;
  await DrmHost.setApiBase({ apiBase });
}
```

Call `pushDrmHostApiBase` and `pushDrmHostAuthorization` after login / token refresh, and `pushDrmHostActiveSlug` when the item about to play is known.

### Swift

```swift
import Capacitor
import Foundation

@objc(DrmHostPlugin)
public class DrmHostPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DrmHostPlugin"
    public let jsName = "DrmHost"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setActiveSlug", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setApiBase", returnType: CAPPluginReturnPromise)
    ]

    @objc func setAuthorization(_ call: CAPPluginCall) {
        DrmHost.setAuthorization(call.getString("token", ""))
        call.resolve()
    }

    @objc func setActiveSlug(_ call: CAPPluginCall) {
        DrmHost.setActiveSlug(call.getString("slug", ""))
        call.resolve()
    }

    @objc func setApiBase(_ call: CAPPluginCall) {
        DrmHost.setApiBase(call.getString("apiBase", ""))
        call.resolve()
    }
}
```

Register after the bridge loads — Capacitor only auto-discovers SPM plugin products:

```swift
import Capacitor

class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(DrmHostPlugin())
    }
}
```

Without that, `registerPlugin('DrmHost')` still creates a JS proxy but `isPluginAvailable('DrmHost')` is false and every call rejects with "DrmHost plugin is not implemented on ios".

### Java

```java
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "DrmHost")
public class DrmHostPlugin extends Plugin {

  @PluginMethod
  public void setAuthorization(PluginCall call) {
    DrmHost.setAuthorization(call.getString("token", ""));
    call.resolve();
  }

  @PluginMethod
  public void setActiveSlug(PluginCall call) {
    DrmHost.setActiveSlug(call.getString("slug", ""));
    call.resolve();
  }

  @PluginMethod
  public void setApiBase(PluginCall call) {
    DrmHost.setApiBase(call.getString("apiBase", ""));
    call.resolve();
  }
}
```

Register **before** `super.onCreate()`:

```java
public class MainActivity extends BridgeActivity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    registerPlugin(DrmHostPlugin.class);
    super.onCreate(savedInstanceState);
  }
}
```

## 3. iOS — `MyFairPlaySession`

Implements both plugins' protocols by wrapping drm-kit's `FairPlaySession`. `open` needs two overloads (one return type per protocol) — Swift will not accept a single covariant-return method for `VideoDrmProvider` and `AudioDrmProvider`.

```swift
import AVFoundation
import Capacitor
import CapacitorVideoPlayerPlugin
import DrmKit
import Foundation
import PlaylistPlugin

public struct MyFairPlaySessionProvider: VideoDrmProvider, AudioDrmProvider {
    public init() {}

    public func open(_ drm: JSObject, onError: @escaping (String) -> Void) -> VideoDrmSession {
        MyFairPlaySession(drm: drm, onError: onError)
    }

    public func open(_ drm: JSObject, onError: @escaping (String) -> Void) -> AudioDrmSession {
        MyFairPlaySession(drm: drm, onError: onError)
    }
}

public final class MyFairPlaySession: VideoDrmSession, AudioDrmSession {
    private let session: FairPlaySession?

    init(drm: JSObject, onError: @escaping (String) -> Void) {
        let token = DrmHost.getAccessToken()
        let apiBase = DrmHost.getApiBase()
        guard !apiBase.isEmpty, !token.isEmpty else {
            onError(VideoDrm.errorNetwork)
            self.session = nil
            return
        }
        let playbackSessionId = Self.string(drm, "playbackSessionId")
        let config = FairPlaySession.Config(
            tokenUrl: DrmHost.tokenUrl(),
            licenseUrl: Self.string(drm, "fairplayLicenseUrl"),
            certificateUrl: Self.string(drm, "fairplayCertificateUrl"),
            heartbeatUrl: DrmHost.heartbeatUrl(playbackSessionId: playbackSessionId),
            playbackSessionId: playbackSessionId,
            renewalCredential: Self.string(drm, "renewalCredential"),
            authorization: { DrmHost.getAccessToken() },
            streamLimit: Self.parseStreamLimit(drm)
        )
        self.session = FairPlaySession(config: config) { error in
            onError(error.rawValue)
        }
    }

    public func attach(to asset: AVURLAsset) {
        session?.addContentKeyRecipient(asset)
    }

    public func start() {
        session?.start()
    }

    public func release() {
        session?.release()
    }

    private static func parseStreamLimit(_ drm: JSObject) -> StreamLimit {
        let streamLimit = drm["streamLimit"] as? JSObject
        var mode = string(streamLimit, "mode")
        if mode.isEmpty {
            mode = StreamLimit.modeNone
        }
        return StreamLimit(
            mode: mode,
            renewalIntervalSeconds: optInt(streamLimit, "renewalIntervalSeconds"),
            heartbeatIntervalSeconds: optInt(streamLimit, "heartbeatIntervalSeconds")
        )
    }

    private static func string(_ obj: JSObject?, _ key: String) -> String {
        (obj?[key] as? String) ?? ""
    }

    private static func optInt(_ obj: JSObject?, _ key: String) -> Int {
        guard let value = obj?[key] else { return 0 }
        if let number = value as? NSNumber { return number.intValue }
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return 0
    }
}
```

Register once at launch:

```swift
import CapacitorVideoPlayerPlugin
import PlaylistPlugin

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let provider = MyFairPlaySessionProvider()
    VideoDrm.setProvider(provider)
    AudioDrm.setProvider(provider)
    return true
}
```

Add drm-kit as an SPM dependency of the **App** target, not a plugin and not `CapApp-SPM`. FairPlay does not work on the simulator.

## 4. Android — `AppWidevineSession`

Same idea: one class implements both plugin sessions and wraps `WidevineSession`.

```java
@UnstableApi
public final class AppWidevineSession implements AudioDrmSession, VideoDrmSession {
  private final WidevineSession session;
  private final DrmSessionManager drmSessionManager;

  public AppWidevineSession(JSObject drm, Consumer<String> onError) {
    String token = DrmHost.getAccessToken();
    String apiBase = DrmHost.getApiBase();
    if (apiBase == null || apiBase.isEmpty() || token == null || token.isEmpty()) {
      if (onError != null) {
        onError.accept("network");
      }
      this.session = null;
      this.drmSessionManager = null;
      return;
    }
    String playbackSessionId = string(drm, "playbackSessionId");
    WidevineSession.Config config = new WidevineSession.Config(
      DrmHost.tokenUrl(),
      string(drm, "widevineLicenseUrl"),
      DrmHost.heartbeatUrl(playbackSessionId),
      playbackSessionId,
      string(drm, "renewalCredential"),
      AppWidevineSession::currentAccessToken,
      parseStreamLimit(drm)
    );
    this.session = new WidevineSession(
      config,
      new WidevineLicenseClient(config),
      new WidevineSession.NativeTaskScheduler(),
      error -> {
        if (onError != null) {
          onError.accept(error.name());
        }
      }
    );
    this.drmSessionManager = new DefaultDrmSessionManager.Builder()
      .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, this.session.createMediaDrmProvider())
      .setMultiSession(true)
      .build(this.session.createMediaDrmCallback());
  }

  @Override
  public void applyDrm(MediaItem.Builder builder) {
    if (session == null) {
      return;
    }
    builder.setDrmConfiguration(new MediaItem.DrmConfiguration.Builder(C.WIDEVINE_UUID).build());
  }

  @Override
  public DrmSessionManager getDrmSessionManager() {
    return drmSessionManager;
  }

  @Override
  public void start() {
    if (session != null) {
      session.start();
    }
  }

  @Override
  public void release() {
    if (session != null) {
      session.release();
    }
    // Do not call DefaultDrmSessionManager.release() here — ExoPlayer owns that.
  }

  private static String currentAccessToken() {
    String token = DrmHost.getAccessToken();
    return token == null ? "" : token;
  }

  private static StreamLimit parseStreamLimit(JSObject drm) {
    JSObject sl = drm != null && drm.has("streamLimit") ? drm.getJSObject("streamLimit") : null;
    String mode = sl != null ? string(sl, "mode") : StreamLimit.MODE_NONE;
    if (mode.isEmpty()) {
      mode = StreamLimit.MODE_NONE;
    }
    return new StreamLimit(mode, optInt(sl, "renewalIntervalSeconds"), optInt(sl, "heartbeatIntervalSeconds"));
  }

  private static String string(JSObject obj, String key) {
    if (obj == null || !obj.has(key) || obj.isNull(key)) {
      return "";
    }
    String value = obj.getString(key);
    return value == null ? "" : value;
  }

  private static int optInt(JSObject obj, String key) {
    if (obj == null || !obj.has(key) || obj.isNull(key)) {
      return 0;
    }
    try {
      Integer value = obj.getInteger(key);
      return value == null ? 0 : value;
    } catch (Exception ignored) {
      return 0;
    }
  }
}
```

Register once in your `Application`:

```java
@UnstableApi
public class App extends Application {
  @Override
  public void onCreate() {
    super.onCreate();
    VideoDrm.setProvider(AppWidevineSession::new);
    AudioDrm.setProvider(AppWidevineSession::new);
  }
}
```

Add drm-kit to the **app** module (`implementation 'com.github.phiamo:drm-kit:…'`), not to a plugin.

## Errors

Provider errors reach the plugins as `blockedByStreamLimit`, `notEntitled`, `expired`, `network`, or `unknown`. Do not auto-retry `blockedByStreamLimit`.
