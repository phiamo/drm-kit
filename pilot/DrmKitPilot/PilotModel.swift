import AVFoundation
import DrmKit
import Foundation

/// Story 58.2 pilot: plays one protected descriptor with `FairPlaySession` on a physical device and
/// records what the pilot must answer (key-URI form, license requests per playback).
/// Never logs the bearer, tokens, SPCs or CKCs.
@MainActor
final class PilotModel: ObservableObject {
    @Published var apiBase = "https://awareness.ferrix.dwbn.org/api/v2"
    @Published var slug = "test-1"
    @Published var bearer = ""
    @Published var descriptorJson = ""
    @Published var form: FairPlaySession.ContentIdentifierForm = .keyUri
    @Published private(set) var player: AVPlayer?
    @Published private(set) var log: [String] = []
    @Published private(set) var counts = FairPlayLicenseClient.RequestCounts()
    @Published private(set) var keyIdentifiers: [String] = []

    private var session: FairPlaySession?
    private var statusObservation: NSKeyValueObservation?
    private var refreshTimer: Timer?

    struct Descriptor: Decodable {
        struct Limit: Decodable {
            let mode: String
            let renewalIntervalSeconds: Int
            let heartbeatIntervalSeconds: Int
        }

        let type: String?
        let manifestUrl: String?
        let fairplayLicenseUrl: String
        let fairplayCertificateUrl: String
        let playbackSessionId: String
        let renewalCredential: String
        let streamLimit: Limit
    }

    func fetchDescriptor() async {
        guard let url = URL(string: "\(trimmedApiBase)/assets/\(slug)/playback") else {
            append("invalid API base or slug")
            return
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            append("descriptor GET → HTTP \(status)")
            if (200..<300).contains(status) {
                descriptorJson = String(data: data, encoding: .utf8) ?? ""
            }
        } catch {
            append("descriptor GET failed: \(error.localizedDescription)")
        }
    }

    func play() {
        stop()
        let descriptor: Descriptor
        do {
            descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(descriptorJson.utf8))
        } catch {
            append("descriptor JSON invalid: \(error.localizedDescription)")
            return
        }
        guard descriptor.type == nil || descriptor.type == "drm",
              let manifest = descriptor.manifestUrl.flatMap(URL.init(string:)) else {
            append("descriptor has no DRM manifestUrl")
            return
        }
        guard !descriptor.fairplayCertificateUrl.isEmpty else {
            append("fairplayCertificateUrl is empty (58.1 not live?)")
            return
        }
        let bearerValue = bearer
        let config = FairPlaySession.Config(
            tokenUrl: "\(trimmedApiBase)/assets/\(slug)/drm-token",
            licenseUrl: descriptor.fairplayLicenseUrl,
            certificateUrl: descriptor.fairplayCertificateUrl,
            heartbeatUrl: "\(trimmedApiBase)/playback-sessions/\(descriptor.playbackSessionId)/heartbeat",
            playbackSessionId: descriptor.playbackSessionId,
            renewalCredential: descriptor.renewalCredential,
            authorization: { bearerValue },
            streamLimit: StreamLimit(
                mode: descriptor.streamLimit.mode,
                renewalIntervalSeconds: descriptor.streamLimit.renewalIntervalSeconds,
                heartbeatIntervalSeconds: descriptor.streamLimit.heartbeatIntervalSeconds
            ),
            contentIdentifierForm: form
        )
        let session = FairPlaySession(config: config) { [weak self] error in
            Task { @MainActor in self?.append("onError: \(error.rawValue)") }
        }
        self.session = session
        append("play \(slug) mode=\(descriptor.streamLimit.mode) form=\(form.rawValue) \(Self.deviceSummary())")

        let asset = AVURLAsset(url: manifest)
        session.addContentKeyRecipient(asset)
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error.map { " error=\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? ""
            Task { @MainActor in
                self?.append("item status=\(status.rawValue)\(message)")
            }
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        session.start()
        player.play()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        statusObservation = nil
        player?.pause()
        player = nil
        if let session {
            refresh()
            append("stop: certificate=\(counts.certificate) token=\(counts.token) license=\(counts.license) heartbeat=\(counts.heartbeat) keys=\(keyIdentifiers)")
            session.release()
        }
        session = nil
    }

    private func refresh() {
        guard let session else { return }
        counts = session.client.requestCounts
        keyIdentifiers = session.keyIdentifiers
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log.append("\(stamp) \(line)")
    }

    private var trimmedApiBase: String {
        apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private var authorizationHeader: String {
        bearer.hasPrefix("Bearer ") ? bearer : "Bearer \(bearer)"
    }

    private static func deviceSummary() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(machine) iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
