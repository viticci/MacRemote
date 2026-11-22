import CoreServices
import Foundation

/// D80 — why macOS asked MacRemote to quit. When the session ends (logout,
/// restart, shutdown), loginwindow sends the quit Apple event with a reason
/// attached. Command-Q, the Quit menu items, and a plain quit from another
/// app or script carry none.
enum QuitReason {
    /// Every reason loginwindow attaches when the session is ending.
    private static let sessionEndingCodes: Set<OSType> = [
        kAELogOut,
        kAEReallyLogOut,
        kAEShowRestartDialog,
        kAERestart,
        kAEShowShutdownDialog,
        kAEShutDown,
    ]

    /// True when `event` is a quit sent because the session is ending. Pass
    /// `NSAppleEventManager.shared().currentAppleEvent` from inside
    /// `applicationShouldTerminate`; it is nil for a quit that came from
    /// inside the app.
    static func isSessionEnding(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        return sessionEndingCodes.contains(reason.typeCodeValue)
    }
}
