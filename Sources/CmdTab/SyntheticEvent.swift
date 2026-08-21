import CoreGraphics

/// Marks the mouse events this app posts itself, so its own gestures can tell them from a hand on
/// the mouse.
///
/// `DesktopMover` performs a genuine drag — that is the only way to move a window between Desktops
/// at all — and a genuine drag is indistinguishable from the user's own to everything watching for
/// one. Two things here are watching: `DragSnap`'s global `NSEvent` monitors and
/// `MouseWindowDrag`'s event tap. Left alone, dragging a window up to Mission Control's Spaces Bar
/// crosses the top-edge snap zone, and the drop that lands the window on another Desktop reads to
/// `DragSnap` as "maximize this" — so the window arrives resized, or inset by the tiling gap, which
/// is not what "move to the next desktop" promised.
///
/// A marker on the event rather than each watcher trying to recognise the gesture by its shape:
/// there is no reliable shape to recognise, and every watcher would have to be taught the same
/// heuristic and kept in step with it. The sender knows for certain, so the sender says so.
///
/// `eventSourceUserData` carries it. It is a field for exactly this — an arbitrary 64-bit value
/// that rides along on a `CGEvent` and survives the trip through the window server — and it is not
/// otherwise used by this app or, in practice, by anything else. A real event from real hardware
/// carries 0 here.
enum SyntheticEvent {
    /// Arbitrary, and deliberately not a small number: 0 is what an ordinary event carries, and a
    /// low value is what something else would pick if it ever started using this field.
    private static let marker: Int64 = 0x0C3D_7AB1_0000_0001

    /// Stamps an event as this app's own.
    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    /// Whether this app posted the event itself. A watcher that acts on user gestures should ignore
    /// anything this returns true for.
    static func isOurs(_ event: CGEvent?) -> Bool {
        guard let event else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
