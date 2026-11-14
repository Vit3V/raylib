// swift-tools-version: 5.9
import PackageDescription

let raylib = Target.Dependency.product(name: "raylib", package: "raylib")

let package = Package(
    name: "RaylibSmoke",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DesktopSmoke", targets: ["DesktopSmoke"]),
        .library(name: "AndroidSmoke", type: .dynamic, targets: ["AndroidSmoke"]),
    ],
    dependencies: [
        .package(name: "raylib", path: "../../.."),
    ],
    targets: [
        .executableTarget(name: "DesktopSmoke", dependencies: [raylib]),
        .target(name: "AndroidSmoke", dependencies: [raylib], linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "--undefined=ANativeActivity_onCreate",
                "-Xlinker", "--wrap=fopen",
                "-Xlinker", "--no-undefined",
            ], .when(platforms: [.android])),
        ]),
    ]
)
