import SwiftUI

@main
struct MailCodeFillerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: delegate.model)
        } label: {
            Image(
                systemName: delegate.model.isDoNotDisturbActive
                    ? "bell.slash"
                    : delegate.model.candidates.isEmpty ? "envelope" : "envelope.badge")
            if !delegate.model.candidates.isEmpty {
                Text("\(delegate.model.candidates.count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
