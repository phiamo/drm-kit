# Key IDs and identifiers

`DrmIdentifiers` (Swift and Kotlin) converts between the formats that the playback API, the packager and the players use: hex, bytes, UUIDs, the FairPlay `skd://` URI, and Axinom key ids and values. Both platforms are checked against the same test vector (`testdata/identifiers-test-vector.json`).

## KID for `/drm-token`

`kid` must be the 32-hex `content_key.kid` (same bytes as HLS `#EXT-X-KEY` / Shaka `keyId`). Backend `TokenService` looks that hex up; anything else is `403 Unknown content key`.

| Surface | KID source |
| --- | --- |
| Web PWA (`web-drm-hls.ts`) | hls.js `keyContext.keyId` |
| Catalog Twig (`web-drm-hls.js`) | same HLS `keyId` |
| Android (`WidevineKeyIds.firstKeyId`) | Widevine PSSH / LicenseRequest `content_id`, never ClientIdentification. Do not take the first protobuf field 2 of length 16: that is often a 16-byte client blob |
| iOS FairPlay (`FairPlayKeyIds.parse`) | Key request identifier `skd://<kid>[:<iv>]` (hex, GUID or base64 KID), never the SPC. Same hex as web |

Do not add a second KID mapping.
