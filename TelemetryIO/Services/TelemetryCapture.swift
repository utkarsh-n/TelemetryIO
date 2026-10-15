import AVFoundation
import Accelerate
import Foundation

/// One-slot mailbox: capture callbacks never queue unbounded UI work.
final class TelemetryMailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func put(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func take() -> Value? { lock.lock(); defer { lock.unlock() }; let latest = value; value = nil; return latest }
    func clear() { lock.lock(); value = nil; lock.unlock() }
}

struct TelemetryAudioPacket: Sendable {
    var rms: Double
    var peak: Double
    var frequency: Double?
    var waveform: [Double]
    var spectrum: [Double]
    var sampleRate: Double
    var generation: Int = 0
}

/// Owned by the audio tap. No UI state or actor-isolated closure is used on its thread.
final class TelemetryAudioAnalyzer: @unchecked Sendable {
    let mailbox: TelemetryMailbox<TelemetryAudioPacket>
    private let generation: Int
    private let size = 2048
    private let logSize: vDSP_Length = 11
    private let setup: FFTSetup?
    private var pending: [Float] = []
    private var window = [Float](repeating: 0, count: 2048)
    private var real = [Float](repeating: 0, count: 1024)
    private var imaginary = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)

    init(mailbox: TelemetryMailbox<TelemetryAudioPacket>, generation: Int = 0) {
        self.mailbox = mailbox
        self.generation = generation
        setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        pending.reserveCapacity(size * 2)
    }
    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    func consume(_ samples: [Float], rate: Double) {
        guard rate.isFinite, rate >= 40, !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return }
        pending.append(contentsOf: samples)
        guard pending.count >= size else { return }
        // Keep the latest complete window even if the system supplied an unusually large buffer.
        let values = Array(pending.suffix(size))
        pending.removeAll(keepingCapacity: true)
        var sum = 0.0, total = 0.0, peak = 0.0
        for value in values { let x = Double(value); sum += x * x; total += x; peak = max(peak, abs(x)) }
        let rmsAmplitude = sqrt(sum / Double(size))
        let rms = max(-80, 20 * log10(max(0.000_000_1, rmsAmplitude)))
        let peakDB = max(-80, 20 * log10(max(0.000_000_1, peak)))
        var frequency: Double?
        var bands = [Double](repeating: 0, count: 48)
        if let setup {
            // A constant ADC offset is not a tone. Remove DC before windowing so its
            // Hann sidelobe cannot masquerade as the first nonzero frequency bin.
            let mean = Float(total / Double(size))
            var weighted = values.map { $0 - mean }
            vDSP_vmul(weighted, 1, window, 1, &weighted, 1, vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    weighted.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, logSize, FFTDirection(FFT_FORWARD))
                    // Packed imaginary[0] is the Nyquist term, not the imaginary DC component.
                    split.imagp[0] = 0
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
                }
            }
            let maxHz = min(8000, rate * 0.48)
            let lower = max(1, Int(20 * Double(size) / rate))
            let upper = min(size / 2 - 1, Int(maxHz * Double(size) / rate))
            if rms > -65, upper > lower, let bin = (lower...upper).max(by: { magnitudes[$0] < magnitudes[$1] }) {
                let amplitude = sqrt(Double(magnitudes[bin])) / Double(size)
                if amplitude > pow(10, -65.0 / 20) { frequency = Double(bin) * rate / Double(size) }
            }
            for band in bands.indices {
                let loHz = 20 * pow(maxHz / 20, Double(band) / Double(bands.count))
                let hiHz = 20 * pow(maxHz / 20, Double(band + 1) / Double(bands.count))
                let lo = max(1, min(size / 2 - 1, Int(loHz * Double(size) / rate)))
                let hi = max(lo, min(size / 2 - 1, Int(hiHz * Double(size) / rate)))
                let energy = (lo...hi).map { Double(magnitudes[$0]) }.max() ?? 0
                let amplitude = sqrt(energy) / Double(size)
                let db = 20 * log10(max(0.000_000_1, amplitude))
                bands[band] = min(1, max(0, (db + 80) / 80))
            }
        }
        let scope = (0..<192).map { Double(values[$0 * (size - 1) / 191]) }
        mailbox.put(TelemetryAudioPacket(rms: rms, peak: peakDB, frequency: frequency, waveform: scope, spectrum: bands, sampleRate: rate, generation: generation))
    }

    nonisolated static func tap(_ analyzer: TelemetryAudioAnalyzer) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            let count = buffer.frameLength
            let stride = max(1, buffer.stride)
            guard count > 0 else { return }
            var samples = [Float](repeating: 0, count: count)
            switch buffer.channelData(0) {
            case .float(let span):
                for i in 0..<count where i * stride < span.count { samples[i] = span[i * stride] }
            case .int16(let span):
                for i in 0..<count where i * stride < span.count { samples[i] = Float(span[i * stride]) / 32768 }
            case .int32(let span):
                for i in 0..<count where i * stride < span.count { samples[i] = Float(span[i * stride]) / 2_147_483_648 }
            @unknown default: return
            }
            analyzer.consume(samples, rate: buffer.format.sampleRate)
        }
    }
}

struct TelemetryCameraPacket: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let luma: Double
    let iso: Double
    let exposure: Double
    let generation: Int
}

/// The camera queue owns session mutation, measurement and teardown. Images are never retained.
final class TelemetryCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TelemetryIO.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var configured = false
    private var lastFrameTime = -Double.infinity
    private var generation = 0
    private let mailbox: TelemetryMailbox<TelemetryCameraPacket>

    init(mailbox: TelemetryMailbox<TelemetryCameraPacket>) { self.mailbox = mailbox; super.init() }

    func start(generation: Int = 0, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            self.generation = generation
            do {
                if !configured {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        completion("No back camera is available."); return
                    }
                    let input = try AVCaptureDeviceInput(device: camera)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.beginConfiguration()
                    session.sessionPreset = .low
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration(); completion("Camera capture is unavailable."); return
                    }
                    session.addInput(input); session.addOutput(output)
                    session.commitConfiguration()
                    device = camera; configured = true
                }
                lastFrameTime = -Double.infinity
                session.startRunning()
                completion(session.isRunning ? nil : "Camera could not start.")
            } catch { completion(error.localizedDescription) }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            mailbox.clear()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session.isRunning, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer), let device else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp - lastFrameTime >= 0.095 else { return }
        lastFrameTime = timestamp
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 48)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 64)) {
                let offset = y * rowBytes + x * 4
                blue += Double(bytes[offset]); green += Double(bytes[offset + 1]); red += Double(bytes[offset + 2]); count += 1
            }
        }
        guard count > 0 else { return }
        let scale = 100 / (count * 255)
        red *= scale; green *= scale; blue *= scale
        mailbox.put(TelemetryCameraPacket(red: red, green: green, blue: blue, luma: 0.2126 * red + 0.7152 * green + 0.0722 * blue, iso: Double(device.iso), exposure: device.exposureDuration.seconds * 1000, generation: generation))
    }
}
