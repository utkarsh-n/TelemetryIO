import Foundation
import NearbyInteraction
import Observation
import simd

/// Ranges one participating peer after both people exchange this session's discovery token.
/// Tokens are ephemeral secure archives; no background discovery or arbitrary UWB scanning.
@MainActor @Observable
final class NearbyProbe: NSObject, NISessionDelegate {
    var supported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        #endif
    }
    private(set) var sharingToken = ""
    private(set) var status = "Prepare a token, then exchange it with a nearby compatible iPhone."
    private(set) var error: String?
    private(set) var distance: Double?
    private(set) var direction: SIMD3<Float>?
    private(set) var running = false
    @ObservationIgnored var onUpdate: ((Double?, SIMD3<Float>?, String) -> Void)?
    @ObservationIgnored private var session: NISession?
    @ObservationIgnored private var sessionIdentifier: ObjectIdentifier?

    func prepare() {
        guard session == nil else { return }
        error = nil
        guard supported else {
            status = "Precise Nearby Interaction ranging is unavailable on this device."
            error = status
            publish()
            return
        }
        let newSession = NISession()
        newSession.delegate = self
        newSession.delegateQueue = .main
        guard let token = newSession.discoveryToken else {
            newSession.invalidate()
            status = "The system has not provided a discovery token. Try preparing again."
            error = status
            publish()
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            sharingToken = data.base64EncodedString()
            session = newSession
            sessionIdentifier = ObjectIdentifier(newSession)
            status = "Share this token, paste the peer's token, and connect on both phones."
            publish()
        } catch {
            newSession.invalidate()
            self.error = "The system discovery token could not be securely encoded."
            status = self.error!
            publish()
        }
    }

    func connect(token: String) {
        error = nil
        let cleaned = token.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleaned.isEmpty, cleaned.utf8.count <= 65_536,
              let data = Data(base64Encoded: cleaned), !data.isEmpty, data.count <= 32_768 else {
            error = "Paste the complete base64 discovery token from the other phone."
            status = error!
            publish()
            return
        }
        let peer: NIDiscoveryToken
        do {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
                error = "This archive is not a Nearby Interaction discovery token."
                status = error!
                publish()
                return
            }
            peer = decoded
        } catch {
            self.error = "The peer token is invalid or cannot be securely decoded. Prepare a fresh token on the other phone."
            status = self.error!
            publish()
            return
        }
        prepare()
        guard let session else { return }
        guard session.discoveryToken != peer else {
            error = "This is your own token. Use the token shared by the other phone."
            status = error!
            publish()
            return
        }
        distance = nil
        direction = nil
        running = false
        status = "Waiting for a measured range. Both phones must connect using each other's tokens."
        publish()
        session.run(NINearbyPeerConfiguration(peerToken: peer))
    }

    func stop() {
        let oldSession = session
        session = nil
        sessionIdentifier = nil
        oldSession?.delegate = nil
        oldSession?.invalidate()
        sharingToken = ""
        running = false
        distance = nil
        direction = nil
        error = nil
        status = "Session stopped. Prepare and exchange new tokens to range again."
        publish()
    }

    private func publish() { onUpdate?(distance, direction, status) }

    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let identifier = ObjectIdentifier(session)
        guard let object = nearbyObjects.first else { return }
        let measuredDistance = object.distance.flatMap { $0.isFinite && $0 >= 0 ? Double($0) : nil }
        let measuredDirection = object.direction.flatMap {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite ? $0 : nil
        }
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.distance = measuredDistance
            self.direction = measuredDirection
            self.running = true
            self.error = nil
            self.status = measuredDistance == nil ? "Peer active; distance is not yet available. Keep both phones nearby and unobstructed." : "Measured peer range. Direction may be unavailable on this peer."
            self.publish()
        }
    }

    nonisolated func sessionDidStartRunning(_ session: NISession) {
        let identifier = ObjectIdentifier(session)
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.running = true
            if self.distance == nil { self.status = "Session active; waiting for the peer to range." }
            self.publish()
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        let identifier = ObjectIdentifier(session)
        let message = reason == .peerEnded ? "The peer ended its session. Exchange its fresh token to reconnect." : "The peer timed out. Keep both apps open and reconnect."
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.running = false
            self.distance = nil
            self.direction = nil
            self.status = message
            self.publish()
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        let identifier = ObjectIdentifier(session)
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.running = false
            self.distance = nil
            self.direction = nil
            self.status = "Nearby Interaction is suspended. Return to the foreground before reconnecting."
            self.publish()
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        let identifier = ObjectIdentifier(session)
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.status = "Session is available again. Reconnect with the peer's current token."
            self.publish()
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: any Error) {
        let identifier = ObjectIdentifier(session)
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.session = nil
            self.sessionIdentifier = nil
            self.sharingToken = ""
            self.running = false
            self.distance = nil
            self.direction = nil
            self.error = message
            self.status = "Session ended: \(message) Prepare a new token before reconnecting."
            self.publish()
        }
    }
}
