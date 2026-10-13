// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoLPing",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LoLPing", targets: ["LoLPing"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "PingCore"),
        .executableTarget(name: "LoLPing", dependencies: ["PingCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "PingCoreChecks", dependencies: ["PingCore"], path: "Tests/PingCoreTests")
    ]
)
