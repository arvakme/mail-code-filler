import MailCodeCore
import SwiftUI

struct IMAPAccountFormView: View {
    let model: AppModel
    let existingAccount: IMAPAccount?
    let onBack: () -> Void
    @State private var provider: IMAPProvider = .gmail
    @State private var email = ""
    @State private var secret = ""
    @State private var error: String?
    @State private var isSaving = false

    private var descriptor: IMAPProviderDescriptor { provider.descriptor }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("返回", action: onBack).keyboardShortcut(.cancelAction)
                Label(
                    provider == .outlook
                        ? (existingAccount == nil ? "添加 Outlook 邮箱" : "重新登录 Microsoft")
                        : (existingAccount == nil ? "添加邮箱" : "更新邮箱凭据"),
                    systemImage: descriptor.iconName
                )
                .font(.title2.bold())
            }
            if existingAccount == nil {
                Picker("邮箱类型", selection: $provider) {
                    ForEach(IMAPProvider.allCases, id: \.self) { item in
                        Text(item.descriptor.displayName).tag(item)
                            .disabled(item == .outlook && !model.isOutlookConfigured)
                    }
                }
                .pickerStyle(.menu)
            }
            if !model.isOutlookConfigured {
                Text("Outlook 需先按 README 填写 Client ID 并重新构建。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(existingAccount == nil ? "添加后与其他账户同时监听。" : existingAccount?.email ?? "")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                TextField("邮箱地址", text: $email)
                    .textContentType(.username)
                    .accessibilityIdentifier("imap-account-email")
                if provider != .outlook {
                    SecureField(descriptor.credentialPlaceholder, text: $secret)
                        .accessibilityIdentifier("imap-account-secret")
                }
            }
            .textFieldStyle(.roundedBorder)
            Text(descriptor.credentialHelpText)
                .font(.callout).foregroundStyle(.secondary)
            if provider == .outlook {
                Text(
                    "首次使用：在 Microsoft Entra 管理中心注册支持个人 Microsoft 账户的公用客户端，将 Client ID 写入本机 Config/Signing.local.xcconfig 的 MAIL_CODE_OUTLOOK_CLIENT_ID 并重新构建。Client ID 不是密码。"
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(
                    "授权允许本 App 通过 IMAP 访问你有权限的邮箱，范围大于验证码读取。App 实际只对 INBOX 执行只读 EXAMINE/BODY.PEEK，在本机识别验证码，不标记已读、不修改、删除或发送邮件；登录令牌保存在本机钥匙串。"
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Link("打开\(descriptor.displayName)设置说明", destination: descriptor.credentialHelpURL)
            }
            Label("登录凭据只保存在本机登录钥匙串；不与 AutoFill 扩展共享。", systemImage: "lock.shield")
                .font(.callout)
            Text("通过加密连接只读 INBOX，不改变邮件已读状态。连接后会检查最近 10 分钟邮件；退出 App 时停止监听。")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .accessibilityIdentifier("imap-account-setup-error")
            }
            HStack {
                Button("取消") {
                    secret = ""
                    onBack()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(provider == .outlook ? "登录 Microsoft 并授权" : "保存并连接") {
                    Task { await save() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    email.isEmpty || (provider != .outlook && secret.isEmpty)
                        || (provider == .outlook && !model.isOutlookConfigured) || isSaving)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            provider = existingAccount?.provider ?? .gmail
            email = existingAccount?.email ?? ""
        }
        .onDisappear { secret = "" }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if provider == .outlook {
                try await model.connectMicrosoftAccount(email: email)
            } else {
                try await model.connectAccount(provider: provider, email: email, secret: secret)
            }
            secret = ""
            onBack()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "保存失败，请重试。"
        }
    }
}

struct IMAPAccountsView: View {
    let model: AppModel
    let addAccount: () -> Void
    let editAccount: (IMAPAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("邮箱账户").font(.callout.weight(.semibold))
                Spacer()
                Button("添加邮箱", action: addAccount)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if model.accounts.isEmpty {
                Text(model.accountSetupProblem ?? "尚未连接邮箱。添加 Gmail、QQ、iCloud、网易或 Outlook 邮箱后即可同时监听。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts, id: \.account.id) { session in
                    IMAPAccountRow(model: model, session: session) {
                        editAccount(session.account)
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

private struct IMAPAccountRow: View {
    let model: AppModel
    let session: IMAPAccountSession
    let update: () -> Void
    @State private var confirmRemoval = false
    @State private var removalError: String?

    private var account: IMAPAccount { session.account }
    private var descriptor: IMAPProviderDescriptor { account.descriptor }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(descriptor.displayName, systemImage: descriptor.iconName)
                    .font(.callout.weight(.medium))
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(stateLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(stateColor)
                Menu {
                    if session.isActive {
                        Button("暂停监听") { Task { await session.pause() } }
                    } else {
                        Button("重新连接") { session.resume() }
                    }
                    Button(account.provider == .outlook ? "重新登录 Microsoft" : "更新凭据", action: update)
                    Divider()
                    Button("移除账户", role: .destructive) { confirmRemoval = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(session.phase == .stopping)
                .accessibilityLabel("管理\(descriptor.displayName)账户 \(account.email)")
            }
            Text(session.message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let date = session.lastSynchronizedAt {
                Text("最近同步：\(date, style: .time)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let notice = session.notice ?? session.recognitionNotice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let removalError {
                Text(removalError).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "移除 \(descriptor.displayName)账户 \(account.email)？本 App 的凭据和该账户候选会被移除，邮箱里的邮件不会改变。",
            isPresented: $confirmRemoval
        ) {
            Button("移除账户", role: .destructive) {
                Task {
                    do {
                        try await model.removeAccount(account.id)
                        removalError = nil
                    } catch {
                        removalError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var stateLabel: String {
        switch session.phase {
        case .notConfigured: "未连接"
        case .paused: "已暂停"
        case .stopping: "停止中"
        case .failed: "需要处理"
        case .active(.connecting): "连接中"
        case .active(.synchronizing): "同步中"
        case .active(.listening): "监听中"
        case .active(.polling): "轮询中"
        case .active(.reconnecting): "连接可能中断，正在重连"
        }
    }

    private var stateColor: Color {
        switch session.phase {
        case .active(.listening): .green
        case .active(.polling): .orange
        case .failed: .red
        default: .secondary
        }
    }
}
