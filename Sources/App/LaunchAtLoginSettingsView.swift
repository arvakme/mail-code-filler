import AppKit
import MailCodeCore
import SwiftUI

struct LaunchAtLoginSettingsView: View {
    let manager: any LaunchAtLoginManaging
    @State private var status: LaunchAtLoginStatus = .notRegistered
    @State private var hasError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "登录时启动",
                isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { enabled in
                        do {
                            status = try manager.setEnabled(enabled)
                            hasError = false
                        } catch {
                            status = manager.refresh()
                            hasError = true
                        }
                    }))
            if status == .requiresApproval {
                Text("已添加，需要在系统设置 → 通用 → 登录项中允许。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开登录项设置") { manager.openSettings() }
                    .buttonStyle(.glass)
            } else if status == .notFound {
                Text("当前 App 的登录项不可用；请从固定安装位置重新启用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hasError {
                Text("无法更新登录项，请在系统设置中检查。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .task { status = manager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            status = manager.refresh()
        }
    }
}
