import MailCodeCore
import SwiftUI

/// Place in the menu panel. The controller owns the deadline and prevents event-driven renewal.
struct CodeWaitControlView: View {
    let controller: any CodeWaitControlling
    @State private var window: CodeWaitWindow?
    @State private var tick = 0

    var body: some View {
        // A plain main-actor ticker instead of TimelineView: SwiftUI may evaluate TimelineView
        // content off the main thread, and the isolation check there crashed the app.
        HStack(spacing: 10) {
            if let window {
                Label("等码中 · \(countdown(to: window.deadline))", systemImage: "hourglass")
                    .font(.callout)
                    .id(tick)
                Spacer()
                Button("停止等待") { Task { await controller.cancel() } }
                    .buttonStyle(.glass)
            } else {
                Button {
                    Task { await controller.begin(.manual) }
                } label: {
                    Label("我在等验证码", systemImage: "hourglass")
                }
                .buttonStyle(.glass)
            }
        }
        .task(id: window) {
            while window != nil {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                tick &+= 1
            }
        }
        .task {
            window = await controller.currentWindow()
            for await update in controller.updates() { window = update }
        }
    }

    private func countdown(to deadline: ContinuousClock.Instant) -> String {
        let remaining = ContinuousClock().now.duration(to: deadline).components
        let seconds = max(0, remaining.seconds + (remaining.attoseconds > 0 ? 1 : 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
