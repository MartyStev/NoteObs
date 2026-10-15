// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NoteObs",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NoteObs",
            path: "NoteObs",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "NoteObsTests",
            dependencies: ["NoteObs"]
        )
    ]
)


