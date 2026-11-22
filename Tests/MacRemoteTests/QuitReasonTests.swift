import CoreServices
import Foundation
import Testing
@testable import MacRemote

struct QuitReasonTests {
    private func quitEvent(reason: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let reason {
            event.setAttribute(
                NSAppleEventDescriptor(typeCode: reason),
                forKeyword: AEKeyword(kAEQuitReason)
            )
        }
        return event
    }

    /// D80 — logout, restart, and shutdown quit without the dialog.
    @Test(arguments: [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown])
    func sessionEndingReasonsSkipTheDialog(reason: OSType) {
        #expect(QuitReason.isSessionEnding(quitEvent(reason: reason)))
    }

    /// Command-Q has no Apple event; a quit from the Dock or a script has no reason.
    @Test func ordinaryQuitsStillAsk() {
        #expect(!QuitReason.isSessionEnding(nil))
        #expect(!QuitReason.isSessionEnding(quitEvent(reason: nil)))
    }
}
