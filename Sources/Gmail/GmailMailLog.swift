import Logging

/// Process-wide logging bootstrap. SwiftMail keeps a private logger, so this
/// has to be installed before the first `IMAPServer`. The app does not bootstrap logging.
enum GmailMailLogging {
    /// One no-op handler. Its level stays `.critical` and `log` discards the event.
    private static let mailHandler = SwiftLogNoOpLogHandler()

    private static let installed: Void = {
        LoggingSystem.bootstrap { label in
            let folded = label.lowercased()
            if folded.contains("swiftmail") || folded.contains("swiftimap") {
                return mailHandler
            }
            return StreamLogHandler.standardError(label: label)
        }
    }()

    static func install() {
        _ = installed
    }
}
