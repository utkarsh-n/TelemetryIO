import SwiftUI

struct PeerRangingView: View {
    let model: InstrumentModel
    @State private var peerToken = ""
    @FocusState private var tokenFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "sensor.tag.radiowaves.forward").font(.largeTitle).foregroundStyle(IOTheme.violet)
                    Text("Measure a real peer.").font(.system(.title, design: .serif))
                    Text("Open Telemetry I/O on two supported iPhones. Share each phone's session token with the other, paste the received token, then connect on both phones. Keep both apps in the foreground.").font(.subheadline).foregroundStyle(IOTheme.muted)
                    VStack(alignment: .leading, spacing: 12) {
                        SectionEyebrow(number: "01", title: "THIS PHONE")
                        Text(model.hub.nearbyProbe.supported ? "Precise ranging supported" : "Precise ranging unavailable on this device").font(.subheadline)
                        Button("Prepare session", systemImage: "sensor.tag.radiowaves.forward") { model.hub.enable("peer") }.buttonStyle(.glassProminent).disabled(!model.hub.nearbyProbe.supported || model.hub.isDemo || model.paused).accessibilityIdentifier("peer-prepare")
                        if !model.hub.nearbyProbe.sharingToken.isEmpty {
                            ShareLink(item: model.hub.nearbyProbe.sharingToken) { Label("Share my session token", systemImage: "square.and.arrow.up") }.buttonStyle(.glass)
                        }
                    }.instrumentPanel()
                    VStack(alignment: .leading, spacing: 12) {
                        SectionEyebrow(number: "02", title: "OTHER PHONE")
                        TextField("Paste the other phone's session token", text: $peerToken, axis: .vertical).lineLimit(3...5).font(.system(.caption, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().focused($tokenFocused).padding(12).background(IOTheme.well, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("peer-token")
                        Button("Connect to peer", systemImage: "link") {
                            tokenFocused = false
                            model.hub.nearbyProbe.connect(token: peerToken)
                        }.buttonStyle(.glassProminent).disabled(peerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.hub.isDemo || model.paused).accessibilityIdentifier("peer-connect")
                        Button("Stop ranging", systemImage: "stop.fill") {
                            tokenFocused = false
                            model.hub.disable("peer")
                        }.buttonStyle(.glass).accessibilityIdentifier("peer-stop")
                    }.instrumentPanel()
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.hub.reading("uwb.distance").definition.formatted(model.hub.reading("uwb.distance").value)).font(.system(.largeTitle, design: .monospaced)); Text("m").foregroundStyle(IOTheme.muted); Spacer(); StatusBadge(status: model.hub.reading("uwb.distance").status)
                    }
                    Text(model.hub.nearbyProbe.status).font(.subheadline)
                    if let error = model.hub.nearbyProbe.error { Text(error).font(.caption).foregroundStyle(IOTheme.rose) }
                    if model.paused { Text("Resume capture before starting a peer session.").font(.caption).foregroundStyle(IOTheme.amber) }
                    if model.hub.isDemo { Text("Switch off Demo to use real ranging.").font(.caption).foregroundStyle(IOTheme.amber) }
                    Text("Tokens belong to the current session and expire when it stops. Nearby Interaction reports distance only when the peer participates; it cannot track arbitrary nearby phones or AirTags.").font(.caption).foregroundStyle(IOTheme.muted)
                }.padding(20)
            }
            .accessibilityIdentifier("peer-scroll")
            .scrollDismissesKeyboard(.interactively)
            .background(IOTheme.background)
            .navigationTitle("UWB peer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { tokenFocused = false }
                        .accessibilityLabel("Dismiss keyboard")
                        .accessibilityIdentifier("peer-dismiss-keyboard")
                }
            }
        }
    }
}
