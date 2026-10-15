import AVFoundation
import Foundation

/// The microphone and oscillator share one process-wide audio session. A reservation
/// counts while activation is pending, so a playback request cannot downgrade input.
@MainActor final class AudioSessionCoordinator {
    struct Reservation: Hashable, Sendable {
        fileprivate let owner: UUID
        fileprivate let token: UUID
        fileprivate let recording: Bool
    }

    static let shared = AudioSessionCoordinator()

    private let configure: @Sendable (Bool) async throws -> Void
    private let activate: @Sendable () async throws -> Bool
    private let deactivate: @Sendable () async throws -> Bool
    private var owners: [UUID: Reservation] = [:]
    private var waiters: [UUID: CheckedContinuation<Bool, any Error>] = [:]
    private var failures: [UUID: any Error] = [:]
    private var readyTokens: Set<UUID> = []
    private var worker: Task<Void, Never>?
    private var recordingConfigured = false
    private var interrupted = false
    private var observers: [NotificationCenter.ObservationToken] = []
    private(set) var isActive = false
    private(set) var lastError: String?

    var ownerCount: Int { owners.count }
    var recordingOwnerCount: Int { eligibleOwners.filter(\.recording).count }
    var isSettled: Bool { worker == nil }
    private var eligibleOwners: [Reservation] { owners.values.filter { failures[$0.token] == nil } }

    private convenience init() {
        let configuration = AudioSessionConfiguration()
        self.init(configure: { try await configuration.configure(recording: $0) },
                  activate: { try await configuration.activate() },
                  deactivate: { try await configuration.deactivate() })
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        observers.append(center.addObserver(of: session, for: .didBecomeInactive) { [weak self] (message: AVAudioSession.DidBecomeInactiveMessage) in
            // Our async deactivation is already serialized by reconcile(). Its
            // notification must not invalidate a newer reservation or activation.
            guard let self, case .systemInterruption = message.deactivationResult else { return }
            self.isActive = false
            self.interrupted = true
        })
        observers.append(center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] (message: AVAudioSession.ResumptionRecommendationMessage) in
            guard let self else { return }
            // The interruption has ended. Each owner honors shouldNotResume for
            // automatic restart; an explicit later enable must still be possible.
            self.interrupted = false
            self.reconcileIfNeeded()
        })
    }

    /// Injectable operations let lifecycle tests hold an activation in flight without
    /// replacing the production AVAudioEngine callback or requesting permissions.
    init(configure: @escaping @Sendable (Bool) async throws -> Void,
         activate: @escaping @Sendable () async throws -> Bool,
         deactivate: @escaping @Sendable () async throws -> Bool) {
        self.configure = configure
        self.activate = activate
        self.deactivate = deactivate
    }

    func reserve(owner: UUID, recording: Bool) -> Reservation {
        let reservation = Reservation(owner: owner, token: UUID(), recording: recording)
        if let previous = owners.updateValue(reservation, forKey: owner) {
            waiters.removeValue(forKey: previous.token)?.resume(returning: false)
            failures.removeValue(forKey: previous.token)
            readyTokens.remove(previous.token)
        }
        lastError = nil
        reconcileIfNeeded()
        return reservation
    }

    func waitUntilActive(_ reservation: Reservation) async throws -> Bool {
        guard owners[reservation.owner] == reservation else { return false }
        if let error = failures[reservation.token] { throw error }
        if isActive, !interrupted, worker == nil, !reservation.recording || recordingConfigured { return true }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[reservation.token] = continuation
            reconcileIfNeeded()
        }
    }

    func release(_ reservation: Reservation) {
        guard owners[reservation.owner] == reservation else { return }
        owners.removeValue(forKey: reservation.owner)
        waiters.removeValue(forKey: reservation.token)?.resume(returning: false)
        failures.removeValue(forKey: reservation.token)
        readyTokens.remove(reservation.token)
        reconcileIfNeeded()
    }

    private func reconcileIfNeeded() {
        guard worker == nil, !interrupted else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.reconcile()
        }
    }

    private func reconcile() async {
        defer { worker = nil }
        do {
            while !interrupted {
                if eligibleOwners.isEmpty {
                    if isActive {
                        guard try await deactivate() else { throw SessionError.deactivationFailed }
                        isActive = false
                    }
                    // Recompute after every await: an owner may have arrived during deactivation.
                    if eligibleOwners.isEmpty { recordingConfigured = false; return }
                    continue
                }

                // Keep a recording-capable category until all owners stop. Disabling
                // only the mic must not reconfigure a running oscillator unnecessarily.
                let recording = recordingOwnerCount > 0 || (isActive && recordingConfigured)
                if !isActive || recording != recordingConfigured {
                    try await configure(recording)
                    recordingConfigured = recording
                    if interrupted { return }
                    if eligibleOwners.isEmpty { continue }
                    if recordingOwnerCount > 0, !recordingConfigured { continue }
                    do {
                        guard try await activate() else { throw SessionError.activationFailed }
                    } catch {
                        isActive = false
                        throw error
                    }
                    if interrupted { isActive = false; return }
                    isActive = true
                    if eligibleOwners.isEmpty { continue }
                    if recordingOwnerCount > 0, !recordingConfigured { continue }
                }

                let ready = eligibleOwners.filter { !$0.recording || recordingConfigured }
                for reservation in ready {
                    readyTokens.insert(reservation.token)
                    waiters.removeValue(forKey: reservation.token)?.resume(returning: true)
                }
                return
            }
        } catch {
            lastError = error.localizedDescription
            // A worker may fail before its caller's Task installs a waiter. Retain
            // that failure for this exact intent; a fresh reserve is the retry.
            for reservation in eligibleOwners {
                let stillReady = isActive && !interrupted && readyTokens.contains(reservation.token) && (!reservation.recording || recordingConfigured)
                if stillReady {
                    waiters.removeValue(forKey: reservation.token)?.resume(returning: true)
                } else {
                    failures[reservation.token] = error
                    readyTokens.remove(reservation.token)
                    waiters.removeValue(forKey: reservation.token)?.resume(throwing: error)
                }
            }
        }
    }

    private enum SessionError: LocalizedError {
        case activationFailed, deactivationFailed
        var errorDescription: String? {
            switch self {
            case .activationFailed: "The audio session did not activate."
            case .deactivationFailed: "The audio session did not deactivate."
            }
        }
    }
}

/// Every potentially blocking session mutation uses one serial background queue.
/// The setActive path is awaited without blocking MainActor. Runtime checks on
/// iOS 27 Simulator found native async activation returned without a usable RemoteIO input.
private final class AudioSessionConfiguration: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TelemetryIO.audio-session")

    func configure(recording: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    let category: AVAudioSession.Category = recording ? .playAndRecord : .playback
                    let options: AVAudioSession.CategoryOptions = recording ? [.mixWithOthers, .defaultToSpeaker] : [.mixWithOthers]
                    if session.category != category || session.mode != .default || session.categoryOptions != options {
                        try session.setCategory(category, mode: .default, options: options)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func activate() async throws -> Bool { try await setActive(true) }
    func deactivate() async throws -> Bool { try await setActive(false) }

    private func setActive(_ active: Bool) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if active { try session.setActive(true) }
                    else { try session.setActive(false, options: [.notifyOthersOnDeactivation]) }
                    continuation.resume(returning: true)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
