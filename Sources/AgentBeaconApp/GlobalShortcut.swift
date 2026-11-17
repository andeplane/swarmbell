import AppKit
import Carbon

enum ShortcutChoice: String, CaseIterable, Identifiable {
  case controlOptionSpace, commandShiftSpace, controlShiftSpace, disabled
  var id: String { rawValue }
  var label: String {
    switch self {
    case .controlOptionSpace: "⌃⌥Space"
    case .commandShiftSpace: "⌘⇧Space"
    case .controlShiftSpace: "⌃⇧Space"
    case .disabled: "Disabled"
    }
  }
  var modifiers: UInt32 {
    switch self {
    case .controlOptionSpace: UInt32(controlKey | optionKey)
    case .commandShiftSpace: UInt32(cmdKey | shiftKey)
    case .controlShiftSpace: UInt32(controlKey | shiftKey)
    case .disabled: 0
    }
  }
}

private func beaconHotKeyCallback(
  _: EventHandlerCallRef?, _: EventRef?, pointer: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let pointer else { return OSStatus(eventNotHandledErr) }
  let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
  Task { @MainActor in shortcut.onTrigger?() }
  return noErr
}

@MainActor
final class GlobalShortcut {
  var onTrigger: (() -> Void)?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  func register(_ choice: ShortcutChoice) -> String? {
    unregister()
    guard choice != .disabled else { return nil }
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let result = InstallEventHandler(
      GetEventDispatcherTarget(), beaconHotKeyCallback, 1, &event,
      Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard result == noErr else { return "Could not register the global shortcut (\(result))." }
    let identifier = EventHotKeyID(signature: OSType(0x4147_4243), id: 1)
    let registration = RegisterEventHotKey(
      UInt32(kVK_Space), choice.modifiers, identifier,
      GetEventDispatcherTarget(), 0, &hotKey)
    guard registration == noErr else {
      unregister()
      return "\(choice.label) is unavailable. Choose another shortcut in Settings."
    }
    return nil
  }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
  }
}
