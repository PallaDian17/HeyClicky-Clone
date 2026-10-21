// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HeyClickyClone",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.30.0"),
    ],
    targets: [
        // Pure logic, no AppKit: the privacy gate and its redaction rules.
        .target(
            name: "ClickyPrivacy",
            path: "apps/mac/Sources/ClickyPrivacy"
        ),
        // Checks for the privacy gate. An executable rather than a test target
        // because Command Line Tools ship neither XCTest nor Swift Testing:
        //   swift run privacy-checks
        .executableTarget(
            name: "privacy-checks",
            dependencies: ["ClickyPrivacy"],
            path: "apps/mac/Checks/PrivacyChecks"
        ),
        .executableTarget(
            name: "HeyClickyClone",
            dependencies: [
                "ClickyPrivacy",
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "apps/mac/Sources/HeyClickyClone",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("IOKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
