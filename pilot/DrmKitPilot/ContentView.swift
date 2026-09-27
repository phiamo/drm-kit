import AVKit
import DrmKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = PilotModel()

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Source")) {
                    TextField("API base", text: $model.apiBase)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Slug", text: $model.slug)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("Bearer (SSO access token)", text: $model.bearer)
                    Button("Fetch descriptor") {
                        Task { await model.fetchDescriptor() }
                    }
                }
                Section(header: Text("Descriptor JSON")) {
                    TextEditor(text: $model.descriptorJson)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                }
                Section(header: Text("Key URI sent to Axinom")) {
                    Picker("Content identifier", selection: $model.form) {
                        ForEach(FairPlaySession.ContentIdentifierForm.allCases, id: \.self) { form in
                            Text(form.rawValue).tag(form)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button("Play") { model.play() }
                    Button("Stop") { model.stop() }
                }
                if let player = model.player {
                    Section(header: Text("Player")) {
                        VideoPlayer(player: player)
                            .frame(height: 220)
                    }
                }
                Section(header: Text("Requests this playback")) {
                    Text("certificate \(model.counts.certificate) · token \(model.counts.token) · license \(model.counts.license) · heartbeat \(model.counts.heartbeat)")
                        .font(.footnote)
                    ForEach(model.keyIdentifiers, id: \.self) { identifier in
                        Text(identifier).font(.system(.caption2, design: .monospaced))
                    }
                }
                Section(header: Text("Log")) {
                    ForEach(Array(model.log.enumerated().reversed()), id: \.offset) { entry in
                        Text(entry.element).font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            .navigationTitle("drm-kit FairPlay pilot")
        }
        .navigationViewStyle(.stack)
    }
}
