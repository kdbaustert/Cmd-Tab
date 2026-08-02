import AppKit
import SwiftUI

/// Click, then press a combination to rebind the trigger. A modifier (⌘/⌥/⌃) is required, since the
/// switcher stays open only while that modifier is held.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : hotkey.displayString) {
            recording ? stop() : start()
        }
        // Narrower than before: these sit two rows to a line now, and one of them shares its cell
        // with an enable checkbox.
        .frame(width: 120)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags
            // Ignore Escape so there is a way to abort without binding it.
            if event.keyCode == 53 { stop(); return nil }
            let mods = Self.cgFlags(from: flags)
            // A hold-to-open hotkey needs a non-Shift modifier to hold.
            guard mods.intersection([.maskCommand, .maskAlternate, .maskControl]) != [] else {
                return nil
            }
            let candidate = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            // Off the handler: `stop()` removes the monitor currently executing this block, which
            // does not belong inside event dispatch.
            DispatchQueue.main.async {
                stop()
                hotkey = candidate
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }
}
