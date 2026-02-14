import SwiftUI

struct PhoneRootView: View {
    @ObservedObject var runtime: PhoneRuntimeController

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(red: 0.02, green: 0.08, blue: 0.16), Color(red: 0.1, green: 0.2, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Swing Replay / Phone")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)

                    Text("Status: \(runtime.connectionText)")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.95))

                    Text("Metrics: \(runtime.metricsText)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.white.opacity(0.9))

                    if let error = runtime.errorText {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    Spacer()
                }
                .padding(24)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}
