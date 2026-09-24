import AppKit
import SwiftUI

@MainActor
final class ShortcutFeedbackController {
    enum Message: String {
        case filled = "验证码已填入 · 未提交表单"
        case copied = "无法安全填入，已复制 · 按 ⌘V 粘贴"
        case unavailable = "没有可用验证码"
        case failed = "未能完成操作，请检查输入框"
    }

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ message: Message) {
        dismissal?.cancel()
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.sharingType = .none
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(
            rootView: Text(message.rawValue)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: .rect(cornerRadius: 12)))
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 140, y: frame.maxY - 88))
        }
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.panel?.orderOut(nil) }
        }
    }

    func stop() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
