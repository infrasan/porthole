import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut via Carbon's RegisterEventHotKey — the one
/// hotkey API that works without Accessibility permissions. ⌃⌥P toggles the
/// panel from anywhere.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    static let keyCode = UInt32(kVK_ANSI_P)
    static let modifiers = UInt32(controlKey | optionKey)
    static let display = "⌃⌥P"

    var onFire: (() -> Void)?
    private(set) var error: String?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "hotkeyEnabled")
            newValue ? register() : unregister()
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func registerIfEnabled() {
        if isEnabled { register() }
    }

    private func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in manager.onFire?() }
            return noErr
        }, 1, &spec, selfPointer, &handlerRef)
        let id = EventHotKeyID(signature: 0x50544C31, id: 1) // 'PTL1'
        let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        error = handlerStatus == noErr && status == noErr ? nil : "The global shortcut is unavailable. Another app may be using it."
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
