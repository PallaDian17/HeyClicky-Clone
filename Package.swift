// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HeyClickyClone",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "HeyClickyClone",
            dependencies: [
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
            ]
        ),
    ]
)
