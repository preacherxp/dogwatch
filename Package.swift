// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Dogwatch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Dogwatch", targets: ["Dogwatch"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .executableTarget(
            name: "Dogwatch",
            dependencies: ["CSQLite"],
            path: "Sources/Dogwatch"
        ),
        .testTarget(
            name: "DogwatchTests",
            dependencies: ["Dogwatch"],
            path: "Tests/DogwatchTests",
            // Read from the source tree by `Fixture`, so they aren't bundled.
            exclude: ["Fixtures"]
        )
    ]
)
