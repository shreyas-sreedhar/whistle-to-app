import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var detector: DetectorManager

    var body: some View {
        VStack(spacing: 10) {
            Text("🐶 Whistle Detector")
                .font(.headline)

            Divider()

            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(detector.isListening ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(detector.isListening ? "Listening..." : "Not listening")
                    .font(.subheadline)
                Spacer()
            }

            // Level meter
            if detector.isListening {
                HStack(spacing: 4) {
                    Text("Level:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(meterColor(detector.inputLevel))
                                .frame(width: max(0, geo.size.width * CGFloat(min(detector.inputLevel * 5, 1.0))))
                        }
                    }
                    .frame(height: 6)
                }

                if detector.peakFrequency > 0 {
                    Text("Peak: \(Int(detector.peakFrequency)) Hz")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Calibration info
            if let freq = detector.calibrationFrequency {
                Text("Calibrated: \(Int(freq)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Last whistle
            if let last = detector.lastWhistleTime {
                Text("Last whistle: \(last, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Error
            if let error = detector.audioError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Controls
            Button(detector.isListening ? "Stop Listening" : "Start Listening") {
                if detector.isListening {
                    detector.stopListening()
                } else {
                    detector.startListening()
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Calibrate Whistle") {
                detector.runCalibration { _, msg in
                    // The detector already updates its own state
                    print(msg)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!detector.isListening)

            Divider()

            // Debug log (last few entries)
            if !detector.debugLog.isEmpty {
                DisclosureGroup("Debug Log") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(detector.debugLog.suffix(10), id: \.self) { entry in
                                Text(entry)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 120)

                    Button("Clear Log") {
                        detector.clearDebugLog()
                    }
                    .font(.caption)
                }
                .font(.caption)
            }

            Divider()

            Button("Quit") {
                detector.stopListening()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding()
        .frame(width: 260)
        .onAppear {
            if !detector.isListening {
                detector.startListening()
            }
        }
    }

    private func meterColor(_ level: Float) -> Color {
        if level > 0.3 { return .red }
        if level > 0.1 { return .yellow }
        return .green
    }
}
