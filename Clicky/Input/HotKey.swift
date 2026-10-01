import Carbon.HIToolbox

/// A global hotkey via Carbon `RegisterEventHotKey`.
/// Works without Accessibility / Input Monitoring permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var isEventHandlerInstalled = false
    private static let signature: OSType = 0x434C_4B59 // 'CLKY'

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void
    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// - Parameters:
    ///   - keyCode: e.g. `kVK_Space`
    ///   - modifiers: Carbon flags, e.g. `controlKey | optionKey | cmdKey` (0 for none)
    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1
    }

    var isRegistered: Bool { ref != nil }

    /// Returns false if the system refused (e.g. the combination is already taken).
    @discardableResult
    func register() -> Bool {
        guard ref == nil else { return true }
        HotKey.installEventHandlerIfNeeded()

        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }

        ref = newRef
        HotKey.handlers[id] = handler
        return true
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        HotKey.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !isEventHandlerInstalled else { return }
        isEventHandlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
