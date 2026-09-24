import AppKit
import MailCodeCore
import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    @Binding var binding: ShortcutBinding
    let otherBinding: ShortcutBinding
    var onRejected: (String) -> Void = { _ in }
    @State private var recording = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(recording ? "按下快捷键…" : binding.displayName) { recording = true }
                .background {
                    RecorderKeyView(isRecording: $recording, onCancel: { recording = false }) { event in
                        let modifiers = Self.carbonModifiers(event.modifierFlags)
                        let proposed = ShortcutBinding(keyCode: event.keyCode, modifiers: modifiers)
                        guard proposed.isValid else {
                            onRejected("请包含 Control 或 Command，并按一个非修饰键。")
                            return
                        }
                        guard !proposed.conflicts(with: otherBinding) else {
                            onRejected("两个动作不能使用同一个快捷键。")
                            return
                        }
                        binding = proposed
                        recording = false
                    }
                    .frame(width: 1, height: 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(binding.displayName)")
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= ShortcutBinding.control }
        if flags.contains(.option) { result |= ShortcutBinding.option }
        if flags.contains(.shift) { result |= ShortcutBinding.shift }
        if flags.contains(.command) { result |= ShortcutBinding.command }
        return result
    }
}

private struct RecorderKeyView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCancel: () -> Void
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onKey = onKey
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
        if isRecording { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
    }

    final class RecorderNSView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            onKey?(event)
        }
    }
}
