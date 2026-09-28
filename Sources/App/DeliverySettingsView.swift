import AppKit
import MailCodeCore
import SwiftUI

struct DeliverySettingsView: View {
    let model: AppModel
    let onBack: () -> Void
    let onOpenSamples: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var seconds = ""
    @State private var key = ""
    @State private var problem: String?
    @State private var accessibilityPermissionGranted = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("返回") {
                    perform {
                        try settings.setDisplayDuration(seconds)
                        key = ""
                        onBack()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Text("识别与提示").font(.title2.bold())
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("到码提示", systemImage: "bell.badge").font(.headline)
                Toggle("同时检查垃圾邮件文件夹", isOn: $settings.checksJunkFolder)
                    .accessibilityIdentifier("checks-junk-folder")
                Text("垃圾邮件里的码更可能是钓鱼，卡片会标出来源。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("提示出现位置", selection: $settings.cardPlacementMode) {
                    Text("跟随鼠标").tag(CardPlacementMode.followMouse)
                    Text("跟随输入光标").tag(CardPlacementMode.followInputCaret)
                }
                .pickerStyle(.radioGroup)
                Text("跟随鼠标时卡片出现在指针右下方并避开指针；靠近屏幕边缘时会换边。跟随输入光标时依次尝试插入点、小型输入框和鼠标位置。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("记住拖动后的位置", isOn: $settings.rememberDraggedPosition)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("拖动卡片标题栏移动。开启后按显示器记住位置；关闭后只移动当前卡片，已保存位置保留但不应用。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("重置位置") { settings.resetRememberedCardPositions() }
                        .buttonStyle(.link)
                        .disabled(settings.rememberedCardPositions.isEmpty)
                }
                Toggle(
                    "允许截图和录屏看到验证码提示",
                    isOn: Binding(
                        get: { settings.allowsScreenshots },
                        set: { model.setScreenshotPermission($0) })
                )
                Text("开启后，系统截图、录屏或屏幕共享可能记录验证码提示；关闭时到码卡片及热键填入面板不会出现在捕获画面。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("自动关闭")
                    Spacer()
                    TextField("秒数", text: $seconds)
                        .onSubmit { perform { try settings.setDisplayDuration(seconds) } }
                        .frame(width: 60).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("提示显示秒数")
                    Text("秒")
                    Stepper(
                        "调整秒数", value: $settings.notificationSeconds, in: DeliverySettings.notificationRange,
                        step: 5
                    )
                    .labelsHidden()
                }
                Text("默认 30 秒，可设 5–300 秒，下次提示生效。成功使用候选后会从待用列表移除并关闭对应提示；自动复制不会消费候选。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("点击验证码卡片时", selection: $settings.cardClickAction) {
                    Text("填入当前输入框（需要辅助功能）").tag(CodeCardClickAction.fill)
                    Text("只复制").tag(CodeCardClickAction.copy)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("code-card-click-action")
                if settings.cardClickAction == .fill {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(
                            accessibilityPermissionGranted
                                ? "辅助功能已授权。没有可写输入框或填入未获确认时，会复制并说明原因。"
                                : "辅助功能未授权；选择填入时会回退为复制并说明原因。"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        if !accessibilityPermissionGranted {
                            Button("打开系统设置") { model.openAccessibilityPrivacySettings() }
                                .font(.caption)
                                .accessibilityIdentifier("open-accessibility-settings")
                        }
                    }
                }
                Text("默认只复制。登录链接始终按点击打开，不受此设置影响。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("登录链接提示范围", selection: $settings.linkCardLevel) {
                    Text("仅登录与验证").tag(LinkCardLevel.signInAndVerification)
                    Text("包括账号安全提醒").tag(LinkCardLevel.includingAccountNotices)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("link-card-level")
                Text("默认只显示登录、邮箱验证和账号激活链接。开启账号安全提醒后，新设备登录等提醒也会进入提示和待用列表。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("浏览器匹配", systemImage: "globe").font(.headline)
                Toggle("允许在 AX 无法读取时读取当前浏览器标签网址", isOn: $settings.allowsBrowserAutomation)
                Text("仅 Safari 和 Chrome 的当前标签可能请求 macOS 自动化权限；其他浏览器只尝试辅助功能。仅保留网站域名用于候选排序，不发送网址。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("等码", systemImage: "hourglass").font(.headline)
                Toggle(
                    "检测验证码输入框并加快查收",
                    isOn: Binding(
                        get: { settings.otpFieldAutoTriggerEnabled },
                        set: {
                            settings.otpFieldAutoTriggerEnabled = $0
                            model.onCodeWaitTriggerSettingsChanged?()
                        }))
                Toggle(
                    "仅在登录或验证页面触发",
                    isOn: Binding(
                        get: { settings.otpFieldRequireAuthPage },
                        set: {
                            settings.otpFieldRequireAuthPage = $0
                            model.onCodeWaitTriggerSettingsChanged?()
                        })
                )
                .disabled(!settings.otpFieldAutoTriggerEnabled)
                Text("自动检测需要已有辅助功能授权；不开启时仍可在主面板手动等码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("剪贴板", systemImage: "doc.on.clipboard").font(.headline)
                Toggle(
                    "自动清除剪贴板验证码",
                    isOn: Binding(
                        get: { settings.clipboardAutoClearEnabled },
                        set: { model.setClipboardAutoClearEnabled($0) }))
                Picker("等待时间", selection: $settings.clipboardAutoClearSeconds) {
                    ForEach(DeliverySettings.clipboardAutoClearChoices, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                .disabled(!settings.clipboardAutoClearEnabled)
                Text("仅在剪贴板未变化时尝试清除；剪贴板历史工具仍可能留存验证码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("登录与反馈", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                LaunchAtLoginSettingsView(manager: model.loginManager)
                    .disabled(model.isOfflinePreview)
                Button("最近邮件里有验证码或登录链接没识别出来？", action: onOpenSamples)
                    .buttonStyle(.link)
                Text("样本仅在选择邮件后只读重取，脱敏预览经你确认才保存到本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label("Jev 辅助识别", systemImage: "sparkles").font(.headline)
                Toggle(
                    "仅将本地未识别的邮件交给 Jev",
                    isOn: Binding(
                        get: { settings.jevEnabled },
                        set: { enabled in perform { try model.enableJev(enabled) } })
                )
                .disabled(model.isOfflinePreview)
                Text(
                    "明确验证码直接在本地显示，多个明确候选仍由你选择。启用后，疑难邮件的发件人、主题和最多 1500 字正文将发给 TypeSafe；不发送 Gmail 密码或附件。Jev 只能选择原文中的码。"
                )
                .font(.caption).foregroundStyle(.secondary)
                if model.isOfflinePreview {
                    Text("离线预览不读取密钥，不调用 Jev。").font(.callout)
                } else {
                    SecureField("TypeSafe API Key", text: $key).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存并启用") {
                            perform {
                                try model.saveJevKey(key)
                                key = ""
                            }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("从 .env 文件导入…") {
                            let panel = NSOpenPanel()
                            panel.showsHiddenFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            NSApp.activate()
                            guard panel.runModal() == .OK, let file = panel.url else { return }
                            perform { try model.importJevKey(from: file) }
                        }
                        Spacer()
                        Button("移除密钥") {
                            perform {
                                try model.removeJevKey()
                                key = ""
                            }
                        }
                    }
                    Text("导入只读取所选文件中的 TYPESAFE_API_KEY，保存到登录钥匙串，不执行该文件。关闭 Jev 会取消待处理请求，不重放旧邮件。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(problem ?? model.jevProblem ?? model.recognitionNotice ?? model.jevStatus)
                    .font(.callout).foregroundStyle(problem == nil ? Color.secondary : .red)
            }
            if let timing = model.lastProcessingSummary {
                Divider()
                Text(timing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("以上不包含邮件投递和服务器推送前的等待，不是端到端延迟。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            seconds = String(settings.notificationSeconds)
            refreshAccessibilityPermission()
        }
        .onChange(of: settings.notificationSeconds) { seconds = String(settings.notificationSeconds) }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refreshAccessibilityPermission() }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    private func refreshAccessibilityPermission() {
        accessibilityPermissionGranted = model.accessibilityPermissionGranted
    }
}
