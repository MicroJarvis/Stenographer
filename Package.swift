// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Stenographer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Stenographer", targets: ["Stenographer"])
    ],
    targets: [
        .executableTarget(
            name: "Stenographer",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
