// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "raylib",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "raylib", type: .static, targets: ["CRaylib"]),
        .library(name: "RaylibAppleHost", type: .static, targets: ["RaylibAppleHost"]),
    ],
    targets: [
        .target(
            name: "CRaylib",
            path: "SwiftPackage/CRaylib",
            cSettings: [
                .headerSearchPath("../../src"),
                .define("PLATFORM_APPLE_SWIFTUI"),
                .define("GRAPHICS_API_OPENGL_33", .when(platforms: [.macOS])),
                .define("GRAPHICS_API_OPENGL_ES3", .when(platforms: [.iOS, .tvOS])),
                .define("GL_SILENCE_DEPRECATION"),
                .define("GLES_SILENCE_DEPRECATION"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("GameController"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("OpenGL", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("OpenGLES", .when(platforms: [.iOS, .tvOS])),
            ]
        ),
        .target(
            name: "RaylibAppleHost",
            dependencies: ["CRaylib"],
            path: "projects/Xcode/AppleAppSupport",
            exclude: ["Archive.c", "AppleGameHost.h", "AppleGameHost.m", "Info.plist", "Info-tvOS.plist",
                      "Launch.c", "StandaloneExample.c", "StandaloneGLFW.m"],
            sources: ["ContentView.swift"]
        ),
    ],
    cLanguageStandard: .gnu11
)
