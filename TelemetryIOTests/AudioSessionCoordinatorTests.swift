import XCTest
@testable import TelemetryIO

/// Tests ownership and stale async completion with explicitly controlled session operations.
/// Real AVAudioEngine rendering and microphone capture are tested separately.
final class AudioSessionCoordinatorTests: XCTestCase {
    @MainActor
    func testReleasedOwnerDoesNotBecomeReadyAfterInFlightActivationCompletes() async throws {
        let operations = HeldSessionOperations(holdActivation: true)
        let session = coordinator(operations)
        let lease = session.reserve(owner: UUID(), recording: false)
        let readiness = Task { try await session.waitUntilActive(lease) }
        let pending = await waitUntil { await operations.activationPending }
        XCTAssertTrue(pending)
        session.release(lease)
        await operations.openActivation()
        let ready = try await readiness.value
        XCTAssertFalse(ready)
        let settled = await waitUntil { session.isSettled && !session.isActive }
        XCTAssertTrue(settled)
        XCTAssertEqual(session.ownerCount, 0)
        let events = await operations.events
        XCTAssertEqual(events, [.configure(false), .activate, .deactivate], "A completed stale activation must be balanced by deactivation.")
    }

    @MainActor
    func testPendingRecordingOwnerWinsAndReleasingOneOwnerPreservesTheOther() async throws {
        let operations = HeldSessionOperations(holdActivation: true)
        let session = coordinator(operations)
        let output = session.reserve(owner: UUID(), recording: false)
        let outputReady = Task { try await session.waitUntilActive(output) }
        let pending = await waitUntil { await operations.activationPending }
        XCTAssertTrue(pending)
        let input = session.reserve(owner: UUID(), recording: true)
        let inputReady = Task { try await session.waitUntilActive(input) }
        XCTAssertEqual(session.ownerCount, 2)
        XCTAssertEqual(session.recordingOwnerCount, 1)
        await operations.openActivation()
        let readyOutput = try await outputReady.value
        let readyInput = try await inputReady.value
        XCTAssertTrue(readyOutput)
        XCTAssertTrue(readyInput)
        let active = await waitUntil { session.isSettled && session.isActive }
        XCTAssertTrue(active)
        let configured = await operations.events
        XCTAssertTrue(configured.contains(.configure(true)), "The microphone reservation exists before a live engine does.")
        XCTAssertFalse(configured.contains(.deactivate))
        session.release(input)
        let retained = await waitUntil { session.isSettled }
        XCTAssertTrue(retained)
        XCTAssertEqual(session.ownerCount, 1)
        XCTAssertEqual(session.recordingOwnerCount, 0)
        XCTAssertTrue(session.isActive)
        let retainedEvents = await operations.events
        XCTAssertEqual(retainedEvents, configured, "Removing input must not reconfigure or deactivate a surviving oscillator.")
        session.release(output)
        let stopped = await waitUntil { session.isSettled && !session.isActive }
        XCTAssertTrue(stopped)
        let finished = await operations.events
        XCTAssertEqual(finished.filter { $0 == .deactivate }.count, 1)
    }

    @MainActor
    func testAReplacementOwnerCannotBeCancelledByAStaleLease() async throws {
        let operations = HeldSessionOperations(holdActivation: true)
        let session = coordinator(operations)
        let owner = UUID()
        let oldLease = session.reserve(owner: owner, recording: false)
        let oldReady = Task { try await session.waitUntilActive(oldLease) }
        let pending = await waitUntil { await operations.activationPending }
        XCTAssertTrue(pending)
        let currentLease = session.reserve(owner: owner, recording: true)
        let currentReady = Task { try await session.waitUntilActive(currentLease) }
        session.release(oldLease)
        XCTAssertEqual(session.ownerCount, 1)
        XCTAssertEqual(session.recordingOwnerCount, 1)
        await operations.openActivation()
        let obsoleteReady = try await oldReady.value
        let replacementReady = try await currentReady.value
        XCTAssertFalse(obsoleteReady)
        XCTAssertTrue(replacementReady)
        session.release(currentLease)
        let stopped = await waitUntil { session.isSettled && !session.isActive }
        XCTAssertTrue(stopped)
        XCTAssertEqual(session.ownerCount, 0)
    }

    @MainActor
    func testNewOwnerDuringDeactivationIsReactivatedWithItsLatestCategory() async throws {
        let operations = HeldSessionOperations(holdDeactivation: true)
        let session = coordinator(operations)
        let first = session.reserve(owner: UUID(), recording: false)
        let firstReady = try await session.waitUntilActive(first)
        XCTAssertTrue(firstReady)
        session.release(first)
        let pending = await waitUntil { await operations.deactivationPending }
        XCTAssertTrue(pending)
        let replacement = session.reserve(owner: UUID(), recording: true)
        let readiness = Task { try await session.waitUntilActive(replacement) }
        await operations.openDeactivation()
        let ready = try await readiness.value
        XCTAssertTrue(ready)
        let active = await waitUntil { session.isSettled && session.isActive }
        XCTAssertTrue(active)
        XCTAssertEqual(session.ownerCount, 1)
        XCTAssertEqual(session.recordingOwnerCount, 1)
        let events = await operations.events
        XCTAssertEqual(events, [.configure(false), .activate, .deactivate, .configure(true), .activate])
        session.release(replacement)
        let stopped = await waitUntil { session.isSettled && !session.isActive }
        XCTAssertTrue(stopped)
    }

    @MainActor
    func testFailureBeforeWaiterRegistrationIsReturnedWithoutAnImplicitRetry() async {
        let operation = FailingSessionConfiguration()
        let session = AudioSessionCoordinator(
            configure: { _ in try await operation.configure() },
            activate: { true },
            deactivate: { true }
        )
        let lease = session.reserve(owner: UUID(), recording: false)
        let failed = await waitUntil { session.isSettled && session.lastError != nil }
        XCTAssertTrue(failed)
        let initialCalls = await operation.calls
        XCTAssertEqual(initialCalls, 1)
        do {
            _ = try await session.waitUntilActive(lease)
            XCTFail("The reservation's failed activation must reach a late waiter.")
        } catch {
            XCTAssertTrue(error is ControlledSessionFailure)
        }
        let callsAfterWait = await operation.calls
        XCTAssertEqual(callsAfterWait, initialCalls, "Late waiter registration is not a new user request to retry configuration.")
        session.release(lease)
        let released = await waitUntil { session.isSettled && session.ownerCount == 0 }
        XCTAssertTrue(released)
    }

    @MainActor
    func testRecordingUpgradeFailureDoesNotFailAStillValidPlaybackOwner() async throws {
        let operation = FailingRecordingUpgrade()
        let session = AudioSessionCoordinator(
            configure: { try await operation.configure(recording: $0) },
            activate: { true },
            deactivate: { true }
        )
        let output = session.reserve(owner: UUID(), recording: false)
        let readyOutput = try await session.waitUntilActive(output)
        XCTAssertTrue(readyOutput)
        let input = session.reserve(owner: UUID(), recording: true)
        let inputReadiness = Task { try await session.waitUntilActive(input) }
        let pending = await waitUntil { await operation.upgradePending }
        XCTAssertTrue(pending)
        var outputWaiterStarted = false
        let outputReadiness = Task {
            outputWaiterStarted = true
            return try await session.waitUntilActive(output)
        }
        let registered = await waitUntil { outputWaiterStarted }
        XCTAssertTrue(registered)
        await operation.failUpgrade()
        do {
            _ = try await inputReadiness.value
            XCTFail("The incompatible recording configuration must fail its own input intent.")
        } catch { XCTAssertTrue(error is ControlledSessionFailure) }
        do {
            let playbackReady = try await outputReadiness.value
            XCTAssertTrue(playbackReady)
        } catch {
            XCTFail("A failed input upgrade must not poison the existing usable playback owner: \(error)")
        }
        XCTAssertTrue(session.isActive)
        session.release(input)
        session.release(output)
        let released = await waitUntil { session.isSettled && !session.isActive }
        XCTAssertTrue(released)
    }

    @MainActor
    private func coordinator(_ operations: HeldSessionOperations) -> AudioSessionCoordinator {
        AudioSessionCoordinator(
            configure: { await operations.configure(recording: $0) },
            activate: { await operations.activate() },
            deactivate: { await operations.deactivate() }
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private enum ControlledSessionFailure: Error { case configuration }

private actor FailingSessionConfiguration {
    private(set) var calls = 0
    func configure() throws {
        calls += 1
        throw ControlledSessionFailure.configuration
    }
}

private actor FailingRecordingUpgrade {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    var upgradePending: Bool { waiter != nil }
    func configure(recording: Bool) async throws {
        guard recording else { return }
        if !released { await withCheckedContinuation { waiter = $0 } }
        throw ControlledSessionFailure.configuration
    }
    func failUpgrade() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor HeldSessionOperations {
    enum Operation: Equatable, Sendable {
        case configure(Bool), activate, deactivate
    }
    private(set) var events: [Operation] = []
    private var holdActivation: Bool
    private var holdDeactivation: Bool
    private var activationWaiter: CheckedContinuation<Void, Never>?
    private var deactivationWaiter: CheckedContinuation<Void, Never>?
    var activationPending: Bool { activationWaiter != nil }
    var deactivationPending: Bool { deactivationWaiter != nil }

    init(holdActivation: Bool = false, holdDeactivation: Bool = false) {
        self.holdActivation = holdActivation
        self.holdDeactivation = holdDeactivation
    }
    func configure(recording: Bool) { events.append(.configure(recording)) }
    func activate() async -> Bool {
        events.append(.activate)
        if holdActivation { await withCheckedContinuation { activationWaiter = $0 } }
        return true
    }
    func deactivate() async -> Bool {
        events.append(.deactivate)
        if holdDeactivation { await withCheckedContinuation { deactivationWaiter = $0 } }
        return true
    }
    func openActivation() {
        holdActivation = false
        activationWaiter?.resume()
        activationWaiter = nil
    }
    func openDeactivation() {
        holdDeactivation = false
        deactivationWaiter?.resume()
        deactivationWaiter = nil
    }
}
