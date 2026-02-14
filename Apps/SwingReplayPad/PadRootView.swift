import SwiftUI
import SwingReplayCore

struct PadRootView: View {
    @ObservedObject var runtime: PadRuntimeController
    @State private var isSettingsPresented = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReceiverFullScreenView(gravity: .fit) { view in
                runtime.bindDisplayView(view)
            }
            .background(Color.black)

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 12)
            .padding(.trailing, 12)
            .accessibilityLabel("Open Settings")
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                Form {
                    Section("Playback Delay") {
                        HStack(spacing: 8) {
                            Text("Delay")
                            Slider(value: $runtime.targetDelaySeconds, in: 1...8, step: 0.5)
                            Text(String(format: "%.1fs", runtime.targetDelaySeconds))
                                .monospacedDigit()
                        }
                    }
                    Section("Runtime") {
                        Text("Status: \(runtime.connectionText)")
                        Text("State: \(runtime.runtimeText)")
                        Text(runtime.debugText)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .navigationTitle("Receiver Settings")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isSettingsPresented = false
                        }
                    }
                }
            }
        }
    }
}
