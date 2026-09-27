import MailCodeAutoFill
import MailCodeCore
import SwiftUI

struct AutoFillStatusView: View {
    let model: AppModel
    let configure: () -> Void

    private var state: AutoFillState {
        model.autoFill?.state ?? .failed(model.autoFillProblem ?? "正在检查扩展配置…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: "key.horizontal").font(.callout.weight(.medium))
                Spacer()
                Button("设置", action: configure).buttonStyle(.glass)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("autofill-status")
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private var title: String {
        switch state {
        case .checking: return "系统 AutoFill · 正在检查"
        case .disabled: return "系统 AutoFill · 尚未启用"
        case .ready: return "系统 AutoFill · 已启用"
        case .failed: return "系统 AutoFill · 需要处理"
        }
    }

    private var detail: String {
        switch state {
        case .checking: return "正在核对系统提供方与共享钥匙串。"
        case .disabled: return "请在系统设置启用 Mail Code Filler；无需辅助功能权限。"
        case .ready(let count):
            return count > 0
                ? "已更新 \(count) 条网站候选。支持的验证码输入框由系统展示建议，点选后填入。"
                : "可在系统验证码列表中选码。选中邮件码并关联网站后，才会发布该网站的建议。"
        case .failed(let message): return message
        }
    }
}

struct AutoFillSettingsView: View {
    let model: AppModel
    let candidate: Candidate?
    let onBack: () -> Void
    @State private var domain = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("返回", action: onBack).keyboardShortcut(.cancelAction)
                Label("系统自动填充", systemImage: "key.horizontal").font(.title2.bold())
            }
            Text("先在系统设置启用 Mail Code Filler，然后保持 Gmail 监听。系统决定哪些 App 和输入框展示建议，并非点击任意输入框都会弹出。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("打开系统 AutoFill 设置") { Task { await model.openAutoFillSettings() } }
                    .buttonStyle(.glassProminent)
                Button("重新检查") {
                    Task {
                        await model.refreshAutoFill()
                        error = nil
                    }
                }
            }
            if let problem = model.autoFillProblem { Text(problem).font(.caption).foregroundStyle(.orange) }
            Divider()
            if let candidate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("为此发件人关联网站").font(.headline)
                    Text(candidate.source).font(.callout).textSelection(.enabled)
                    HStack {
                        TextField("例如 accounts.example.com", text: $domain).textFieldStyle(.roundedBorder)
                        Button("关联") { associate(candidate.id) }
                            .disabled(domain.isEmpty || model.autoFill == nil)
                    }
                    Text("只关联你正在登录的网站，不从邮件内容猜测。关联仅用于排序建议，不代表已验证发件人身份；每次仍由你点选。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("收到真实验证码后，在菜单栏面板选中它，再打开这里关联网站。未关联的验证码仍可从系统列表手动选择。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let rules = model.autoFill?.rules, !rules.isEmpty {
                Text("已关联的网站").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(rules) { rule in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.domain).font(.callout.bold())
                                    Text(rule.sender).font(.caption)
                                    Text(rule.account).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("移除") { remove(rule.id) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never).frame(maxHeight: 150)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("仅短期验证码、来源和关联规则通过本机钥匙串共享；扩展不读取 Gmail 密码或邮件正文。超出接收后 10 分钟的码不会返回，即使主 App 已退出。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }

    private func associate(_ id: Candidate.ID) {
        do {
            try model.associate(id, with: domain)
            domain = ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ id: AutoFillRule.ID) {
        do {
            try model.autoFill?.removeRule(id: id)
            error = nil
        } catch {
            self.error = "移除尚未完全应用：\(error.localizedDescription) 请点“重新检查”重试同步。"
        }
    }
}
