import Carbon
import MailCodeCore

@MainActor
final class HotKey {
    private static let signature: OSType = 0x4D43_4650
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var activeBindings: (fill: ShortcutBinding, chooser: ShortcutBinding)?

    /// Existing single-shortcut call remains usable until the integrator wires both actions.
    func register(action: @escaping () -> Void) -> Bool {
        guard installHandler() else { return false }
        actions = [2: action]
        let result = register(ShortcutBinding.defaultChooser, id: 2)
        if !result { invalidate() }
        return result
    }

    func register(
        fill: @escaping () -> Void, chooser: @escaping () -> Void,
        bindings: (fill: ShortcutBinding, chooser: ShortcutBinding) =
            (.defaultFill, .defaultChooser)
    ) -> Bool {
        guard bindings.fill.isValid, bindings.chooser.isValid,
            !bindings.fill.conflicts(with: bindings.chooser), installHandler()
        else { return false }
        let previous = activeBindings
        let previousActions = actions
        unregisterAll()
        actions = [1: fill, 2: chooser]
        guard register(bindings.fill, id: 1), register(bindings.chooser, id: 2) else {
            unregisterAll()
            if let previous {
                actions = previousActions
                if register(previous.fill, id: 1), register(previous.chooser, id: 2) {
                    activeBindings = previous
                } else {
                    unregisterAll()
                    activeBindings = nil
                }
            } else {
                actions = [:]
                activeBindings = nil
            }
            return false
        }
        activeBindings = bindings
        return true
    }

    func invalidate() {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        actions = [:]
        activeBindings = nil
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            return MainActor.assumeIsolated {
                guard identifier.signature == HotKey.signature,
                    let action = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                        .actions[identifier.id]
                else { return OSStatus(eventNotHandledErr) }
                action()
                return noErr
            }
        }
        return InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &type,
            Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }

    private func register(_ binding: ShortcutBinding, id: UInt32) -> Bool {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(
            UInt32(binding.keyCode), binding.modifiers,
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &reference)
        guard result == noErr, let reference else { return false }
        references[id] = reference
        return true
    }

    private func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references = [:]
    }
}
