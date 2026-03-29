import SwiftUI
import AVFoundation
import Accelerate
import Combine

@MainActor
class DetectorManager: ObservableObject {
    @Published var isListening = false
    @Published var lastWhistleTime: Date?
    @Published var calibrationFrequency: Double?
    @Published var audioError: String?
    @Published var debugLog: [String] = []
    @Published var inputLevel: Float = 0.0
    @Published var peakFrequency: Double = 0.0

    private let targetSampleRate: Double = 44100
    private let fftSize = 2048
    private var lastActionDate: Date?
    private let actionCooldown: TimeInterval = 2.0
    private var isCalibrating = false
    private var calibrationData: [Float] = []

    private var audioEngine: AVAudioEngine?
    private var processor: AudioProcessor?
    private let audioProcessingQueue = DispatchQueue(label: "audio.processing", qos: .userInteractive)

    init() {
        log("DetectorManager initialized")
    }

    func clearDebugLog() { debugLog.removeAll() }

    private func log(_ message: String) {
        let entry = "[\(Date().formatted(.dateTime.hour().minute().second()))] \(message)"
        print(entry)
        debugLog.append(entry)
        if debugLog.count > 100 { debugLog.removeFirst(debugLog.count - 100) }
    }

    // MARK: - Start / Stop

    func startListening() {
        log("startListening called")

        // On macOS 14+, use AVAudioApplication. On older, just try to start.
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.log("Mic permission granted")
                        self?.startEngine()
                    } else {
                        self?.audioError = "Microphone permission denied. Enable in System Settings > Privacy > Microphone."
                        self?.log("Mic permission denied")
                    }
                }
            }
        } else {
            // Older macOS — just try to start, the system will prompt
            startEngine()
        }
    }

    private func startEngine() {
        // Tear down any existing engine cleanly
        stopListening()

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode

        // Use the hardware's native format — don't force a format
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let actualSampleRate = hwFormat.sampleRate
        let channelCount = hwFormat.channelCount

        log("Hardware format: \(actualSampleRate) Hz, \(channelCount) ch")

        guard actualSampleRate > 0, channelCount > 0 else {
            audioError = "No audio input device found."
            log("❌ Invalid hardware format")
            self.audioEngine = nil
            return
        }

        // Create processor with the actual sample rate
        let proc = AudioProcessor(fftSize: fftSize, sampleRate: actualSampleRate)
        self.processor = proc

        // Install tap using the hardware's native format
        inputNode.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: hwFormat) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, sampleRate: actualSampleRate)
        }

        do {
            try engine.start()
            isListening = true
            audioError = nil
            log("✅ Audio engine started (rate: \(actualSampleRate) Hz)")
        } catch {
            self.audioEngine = nil
            self.processor = nil
            audioError = "Failed to start audio: \(error.localizedDescription)"
            log("❌ Engine start failed: \(error)")
        }
    }

    func stopListening() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            log("Audio engine stopped")
        }
        audioEngine = nil
        processor = nil
        isListening = false
    }

    // MARK: - Calibration

    func runCalibration(completion: @escaping (Bool, String) -> Void) {
        isCalibrating = true
        calibrationData.removeAll()
        log("Calibration started — whistle now!")

        if !isListening { startListening() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.isCalibrating = false
            if let freq = self.analyzeCalibrationData() {
                self.calibrationFrequency = freq
                let msg = "Calibrated to \(Int(freq)) Hz"
                self.log("✅ \(msg)")
                completion(true, msg)
            } else {
                let msg = "No whistle detected — try again louder."
                self.log("⚠️ \(msg)")
                completion(false, msg)
            }
        }
    }

    private func analyzeCalibrationData() -> Double? {
        let inRange = calibrationData.filter { $0 >= 1000 && $0 <= 3200 }
        guard inRange.count >= 3 else { return nil } // need at least 3 samples

        let tolerance: Float = 80.0
        var groups: [(center: Float, count: Int)] = []

        for freq in inRange {
            if let idx = groups.firstIndex(where: { abs($0.center - freq) <= tolerance }) {
                // Update running average
                let g = groups[idx]
                let newCenter = (g.center * Float(g.count) + freq) / Float(g.count + 1)
                groups[idx] = (newCenter, g.count + 1)
            } else {
                groups.append((freq, 1))
            }
        }

        guard let best = groups.max(by: { $0.count < $1.count }), best.count >= 2 else {
            return nil
        }
        return Double(best.center)
    }

    // MARK: - Audio Processing

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Compute RMS level
        var rms: Float = 0.0
        vDSP_measqv(channelData, 1, &rms, vDSP_Length(frames))
        let level = sqrt(rms)

        // Copy samples before leaving this scope (buffer is reused by the engine)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))

        Task { @MainActor in
            self.inputLevel = level
        }

        audioProcessingQueue.async { [weak self] in
            guard let self, let proc = self.processor else { return }
            if let result = proc.process(samples: samples) {
                Task { @MainActor in
                    self.handleFFTResult(result)
                }
            }
        }
    }

    private func handleFFTResult(_ result: FFTResult) {
        peakFrequency = result.frequency

        if isCalibrating {
            calibrationData.append(Float(result.frequency))
            return
        }

        if isWhistleFrequency(result.frequency) && result.magnitude > 0.005 {
            onWhistleDetected(at: result.frequency, magnitude: result.magnitude)
        }
    }

    private func isWhistleFrequency(_ freq: Double) -> Bool {
        if let cal = calibrationFrequency {
            return abs(freq - cal) <= 250.0
        }
        return freq >= 1000 && freq <= 3200
    }

    private func onWhistleDetected(at freq: Double, magnitude: Float) {
        let now = Date()
        if let last = lastActionDate, now.timeIntervalSince(last) < actionCooldown { return }

        lastWhistleTime = now
        lastActionDate = now
        log("🎵 Whistle detected at \(Int(freq)) Hz (mag: \(String(format: "%.2f", magnitude))) — launching Claude!")
        openClaudeCode()
    }

    // MARK: - Action

    private func openClaudeCode() {
        // Use Process instead of NSAppleScript — works without sandbox issues
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal"]

        // First open Terminal, then send the command via AppleScript
        // Alternative: use Process to launch directly
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // Method 1: Direct process launch
                let shell = Process()
                shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
                shell.arguments = ["-c", "open -a Terminal && sleep 0.5 && osascript -e 'tell application \"Terminal\" to do script \"cd ~/Developer && claude\"'"]
                try shell.run()
                shell.waitUntilExit()

                Task { @MainActor [weak self] in
                    self?.log("✅ Claude Code launched")
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.log("❌ Launch failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - FFTResult

struct FFTResult {
    let frequency: Double
    let magnitude: Float
}

// MARK: - AudioProcessor (thread-safe, works on audioProcessingQueue only)

final class AudioProcessor: @unchecked Sendable {
    private let fftSize: Int
    private let sampleRate: Double
    private let halfSize: Int

    private var audioBuffer: [Float] = []
    private var window: [Float]
    private var windowedSamples: [Float]
    private var magnitudes: [Float]

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    init(fftSize: Int, sampleRate: Double) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.halfSize = fftSize / 2

        self.window = [Float](repeating: 0, count: fftSize)
        self.windowedSamples = [Float](repeating: 0, count: fftSize)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func process(samples: [Float]) -> FFTResult? {
        audioBuffer.append(contentsOf: samples)

        // Keep buffer from growing unbounded
        if audioBuffer.count > fftSize * 3 {
            audioBuffer.removeFirst(audioBuffer.count - fftSize)
        }
        guard audioBuffer.count >= fftSize else { return nil }

        // Take the most recent fftSize samples
        let slice = Array(audioBuffer.suffix(fftSize))

        // Apply window
        vDSP_vmul(slice, 1, window, 1, &windowedSamples, 1, vDSP_Length(fftSize))

        // Set up split complex for in-place FFT
        var realPart = [Float](repeating: 0, count: halfSize)
        var imagPart = [Float](repeating: 0, count: halfSize)

        // Pack real data into split complex form
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )

                // Convert interleaved real data to split complex
                windowedSamples.withUnsafeBufferPointer { samplesPtr in
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }

                // Perform FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Compute magnitudes
                for i in 0..<halfSize {
                    let r = splitComplex.realp[i]
                    let im = splitComplex.imagp[i]
                    magnitudes[i] = sqrt(r * r + im * im) / Float(fftSize)
                }
            }
        }

        // Search only in whistle range: 1000–3200 Hz
        let minBin = max(1, Int(1000.0 * Double(fftSize) / sampleRate))
        let maxBin = min(Int(3200.0 * Double(fftSize) / sampleRate), halfSize - 1)

        guard minBin < maxBin else { return nil }

        // Find peak in whistle range
        var peakIdx = minBin
        var peakMag = magnitudes[minBin]
        for i in (minBin + 1)...maxBin {
            if magnitudes[i] > peakMag {
                peakMag = magnitudes[i]
                peakIdx = i
            }
        }

        // Compute average magnitude in the whistle range (excluding the peak ±2 bins)
        var sum: Float = 0
        var count: Float = 0
        for i in minBin...maxBin {
            if abs(i - peakIdx) > 2 {
                sum += magnitudes[i]
                count += 1
            }
        }
        let avgMag = count > 0 ? sum / count : 0

        // A whistle is a clean tone — peak should be much louder than the average
        // Ratio of ~5+ means a clear tonal spike vs background
        let peakToAvg = avgMag > 0 ? peakMag / avgMag : 0

        // Need both: some minimum energy AND a clear tonal peak
        guard peakMag > 0.005, peakToAvg > 4.0 else { return nil }

        // Parabolic interpolation for better frequency accuracy
        let freq: Double
        if peakIdx > 0 && peakIdx < halfSize - 1 {
            let alpha = magnitudes[peakIdx - 1]
            let beta  = magnitudes[peakIdx]
            let gamma = magnitudes[peakIdx + 1]
            let denom = alpha - 2.0 * beta + gamma
            let p: Float = (denom != 0) ? 0.5 * (alpha - gamma) / denom : 0
            freq = (Double(peakIdx) + Double(p)) * sampleRate / Double(fftSize)
        } else {
            freq = Double(peakIdx) * sampleRate / Double(fftSize)
        }

        // Consume processed samples to avoid re-processing
        if audioBuffer.count >= fftSize {
            audioBuffer.removeFirst(fftSize / 2) // overlap by 50%
        }

        return FFTResult(frequency: freq, magnitude: peakMag)
    }
}
