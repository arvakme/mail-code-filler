import Carbon

@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private static let identifier = EventHotKeyID(signature: 0x4D43_4650, id: 1)

    func register(action: @escaping () -> Void) -> Bool {
        self.action = action
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
            )
            guard result == noErr else { return result }
            // Carbon application-event handlers run on the main event loop.
            return MainActor.assumeIsolated {
                guard identifier.signature == HotKey.identifier.signature,
                    identifier.id == HotKey.identifier.id
                else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action?()
                return noErr
            }
        }
        guard
            InstallEventHandler(
                GetApplicationEventTarget(), callback, 1, &type,
                Unmanaged.passUnretained(self).toOpaque(), &handler
            ) == noErr
        else { return false }
        let result = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(controlKey | optionKey), Self.identifier,
            GetApplicationEventTarget(), 0, &reference
        )
        if result != noErr { invalidate() }
        return result == noErr
    }

    func invalidate() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        action = nil
    }
}
