import Foundation

/// Reads the content KID and IV from a FairPlay key request identifier (the HLS `EXT-X-KEY` URI).
///
/// Accepted KID forms, with or without `skd://` and an optional `:<32-hex IV>` suffix:
/// - 32 hex (what `DrmIdentifiers.fairPlayUri` / the packager write today),
/// - an RFC 4122 GUID (Axinom's documented form, big-endian like `DrmIdentifiers.axinomKeyId`),
/// - base64 / base64url of the 16 KID bytes (Shaka's default when `--hls_key_uri` is omitted).
///
/// The KID always comes from this identifier, never from the SPC.
public enum FairPlayKeyIds {
    public struct KeyUri: Equatable {
        /// 16 KID bytes as 32 lowercase hex (the `/drm-token?kid=` value).
        public let kidHex: String
        /// 16 IV bytes as 32 lowercase hex, when the URI carries one.
        public let ivHex: String?
    }

    public static func parse(_ identifier: String) -> KeyUri? {
        var body = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("skd://") {
            body = String(body.dropFirst("skd://".count))
        }
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let kidHex = kidHex(parts[0]) else { return nil }
        var ivHex: String?
        if parts.count == 2 {
            guard let iv = try? DrmIdentifiers.hexToBytes(parts[1]), iv.count == 16 else { return nil }
            ivHex = DrmIdentifiers.toHex(iv)
        }
        return KeyUri(kidHex: kidHex, ivHex: ivHex)
    }

    /// Content identifier handed to `makeStreamingContentKeyRequestData`; Axinom reads the key URI
    /// from it (UTF-8). `.keyUri` sends the manifest's URI unchanged; `.axinomGuid` rewrites it to
    /// `skd://<KID as GUID>:<IV as 32 hex>` (the form Axinom documents).
    public static func contentIdentifier(
        _ identifier: String,
        form: FairPlaySession.ContentIdentifierForm
    ) -> Data? {
        switch form {
        case .keyUri:
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Data(trimmed.utf8)
        case .axinomGuid:
            guard let parsed = parse(identifier),
                  let kid = try? DrmIdentifiers.hexToBytes(parsed.kidHex) else {
                return nil
            }
            var uri = "skd://" + DrmIdentifiers.axinomKeyId(kid)
            if let iv = parsed.ivHex {
                uri += ":" + iv.uppercased()
            }
            return Data(uri.utf8)
        }
    }

    private static func kidHex(_ value: String) -> String? {
        if value.count == 32, let bytes = try? DrmIdentifiers.hexToBytes(value) {
            return DrmIdentifiers.toHex(bytes)
        }
        if value.count == 36, value.filter({ $0 == "-" }).count == 4,
           let bytes = try? DrmIdentifiers.uuidToBytes(value) {
            return DrmIdentifiers.toHex(bytes)
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        if let bytes = Data(base64Encoded: base64), bytes.count == 16 {
            return DrmIdentifiers.toHex(bytes)
        }
        return nil
    }
}
