// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HeyClickyClone",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
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
