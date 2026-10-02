// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-app-lifecycle",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppLifecycle", targets: ["AppLifecycle"]),
        .executable(name: "AppLifecycleRecoveryHelper", targets: ["AppLifecycleRecoveryHelper"])
    ],
    targets: [
        .target(name: "RecoveryCore"),
        .target(name: "AppLifecycle"),
        .executableTarget(name: "AppLifecycleRecoveryHelper", dependencies: ["RecoveryCore"]),
        .testTarget(name: "RecoveryCoreTests", dependencies: ["RecoveryCore"]),
        .testTarget(name: "AppLifecycleTests", dependencies: ["AppLifecycle"])
    ]
)
