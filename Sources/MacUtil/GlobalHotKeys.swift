import Foundation
import Carbon.HIToolbox

/// Đăng ký phím tắt TOÀN HỆ THỐNG qua Carbon RegisterEventHotKey.
/// Chạy kể cả khi app ở nền / không focus, KHÔNG cần quyền Accessibility.
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    /// Đăng ký một hotkey. modifiers dùng cmdKey/shiftKey/optionKey/controlKey (Carbon).
    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x4D435554 /* 'MCUT' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            me.handlers[hkID.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}
