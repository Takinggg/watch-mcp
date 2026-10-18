import Carbon
import Foundation

/// A system-wide shortcut registered with Carbon's RegisterEventHotKey.
/// Unlike a global key monitor, this needs no Accessibility permission.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var onPress: (@MainActor () -> Void)?

    /// Returns nil when the shortcut is already taken by another app.
    init?(_ spec: HotKeySpec, onPress: @escaping @MainActor () -> Void) {
        HotKey.onPress = onPress
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated { HotKey.onPress?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5754_4352), id: 1) // "WTCR"
        let registered = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
