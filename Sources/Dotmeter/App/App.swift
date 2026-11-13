import Foundation
import DotmeterShared

/// The app's name and identifiers as the rest of the app uses them. See `AppIdentity`.
enum App {
    static let name = AppIdentity.name
    static let possessive = AppIdentity.possessive
    static let bundleID = AppIdentity.bundleID
    static let supportFolder = AppIdentity.supportFolder
}
