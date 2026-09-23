import AuthenticationServices
import MailCodeAutoFill
import SwiftUI

@MainActor
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var reader: AutoFillReader?
    private var domains: [String] = []
    private var destination = "当前 App 或网站"
    private var requestedIdentity: (id: String, domain: String)?
    private var completed = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 450))
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        requestedIdentity = nil
        domains = serviceIdentifiers.compactMap { identifier in
            switch identifier.type {
            case .domain: return identifier.identifier.lowercased()
            case .URL: return URL(string: identifier.identifier)?.host?.lowercased()
            default: return nil
            }
        }
        destination = domains.first ?? "当前 App 或网站"
        showList()
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard let request = credentialRequest as? ASOneTimeCodeCredentialRequest,
            let id = request.credentialIdentity.recordIdentifier
        else {
            cancel(.credentialIdentityNotFound)
            return
        }
        do {
            let reader = try makeReader()
            guard
                let entry = try reader.resolve(
                    id: id, domain: request.credentialIdentity.serviceIdentifier.identifier, at: Date())
            else {
                cancel(.credentialIdentityNotFound)
                return
            }
            complete(entry)
        } catch {
            cancel(.userInteractionRequired)
        }
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        guard let request = credentialRequest as? ASOneTimeCodeCredentialRequest,
            let id = request.credentialIdentity.recordIdentifier
        else {
            cancel(.credentialIdentityNotFound)
            return
        }
        let domain = request.credentialIdentity.serviceIdentifier.identifier
        requestedIdentity = (id, domain)
        destination = domain
        showList()
    }

    override func prepareInterfaceForExtensionConfiguration() {
        showMessage(
            "已开启系统 AutoFill",
            detail: "请在菜单栏的 Mail Code Filler 中连接 Gmail，并保持 App 运行。未关联网站的邮件码可从系统的验证码列表中手动选择；关联后由系统决定何时展示建议。",
            button: "完成"
        ) { [weak self] in self?.extensionContext.completeExtensionConfigurationRequest() }
    }

    private func makeReader() throws -> AutoFillReader {
        let group = Bundle.main.object(forInfoDictionaryKey: "MailCodeAutoFillAccessGroup") as? String ?? ""
        return try AutoFillReader(store: KeychainAutoFillStore(accessGroup: group))
    }

    private func showList() {
        do {
            let reader = try makeReader()
            self.reader = reader
            if let request = requestedIdentity {
                guard let entry = try reader.resolve(id: request.id, domain: request.domain, at: Date())
                else {
                    showError("这条验证码已过期或已移除，请回到输入框重新选择。")
                    return
                }
                show(entries: [entry])
            } else {
                show(entries: try reader.entries(at: Date(), preferredDomains: domains))
            }
        } catch { showError(error.localizedDescription) }
    }

    private func show(entries: [AutoFillEntry]) {
        view = NSHostingView(
            rootView: CodeProviderView(
                entries: entries, destination: destination, choose: { [weak self] in self?.choose($0) },
                refresh: { [weak self] in self?.showList() },
                cancel: { [weak self] in self?.cancel(.userCanceled) }
            ))
        preferredContentSize = NSSize(width: 420, height: 450)
    }

    private func choose(_ id: String) {
        do {
            guard let entry = try reader?.resolve(id: id, domain: requestedIdentity?.domain, at: Date())
            else {
                showError("这条验证码已过期或已移除；不会改填另一条验证码。")
                return
            }
            complete(entry)
        } catch { showError(error.localizedDescription) }
    }

    private func complete(_ entry: AutoFillEntry) {
        guard !completed else { return }
        completed = true
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: entry.code))
    }

    private func cancel(_ code: ASExtensionError.Code) {
        guard !completed else { return }
        completed = true
        extensionContext.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }

    private func showError(_ detail: String) {
        showMessage("无法提供验证码", detail: detail, button: "返回输入框") { [weak self] in self?.cancel(.userCanceled) }
    }

    private func showMessage(_ title: String, detail: String, button: String, action: @escaping () -> Void) {
        view = NSHostingView(
            rootView:
                VStack(alignment: .leading, spacing: 20) {
                    Label(title, systemImage: "key.horizontal").font(.title2.bold())
                    Text(detail).foregroundStyle(.secondary)
                    Button(button, action: action).buttonStyle(.glassProminent).keyboardShortcut(
                        .defaultAction)
                }.padding(24).frame(width: 420)
        )
        preferredContentSize = NSSize(width: 420, height: 240)
    }
}

private struct CodeProviderView: View {
    let entries: [AutoFillEntry]
    let destination: String
    let choose: (String) -> Void
    let refresh: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Mail Code Filler", systemImage: "key.horizontal").font(.title2.bold())
            Text("填入：\(destination)").font(.callout).textSelection(.enabled)
            if entries.isEmpty {
                ContentUnavailableView(
                    "没有可用验证码", systemImage: "envelope.open",
                    description:
                        Text("请保持主 App 正在监听 Gmail，再请求新验证码。"))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(entries) { entry in
                            Button {
                                choose(entry.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.code).font(.system(.title2, design: .monospaced).bold())
                                    Text(entry.sender).font(.callout)
                                    Text(entry.account).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.receivedAt, style: .time).font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }.buttonStyle(.glass)
                        }
                    }.padding(4)
                }
            }
            Text("请核对发件人与目标网站。邮件来源未经本工具认证；点选仅填入，不提交。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("刷新", action: refresh)
            }
        }.padding(24).frame(width: 420, height: 450)
    }
}
