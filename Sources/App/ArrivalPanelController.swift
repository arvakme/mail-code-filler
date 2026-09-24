import AppKit
import MailCodeCore
import SwiftUI

@MainActor
final class ArrivalPanelController {
    private let model: AppModel
    private let panel: NSPanel
    private var ids: Set<Candidate.ID> = []
    private var dismissal: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var currentNotice: ArrivalNotice?
    private var host: NSHostingView<ArrivalView>?
    private var fillPossible = false
    private let pageProvider: any ActivePageProviding
    private let ranker = CurrentSiteCandidateRanker()

    init(model: AppModel, pageProvider: any ActivePageProviding = BrowserActivePageProvider()) {
        self.model = model
        self.pageProvider = pageProvider
        panel = ArrivalCardPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Mail Code Filler · 验证码提示"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // SwiftUI supplies the card glass; avoid a second rectangular panel shadow.
        panel.hasShadow = false
        panel.sharingType = model.settings.allowsScreenshots ? .readOnly : .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func show(_ notice: ArrivalNotice) {
        if panel.isVisible, host != nil {
            currentNotice = notice
            ids = Set(notice.candidates.map(\.id))
            updateVisibleStack()
            restartDismissal(for: notice)
            return
        }
        currentNotice = notice
        ids = Set(notice.candidates.map(\.id))
        updateScreenshotSharing()
        let target = AccessibilityDestination.focusedTextTarget()
        fillPossible = target != nil
        let hostingView = NSHostingView(
            rootView: ArrivalView(
                model: model, notice: notice,
                rankedCandidates: ranker.rank(notice.candidates, for: pageProvider.currentPage()),
                fillPossible: fillPossible, close: { [weak self] in self?.close() },
                drag: { [weak self] in self?.drag($0) }))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        host = hostingView
        guard
            let frame = positionedFrame(size: size, target: target?.bounds)
        else {
            close()
            return
        }
        panel.setFrame(frame, display: true)
        // Never activate or request key status; the user's app keeps the typing focus.
        panel.orderFrontRegardless()
        restartDismissal(for: notice)
    }

    private func updateVisibleStack() {
        guard let notice = currentNotice, let host else { return }
        host.rootView = ArrivalView(
            model: model, notice: notice,
            rankedCandidates: ranker.rank(notice.candidates, for: pageProvider.currentPage()),
            fillPossible: fillPossible,
            close: { [weak self] in self?.close() }, drag: { [weak self] in self?.drag($0) })
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let oldFrame = panel.frame
        panel.setFrame(NSRect(origin: oldFrame.origin, size: size), display: true)
    }

    private func restartDismissal(for notice: ArrivalNotice) {
        dismissal?.cancel()
        let duration = model.settings.displayDuration(automaticallyCopied: notice.automaticallyCopied)
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.close()
        }
    }

    /// `size` includes the transparent glass margin; placement and remembered origins use the visible surface.
    private func positionedFrame(size: NSSize, target: CGRect?) -> NSRect? {
        let cardSize = CGSize(
            width: max(0, size.width - 2 * cardGlassMargin),
            height: max(0, size.height - 2 * cardGlassMargin))
        let mode = model.settings.cardPlacementMode
        let anchor = mode == .followInputCaret ? (target ?? AccessibilityDestination.placementAnchor()) : nil
        let mouse = NSEvent.mouseLocation
        let point = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let screen = screen(containing: point)
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        let allScreens = NSScreen.screens.compactMap { placementScreen(for: $0) }
        let cardFrame: CGRect
        if let currentScreen = placementScreen(for: screen) {
            cardFrame = CardPlacement.preferredFrame(
                mode: mode,
                shouldUseRememberedPosition: model.settings.rememberDraggedPosition,
                rememberedPositions: model.settings.rememberedCardPositions,
                currentScreen: currentScreen,
                screens: allScreens,
                cardSize: cardSize,
                pointer: mouse,
                inputAnchor: anchor,
                mouseGap: CardPlacement.pointerGap + cardGlassMargin,
                collisionMargin: cardGlassMargin)
        } else if mode == .followMouse {
            cardFrame = CardPlacement.followingMouse(
                cardSize: cardSize, pointer: mouse, visibleFrame: visible,
                gap: CardPlacement.pointerGap + cardGlassMargin,
                collisionMargin: cardGlassMargin)
        } else {
            cardFrame = CardPlacement.followingInput(
                cardSize: cardSize,
                anchor: anchor ?? AccessibilityDestination.placementAnchor(),
                visibleFrame: visible)
        }
        return cardFrame.insetBy(dx: -cardGlassMargin, dy: -cardGlassMargin)
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func screenIdentifier(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    private func placementScreen(for screen: NSScreen) -> CardPlacementScreen? {
        guard let identifier = screenIdentifier(screen) else { return nil }
        return CardPlacementScreen(identifier: identifier, visibleFrame: screen.visibleFrame)
    }

    func updateScreenshotSharing(_ allowed: Bool? = nil) {
        let isAllowed = allowed ?? model.settings.allowsScreenshots
        panel.sharingType = isAllowed ? .readOnly : .none
    }

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// The panel never becomes key, so AppKit's background dragging does not apply; move it from the header gesture.
    private func drag(_ phase: ArrivalDragPhase) {
        switch phase {
        case .changed:
            let mouse = NSEvent.mouseLocation
            let start = dragStart ?? (mouse, panel.frame.origin)
            dragStart = start
            panel.setFrameOrigin(
                NSPoint(
                    x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        case .ended:
            dragStart = nil
            if model.settings.rememberDraggedPosition { rememberCurrentPosition() }
        }
    }

    private func rememberCurrentPosition() {
        let frame = panel.frame.insetBy(dx: cardGlassMargin, dy: cardGlassMargin)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screen(containing: center), let identifier = screenIdentifier(screen) else {
            return
        }
        model.settings.rememberCardPosition(
            CardPlacement.remember(
                frame: frame,
                on: CardPlacementScreen(identifier: identifier, visibleFrame: screen.visibleFrame)))
    }

    func consumed(_ id: Candidate.ID) {
        guard let notice = currentNotice, ids.contains(id) else { return }
        let remaining = notice.candidates.filter { $0.id != id }
        if remaining.isEmpty {
            close()
        } else {
            currentNotice = ArrivalNotice(
                candidates: remaining,
                automaticCopyCandidateID: notice.automaticCopyCandidateID == id
                    ? nil : notice.automaticCopyCandidateID,
                automaticallyCopied: notice.automaticallyCopied,
                automaticCopyFeedback: notice.automaticCopyFeedback)
            ids = Set(remaining.map(\.id))
            updateVisibleStack()
        }
    }

    func reconcile() {
        guard let notice = currentNotice else { return }
        let live = Set(model.candidates.filter { $0.expiresAt > Date() }.map(\.id))
        let remaining = notice.candidates.filter { live.contains($0.id) }
        if remaining.isEmpty {
            close()
        } else if remaining.map(\.id) != notice.candidates.map(\.id) {
            currentNotice = ArrivalNotice(
                candidates: remaining,
                automaticCopyCandidateID: notice.automaticCopyCandidateID.flatMap {
                    live.contains($0) ? $0 : nil
                },
                automaticallyCopied: notice.automaticallyCopied,
                automaticCopyFeedback: notice.automaticCopyFeedback)
            ids = Set(remaining.map(\.id))
            updateVisibleStack()
        }
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        ids = []
        panel.orderOut(nil)
        currentNotice = nil
        host = nil
        panel.contentView = nil
    }

    func stop() {
        close()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }
}

private let cardGlassMargin: CGFloat = 24

private enum ArrivalDragPhase { case changed, ended }

private final class ArrivalCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ArrivalView: View {
    let model: AppModel
    let notice: ArrivalNotice
    let rankedCandidates: [RankedCandidate]
    let fillPossible: Bool
    let close: () -> Void
    let drag: (ArrivalDragPhase) -> Void
    @State private var feedback: [Candidate.ID: ArrivalFeedback] = [:]
    @State private var automaticFeedbackVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("新到验证码").font(.caption.weight(.semibold))
                Text("· \(notice.candidates.count)").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if automaticFeedbackVisible, notice.automaticallyCopied,
                    let message = notice.automaticCopyFeedback
                {
                    Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭验证码提示")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in drag(.changed) }
                    .onEnded { _ in drag(.ended) }
            )
            .help("拖动以移开提示")
            ForEach(rankedCandidates.prefix(5)) { ranked in
                row(ranked.candidate, matchesCurrentSite: ranked.matchesCurrentSite)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            let overflow = max(0, notice.candidates.count - 5)
            if overflow > 0 {
                Text("还有 \(overflow) 条 · 在菜单栏查看")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .center)
            }
        }
        .padding(6)
        .frame(width: 350)
        // Same glass as the MenuBarExtra panel; no interactive variant.
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        // Liquid Glass draws its rim and shadow outside the shape; leave room so the window edge does not clip it.
        .padding(cardGlassMargin)
        .animation(.snappy(duration: 0.22), value: notice.candidates.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mail Code Filler 验证码堆叠提示")
        .task(id: notice.automaticCopyCandidateID) {
            guard notice.automaticCopyCandidateID != nil,
                notice.automaticCopyFeedback != nil
            else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            automaticFeedbackVisible = false
        }
    }

    private func row(_ candidate: Candidate, matchesCurrentSite: Bool) -> some View {
        let cardAction = model.settings.actionForCodeCard(writableTargetAvailable: fillPossible)
        let sender = SenderIdentity(fromHeader: candidate.source)
        return ArrivalRow(
            candidate: candidate, sender: sender, action: cardAction,
            secondary: secondaryText(for: candidate), matchesCurrentSite: matchesCurrentSite
        ) {
            activate(candidate)
        }
        .accessibilityLabel(
            accessibilityLabel(for: candidate, sender: sender, link: candidate.loginLink, action: cardAction)
                + (matchesCurrentSite ? "，匹配当前网站" : "")
        )
        .accessibilityHint(accessibilityHint(for: candidate, action: cardAction))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func secondaryText(for candidate: Candidate) -> String {
        if let message = feedback[candidate.id]?.message { return message }
        if automaticFeedbackVisible, notice.automaticCopyCandidateID == candidate.id,
            let message = notice.automaticCopyFeedback
        {
            return message
        }
        let mail = candidate.subject.isEmpty ? "邮件" : candidate.subject
        let age = candidate.receivedAt.formatted(.relative(presentation: .named))
        let mailbox = model.receivingMailbox(for: candidate).map { " · \($0)" } ?? ""
        return "\(mail) · \(age)\(mailbox)"
    }

    private func accessibilityLabel(
        for candidate: Candidate, sender: SenderIdentity, link: SignInLink?, action: CodeCardClickAction
    ) -> String {
        let origin = "\(sender.displayName)，\(sender.registrableDomain ?? "域名未知")"
        if let link {
            return "\(link.purpose.actionLabel)，主机 \(link.host)，来自 \(origin)"
        }
        return "\(action == .fill ? "填入" : "复制")验证码 \(candidate.code ?? "")，来自 \(origin)"
    }

    private func accessibilityHint(for candidate: Candidate, action: CodeCardClickAction) -> String {
        if let link = candidate.loginLink {
            return "在默认浏览器打开此 HTTPS\(link.purpose.displayName)"
        }
        return action == .fill ? "插入当前输入框，不会提交表单" : "复制后可在输入框按 Command V 粘贴"
    }

    private func activate(_ candidate: Candidate) {
        let id = candidate.id
        let token = UUID()
        feedback[id] = ArrivalFeedback(token: token, message: "正在处理…")
        Task {
            let result = await model.fillOrCopy(id, writableTargetAvailable: fillPossible)
            feedback[id] = ArrivalFeedback(token: token, message: result.feedback)
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard feedback[id]?.token == token else { return }
            feedback[id] = nil
        }
    }
}

private struct ArrivalFeedback {
    let token: UUID
    let message: String
}

/// A row styled like a system menu item: the selection fills with the accent color and text turns white.
private struct ArrivalRow: View {
    let candidate: Candidate
    let sender: SenderIdentity
    let action: CodeCardClickAction
    let secondary: String
    let matchesCurrentSite: Bool
    let perform: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                SenderAvatar(identity: sender, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(sender.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(sender.registrableDomain ?? "域名未知")
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryStyle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(secondary)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if matchesCurrentSite {
                        Text("匹配当前网站")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(secondaryStyle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    if let link = candidate.loginLink {
                        Text(link.purpose.actionLabel)
                            .font(.system(size: 12, weight: .semibold))
                        Text(link.host)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(secondaryStyle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let code = candidate.code {
                        Text(code)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(action == .fill ? "填入" : "复制")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(secondaryStyle)
                    }
                }
            }
            .foregroundStyle(hovered ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                // 16pt glass minus 6pt inset keeps the corners concentric.
                if hovered { RoundedRectangle(cornerRadius: 10).fill(Color.accentColor) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var secondaryStyle: AnyShapeStyle {
        hovered ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }
}
