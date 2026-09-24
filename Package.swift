// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailCodeCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailCodeCore", targets: ["MailCodeCore"]),
        .library(name: "MailCodeGmail", targets: ["MailCodeGmail"]),
        .library(name: "MailCodeAutoFill", targets: ["MailCodeAutoFill"]),
    ],
    dependencies: [
        // IMAP grammar alone is not a client. SwiftMail 1.12.0 is the one production
        // dependency: EXAMINE, BODY.PEEK, IDLE, INTERNALDATE, and MIME. Exact pin.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", exact: "1.12.0"),
        // Already resolved through SwiftMail. Imported so its default stderr logger
        // can be replaced for SwiftMail labels before any mailbox command runs.
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
    ],
    targets: [
        .target(name: "MailCodeCore", path: "Sources/Core", resources: [.process("Resources")]),
        .target(name: "MailCodeAutoFill", dependencies: ["MailCodeCore"], path: "Sources/AutoFill"),
        .testTarget(name: "MailCodeAutoFillTests", dependencies: ["MailCodeAutoFill", "MailCodeCore"]),
        .target(
            name: "MailCodeGmail",
            dependencies: [
                "MailCodeCore",
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Gmail"
        ),
        .testTarget(name: "MailCodeCoreTests", dependencies: ["MailCodeCore"]),
        .testTarget(
            name: "MailCorpusTests",
            dependencies: ["MailCodeGmail", "MailCodeCore"],
            path: "Tests/Fixtures",
            resources: [.process("mail-corpus")]
        ),
        .testTarget(
            name: "MailCodeGmailTests",
            dependencies: [
                "MailCodeGmail",
                "MailCodeCore",
                .product(name: "SwiftMail", package: "SwiftMail"),
            ],
            path: "Tests/MailCodeGmailTests"
        ),
    ]
)
