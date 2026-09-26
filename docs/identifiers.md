# Key IDs and identifiers

`DrmIdentifiers` (Swift and Kotlin) converts between the formats that the playback API, the packager and the players use: hex, bytes, UUIDs, the FairPlay `skd://` URI, and Axinom key ids and values. Both platforms are checked against the same test vector (`testdata/identifiers-test-vector.json`).

## KID for `/drm-token`

`kid` must be the 32-hex `content_key.kid` (same bytes as HLS `#EXT-X-KEY` / Shaka `keyId`). Backend `TokenService` looks that hex up; anything else is `403 Unknown content key`.

| Surface | KID source | Status |
| --- | --- | --- |
| Web PWA (`web-drm-hls.ts`) | hls.js `keyContext.keyId` | Correct |
| Catalog Twig (`web-drm-hls.js`) | same HLS `keyId` | Correct |
| Android (`WidevineKeyIds.firstKeyId`) | Widevine PSSH / LicenseRequest **content_id**, never ClientIdentification | Fixed in this tree — do not take the first protobuf field 2 of length 16 (that is often a 16-byte client blob) |
| iOS FairPlay (`v0.3.0`) | HLS `skd://kid:iv` via `DrmIdentifiers.fairPlayUri` — not the SPC blob | Not implemented yet; same hex as web |

**Later (same repo, later tags):** FairPlay `AVContentKeySession` (`v0.3.0`, Story 58.2), offline / persistable keys (`v0.4.0` / `v0.5.0`, Epic 59). `1.0.0` waits for the DRM release.

The Android `WidevineKeyIds` reads the content KID from the PSSH / LicenseRequest `content_id`, not from ClientIdentification. Do not add a second KID mapping.
