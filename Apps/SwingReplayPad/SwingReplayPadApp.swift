import SwiftUI

@main
struct SwingReplayPadApp: App {
    @StateObject private var runtime = PadRuntimeController()

    var body: some Scene {
        WindowGroup {
            PadRootView(runtime: runtime)
                .onAppear {
                    runtime.start()
                }
                .onDisappear {
                    runtime.stop()
                }
        }
    }
}
