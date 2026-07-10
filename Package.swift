// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Reminder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Reminder", targets: ["ReminderApp"])
    ],
    targets: [
        .executableTarget(
            name: "ReminderApp",
            path: "Sources/ReminderApp"
        )
    ]
)
