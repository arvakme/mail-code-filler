import MailCodeCore
import SwiftUI

/// AppModel supplies the ring snapshot and read-only refetch closure.
struct MissedDetectionSamplesView: View {
    let recent: [RecentMissedMail]
    let refetch: @MainActor (RecentMissedMail) async throws -> ReceivedMail
    let store: MissedDetectionSampleStore

    @State private var selectedID: MessageID?
    @State private var original: ReceivedMail?
    @State private var draft: MissedDetectionSample?
    @State private var reviewed = false
    @State private var isLoading = false
    @State private var saved: [MissedDetectionSample] = []
    @State private var errorMessage: String?
    @State private var showEviction = false
    @State private var showDeleteAll = false
    @State private var expectedCode = ""
    @State private var expectedLink = ""
    @State private var expectedPurpose = "signIn"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近邮件里有验证码或登录链接没识别出来？")
                .font(.headline)
            Text("只在选择邮件后重新读取原文。脱敏预览需要你检查，点击保存后才写入本机加密样本。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                recentList
                reviewPane
            }
            Divider()
            HStack {
                Text("已保存样本：\(saved.count)")
                Spacer()
                Button("删除所有样本", role: .destructive) { showDeleteAll = true }
                    .disabled(saved.isEmpty)
            }
            ForEach(saved) { sample in
                HStack {
                    Text(sample.subject).lineLimit(1)
                    Text(sample.redactedAt, style: .date).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除", role: .destructive) { delete(sample.id) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .task { reloadSaved() }
        .alert(
            "无法完成操作",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("知道了") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("继续将删除最早的一条样本", isPresented: $showEviction) {
            Button("继续保存并删除最早样本", role: .destructive) { save(confirmEviction: true) }
        }
        .confirmationDialog("删除所有已保存样本？", isPresented: $showDeleteAll) {
            Button("删除所有样本", role: .destructive) {
                do {
                    try store.deleteAll()
                    reloadSaved()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading) {
            Text("最近未识别邮件").font(.subheadline.weight(.semibold))
            List(recent, selection: $selectedID) { mail in
                VStack(alignment: .leading, spacing: 3) {
                    Text(mail.subject).lineLimit(1)
                    HStack {
                        Text(mail.senderDomain)
                        Text(mail.receivedAt, style: .relative)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .tag(mail.id)
            }
            Button(isLoading ? "正在读取…" : "检查脱敏结果") {
                Task { await loadSelected() }
            }
            .disabled(selectedID == nil || isLoading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }

    private var reviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let original {
                    DisclosureGroup("本地原文（不会保存）") {
                        Text(original.subject).font(.subheadline)
                        Text(original.bodies.joined(separator: "\n\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        ForEach(original.links.map(\.href), id: \.self) { href in
                            Text(href).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                if draft != nil {
                    Text("脱敏预览 · 可继续手动遮盖").font(.subheadline.weight(.semibold))
                    TextField(
                        "脱敏主题",
                        text: Binding(
                            get: { draft?.subject ?? "" },
                            set: {
                                draft?.subject = $0
                                reviewed = false
                            }))
                    Text("发件域：\(draft?.fromDomain ?? "")").font(.caption)
                    TextEditor(
                        text: Binding(
                            get: { draft?.body.texts.joined(separator: "\n") ?? "" },
                            set: {
                                draft?.body = .text($0)
                                reviewed = false
                            })
                    )
                    .font(.caption.monospaced())
                    .frame(minHeight: 180)
                    .border(.secondary)
                    HStack {
                        TextField("标记真码的占位符", text: $expectedCode)
                        Button("标记验证码") {
                            guard var value = draft else { return }
                            MissedMailRedactor().markCode(expectedCode, in: &value)
                            draft = value
                            expectedCode = ""
                            reviewed = false
                        }
                    }
                    HStack {
                        TextField("https://example.invalid/…", text: $expectedLink)
                        Picker("用途", selection: $expectedPurpose) {
                            Text("登录").tag("signIn")
                            Text("激活").tag("activation")
                            Text("验证").tag("verification")
                        }
                        Button("标记链接") {
                            guard var value = draft else { return }
                            MissedMailRedactor().markLink(
                                expectedLink, purpose: expectedPurpose, in: &value)
                            draft = value
                            expectedLink = ""
                            reviewed = false
                        }
                    }
                    TextField(
                        "脱敏备注（可选）",
                        text: Binding(
                            get: { draft?.notes ?? "" },
                            set: {
                                draft?.notes = $0
                                reviewed = false
                            }))
                    Toggle("我已检查并遮盖个人信息、验证码及原始链接", isOn: $reviewed)
                    Button("保存加密样本") { save(confirmEviction: false) }
                        .disabled(!reviewed)
                } else {
                    ContentUnavailableView(
                        "选择一封邮件", systemImage: "envelope.badge.shield.half.filled",
                        description: Text("选择后才会重新读取并在本机脱敏。"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func loadSelected() async {
        guard let selected = recent.first(where: { $0.id == selectedID }) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let mail = try await refetch(selected)
            original = mail
            draft = MissedMailRedactor().makeDraft(from: mail)
            reviewed = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(confirmEviction: Bool) {
        guard let draft else { return }
        do {
            try store.save(draft, reviewed: reviewed, confirmEviction: confirmEviction)
            reloadSaved()
            self.draft = nil
            original = nil
            reviewed = false
        } catch MissedSampleStoreError.full {
            showEviction = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ id: UUID) {
        do {
            try store.delete(id: id)
            reloadSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadSaved() {
        do { saved = try store.list() } catch { errorMessage = error.localizedDescription }
    }
}
