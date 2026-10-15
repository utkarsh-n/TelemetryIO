import CoreNFC
import Foundation
import Observation

/// A person starts each foreground NDEF scan. Only record counts and format classes survive
/// the delegate callback; payloads, identifiers, and URI contents are never retained.
@MainActor @Observable
final class NFCProbe: NSObject, NFCNDEFReaderSessionDelegate {
    var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }
    private(set) var isReading = false
    private(set) var readCount = 0
    private(set) var lastSummary = "No NDEF tag read in this session."
    private(set) var error: String?
    @ObservationIgnored var onRead: ((Int, String) -> Void)?
    @ObservationIgnored private var session: NFCNDEFReaderSession?
    @ObservationIgnored private var sessionIdentifier: ObjectIdentifier?

    func start() {
        guard !isReading else { return }
        error = nil
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NFCReaderUsageDescription") as? String,
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "NFC reading requires a non-empty NFCReaderUsageDescription in this app's Info.plist."
            return
        }
        guard isAvailable else {
            error = "NFC reading is unavailable on this device or simulator. A supported phone and NFC reader entitlement are required."
            return
        }
        let reader = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        reader.alertMessage = "Hold an NDEF tag near the top of your iPhone. Telemetry I/O reads its record count and format only."
        session = reader
        sessionIdentifier = ObjectIdentifier(reader)
        isReading = true
        reader.begin()
    }

    func stop() {
        let reader = session
        session = nil
        sessionIdentifier = nil
        isReading = false
        reader?.invalidate()
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let identifier = ObjectIdentifier(session)
        let records = messages.flatMap(\.records)
        let recordCount = records.count
        let formats = Set(records.map { Self.formatName($0.typeNameFormat) }).sorted().joined(separator: ", ")
        let summary = "\(recordCount) NDEF record\(recordCount == 1 ? "" : "s")" + (formats.isEmpty ? "" : " · \(formats)")
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.readCount += 1
            self.lastSummary = summary
            self.onRead?(self.readCount, summary)
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: any Error) {
        let identifier = ObjectIdentifier(session)
        let readerError = error as? NFCReaderError
        let completedRead = readerError?.code == .readerSessionInvalidationErrorFirstNDEFTagRead
        let reason: String?
        switch readerError?.code {
        case .readerSessionInvalidationErrorUserCanceled, .readerSessionInvalidationErrorFirstNDEFTagRead:
            reason = nil
        case .readerErrorSecurityViolation:
            reason = "NFC access requires the NDEF reader entitlement in this app's provisioning profile. Enable NFC Tag Reading with an eligible Apple Developer team."
        case .readerSessionInvalidationErrorSessionTimeout:
            reason = "The scan timed out. Start another scan and hold an NDEF tag near the top of the phone."
        default:
            reason = error.localizedDescription
        }
        Task { @MainActor [weak self] in
            guard let self, self.sessionIdentifier == identifier else { return }
            self.session = nil
            // Keep the identifier until the pending successful-read callback is applied.
            // Delegate tasks and invalidation tasks need not enter the main actor in order.
            if !completedRead { self.sessionIdentifier = nil }
            self.isReading = false
            self.error = reason
        }
    }

    private nonisolated static func formatName(_ format: NFCTypeNameFormat) -> String {
        switch format {
        case .empty: "empty"
        case .nfcWellKnown: "well-known"
        case .media: "MIME"
        case .absoluteURI: "absolute URI"
        case .nfcExternal: "external"
        case .unknown: "unknown"
        case .unchanged: "unchanged"
        @unknown default: "other"
        }
    }
}
