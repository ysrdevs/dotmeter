import AppKit
import CoreServices

/// Asks the Finder to move an item to the Trash. This is what dragging it there does, down to the Finder's own
/// request for an administrator's name and password when the item belongs to the system, as an app from the App
/// Store or an installer does. Dotmeter never sees what is typed there.
///
/// One app directing another needs the user's consent, which macOS asks for the first time (Privacy & Security,
/// Automation). The Info.plist says why, and the notarized build carries the entitlement that lets it ask.
enum FinderTrash {
    enum Refusal: Error, Equatable {
        /// The user has not allowed Dotmeter to direct the Finder.
        case notAllowed
        /// The user backed out of the Finder's password dialog.
        case cancelled
        case failed(Int, String?)
    }

    /// Blocks while a consent or password dialog is up, so never call it on the main thread.
    static func moveToTrash(_ url: URL) throws {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        // Ask for consent now, in the open, instead of letting the event fail.
        let consent = AEDeterminePermissionToAutomateTarget(finder.aeDesc, typeWildCard, typeWildCard, true)
        if consent == OSStatus(errAEEventNotPermitted) { throw Refusal.notAllowed }
        guard consent == noErr else { throw Refusal.failed(Int(consent), nil) }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete), targetDescriptor: finder,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: keyDirectObject)
        do {
            // Ten minutes: the Finder answers only once any password dialog has been dealt with.
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 600)
            if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 {
                throw refusal(Int(code), reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue)
            }
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw refusal((error as NSError).code, (error as NSError).localizedFailureReason)
        }
        if FileManager.default.fileExists(atPath: url.path) { throw Refusal.failed(0, "The Finder reported no error, but the item is still there.") }
    }

    private static func refusal(_ code: Int, _ text: String?) -> Refusal {
        switch code {
        case Int(errAEEventNotPermitted): return .notAllowed
        case Int(userCanceledErr): return .cancelled
        default: return .failed(code, text)
        }
    }
}
