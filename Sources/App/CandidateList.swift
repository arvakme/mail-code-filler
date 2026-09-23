import MailCodeCore
import SwiftUI

struct CandidateList: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.candidates.isEmpty {
                ContentUnavailableView {
                    Label("暂无待用验证码", systemImage: "envelope.open")
                } description: {
                    Text(model.emptyCandidateDescription)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.candidates) { candidate in row(candidate) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 210)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private func row(_ candidate: Candidate) -> some View {
        let sender = SenderIdentity(fromHeader: candidate.source)
        let action = candidate.isCode ? "复制" : "打开"
        return Button {
            model.select(candidate)
            Task { await model.performPrimaryAction(candidate.id) }
        } label: {
            HStack(spacing: 9) {
                SenderAvatar(identity: sender, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(sender.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(sender.registrableDomain ?? "域名未知")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 4) {
                        Text(candidate.subject.isEmpty ? "邮件" : candidate.subject)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("·")
                        Text(candidate.receivedAt, style: .relative)
                            .fixedSize()
                        if let mailbox = model.receivingMailbox(for: candidate) {
                            Text("·")
                            Text(mailbox).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    if let code = candidate.code {
                        Text(code)
                            .font(.system(.callout, design: .monospaced).weight(.bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(candidate.loginLink?.purpose.actionLabel ?? "打开链接")
                            .font(.caption.weight(.semibold))
                        Text(candidate.loginLink?.host ?? "")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(action).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .background(
                model.selectedID == candidate.id ? Color.accentColor.opacity(0.10) : .clear,
                in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: candidate, sender: sender))
        .accessibilityHint(candidate.isCode ? "复制并从待用列表移除" : "在默认浏览器打开并从待用列表移除")
        .accessibilityAddTraits(model.selectedID == candidate.id ? .isSelected : [])
    }

    private func accessibilityLabel(for candidate: Candidate, sender: SenderIdentity) -> String {
        let origin = "\(sender.displayName)，\(sender.registrableDomain ?? "域名未知")"
        if let code = candidate.code { return "复制验证码 \(code)，来自 \(origin)" }
        if let link = candidate.loginLink {
            return "\(link.purpose.actionLabel) \(link.host)，来自 \(origin)"
        }
        return "处理候选，来自 \(origin)"
    }
}

struct SenderAvatar: View {
    let identity: SenderIdentity
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let asset = identity.iconAssetName {
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(iconShape)
                    .overlay {
                        iconShape.strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.5)
                    }
            } else {
                ZStack {
                    iconShape.fill(color)
                    Text(identity.monogram)
                        .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    if colorScheme == .dark && isDarkBrand {
                        iconShape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    }

    private var isDarkBrand: Bool {
        let red = Double((identity.colorHex >> 16) & 0xFF)
        let green = Double((identity.colorHex >> 8) & 0xFF)
        let blue = Double(identity.colorHex & 0xFF)
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255 < 0.2
    }

    private var color: Color {
        Color(
            .sRGB,
            red: Double((identity.colorHex >> 16) & 0xFF) / 255,
            green: Double((identity.colorHex >> 8) & 0xFF) / 255,
            blue: Double(identity.colorHex & 0xFF) / 255,
            opacity: 1)
    }
}

struct CandidatePanel: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择验证码").font(.headline)
            Text(model.targetName.map { "填入目标：\($0)" } ?? "尚未捕获可用输入框")
                .font(.callout).foregroundStyle(.secondary)
            CandidateList(model: model)
            Text(model.status).font(.callout).foregroundStyle(.secondary)
                .frame(minHeight: 48, alignment: .topLeading)
            HStack {
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("复制") { Task { await model.copySelection() } }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(model.selectedID == nil)
                Spacer()
                Button("确认填入") {
                    Task { if await model.confirmFill() { close() } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(model.selectedID == nil || model.targetName == nil || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            model.performSelectedPrimaryAction()
            return .handled
        }
    }
}
