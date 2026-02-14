import SwiftUI

@main
struct SwingReplayPhoneApp: App {
    @StateObject private var runtime = PhoneRuntimeController()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(runtime: runtime)
                .onAppear {
                    runtime.start()
                }
                .onDisappear {
                    runtime.stop()
                }
        }
    }
}
