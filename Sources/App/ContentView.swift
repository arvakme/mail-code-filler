import MailCodeCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var page: Page = .main
    @State private var accountToEdit: IMAPAccount?
    @State private var associationCandidate: Candidate?
    @State private var contentHeight: CGFloat = 0
    @FocusState private var queueHasFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch page {
                    case .main:
                        mainPage
                    case .deliverySettings:
                        DeliverySettingsView(model: model, onBack: showMain)
                    case .accountEditor:
                        IMAPAccountFormView(model: model, existingAccount: accountToEdit, onBack: showMain)
                    case .autoFill:
                        AutoFillSettingsView(
                            model: model,
                            candidate: associationCandidate,
                            onBack: showMain
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
            // MenuBarExtra proposes no height, so a bare ScrollView collapses to zero.
            .frame(width: 420, height: min(max(contentHeight, 1), 660))

            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .frame(width: 420)
        .focusable()
        .focused($queueHasFocus)
        .focusEffectDisabled()
        .onAppear { queueHasFocus = page == .main }
        .onChange(of: page) { queueHasFocus = page == .main }
        .onKeyPress(.upArrow) {
            guard page == .main else { return .ignored }
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard page == .main else { return .ignored }
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard page == .main else { return .ignored }
            model.performSelectedPrimaryAction()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard page == .main, press.modifiers.contains(.command),
                let number = Int(press.characters), (1...9).contains(number)
            else { return .ignored }
            model.performPrimaryAction(at: number - 1)
            return .handled
        }
    }

    private var mainPage: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .glassEffect(in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mail Code Filler").font(.title2.bold())
                    Text("验证码，不必翻邮箱").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    page = .deliverySettings
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("识别与提示设置")
            }
            if model.isOfflinePreview {
                Label("离线预览 · 不读取邮箱或钥匙串", systemImage: "testtube.2")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                IMAPAccountsView(model: model, addAccount: showAddAccount, editAccount: showEditAccount)
            }
            if model.supportsAutoFill {
                AutoFillStatusView(model: model) {
                    associationCandidate = model.candidates.first { candidate in
                        candidate.id == model.selectedID
                            && candidate.isCode
                            && model.accountRecords.contains { $0.id == candidate.id.message.account }
                    }
                    page = .autoFill
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("收到新码时自动复制", isOn: $settings.automaticallyCopy)
                    .accessibilityIdentifier("automatically-copy-code")
                Text("开启后会覆盖当前剪贴板。多个候选时仍需手动选择；启动补查的旧邮件不会自动复制。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            doNotDisturbControl
            if let problem = model.recognitionNotice ?? model.accountSetupProblem ?? model.jevProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            CandidateList(model: model)
            HStack {
                if model.accountRecords.isEmpty {
                    Button("离线试用") { Task { await model.loadSample() } }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy)
                }
                Spacer()
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44, alignment: .topLeading)
                .accessibilityIdentifier("operation-status")
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if model.supportsAutoFill {
                    HStack {
                        Text(model.shortcutStatus).font(.callout)
                        Spacer()
                        Button("检查权限") { model.checkPermission() }.buttonStyle(.link)
                    }
                }
                Text("提示默认跟随鼠标出现，也可改为跟随输入光标；拖动标题栏可移动卡片，不会抢焦点。点击时按设置尝试填入或复制。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("候选最长保留 10 分钟，不代表网站有效期。剪贴板中的码不会自动清除。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(22)
        .frame(width: 420)
    }

    @ViewBuilder
    private var doNotDisturbControl: some View {
        if model.isDoNotDisturbActive {
            HStack(spacing: 8) {
                Label(doNotDisturbLabel, systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复") { Task { await model.resumeDoNotDisturb() } }
                    .buttonStyle(.glass)
            }
            .accessibilityIdentifier("do-not-disturb-active")
        } else {
            Menu {
                Button("30 分钟") { Task { await model.setDoNotDisturb(.thirtyMinutes) } }
                Button("1 小时") { Task { await model.setDoNotDisturb(.oneHour) } }
                Button("直到明天早上 08:00") {
                    Task { await model.setDoNotDisturb(.tomorrowMorning) }
                }
                Button("直到我恢复") { Task { await model.setDoNotDisturb(.untilResumed) } }
            } label: {
                Label("暂时勿扰", systemImage: "bell.slash")
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("do-not-disturb-menu")
        }
    }

    private var doNotDisturbLabel: String {
        guard let period = model.settings.doNotDisturbPeriod else { return "勿扰中" }
        if period.choice == .untilResumed { return "勿扰中 · 直到恢复" }
        guard let end = period.endsAt else { return "勿扰中" }
        return "勿扰至 \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func showMain() {
        page = .main
    }

    private func showAddAccount() {
        accountToEdit = nil
        page = .accountEditor
    }

    private func showEditAccount(_ account: IMAPAccount) {
        accountToEdit = account
        page = .accountEditor
    }

    private enum Page: Equatable {
        case main
        case deliverySettings
        case accountEditor
        case autoFill
    }
}
