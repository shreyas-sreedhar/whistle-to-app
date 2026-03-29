import SwiftUI

@main
struct Whistle2App: App {
    @StateObject private var detector = DetectorManager()

    var body: some Scene {
        MenuBarExtra("Whistle Detector", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environmentObject(detector)
        }
        .menuBarExtraStyle(.window)
    }
}
