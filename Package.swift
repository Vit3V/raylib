// swift-tools-version: 5.9
import PackageDescription

let applePlatforms: [Platform] = [.macOS, .iOS, .tvOS]
let glfwPlatforms: [Platform] = [.windows, .linux]

var products: [Product] = [
    .library(name: "raylib", type: .static, targets: ["CRaylib"]),
]
var targets: [Target] = [
    .target(
        name: "CRaylib",
        dependencies: [
            .target(name: "RaylibAppleBridge", condition: .when(platforms: applePlatforms)),
            .target(name: "AndroidNativeAppGlue", condition: .when(platforms: [.android])),
        ],
        path: "projects/SwiftPackage/CRaylib",
        cSettings: [
            .headerSearchPath("../../../src/external/glfw/include", .when(platforms: glfwPlatforms)),
            .define("PLATFORM_APPLE_SWIFTUI", .when(platforms: applePlatforms)),
            .define("PLATFORM_DESKTOP_GLFW", .when(platforms: glfwPlatforms)),
            .define("PLATFORM_ANDROID", .when(platforms: [.android])),
            .define("GRAPHICS_API_OPENGL_33", .when(platforms: [.macOS, .windows, .linux])),
            .define("GRAPHICS_API_OPENGL_ES3", .when(platforms: [.iOS, .tvOS])),
            .define("GRAPHICS_API_OPENGL_ES2", .when(platforms: [.android])),
            .define("_GLFW_X11", .when(platforms: [.linux])),
            .define("_CRT_SECURE_NO_WARNINGS", .when(platforms: [.windows])),
            .define("GL_SILENCE_DEPRECATION", .when(platforms: [.macOS])),
            .define("GLES_SILENCE_DEPRECATION", .when(platforms: [.iOS, .tvOS])),
        ],
        linkerSettings: [
            .linkedLibrary("opengl32", .when(platforms: [.windows])),
            .linkedLibrary("gdi32", .when(platforms: [.windows])),
            .linkedLibrary("user32", .when(platforms: [.windows])),
            .linkedLibrary("winmm", .when(platforms: [.windows])),
            .linkedLibrary("shell32", .when(platforms: [.windows])),
            .linkedLibrary("GL", .when(platforms: [.linux])),
            .linkedLibrary("X11", .when(platforms: [.linux])),
            .linkedLibrary("pthread", .when(platforms: [.linux])),
            .linkedLibrary("dl", .when(platforms: [.linux])),
            .linkedLibrary("rt", .when(platforms: [.linux])),
            .linkedLibrary("m", .when(platforms: [.linux, .android])),
            .linkedLibrary("EGL", .when(platforms: [.android])),
            .linkedLibrary("GLESv2", .when(platforms: [.android])),
            .linkedLibrary("OpenSLES", .when(platforms: [.android])),
        ]
    ),
    .target(
        name: "RaylibAppleBridge",
        path: "projects/SwiftPackage/RaylibAppleBridge",
        cSettings: [
            .headerSearchPath("../../../src"),
            .define("GL_SILENCE_DEPRECATION", .when(platforms: [.macOS])),
            .define("GLES_SILENCE_DEPRECATION", .when(platforms: [.iOS, .tvOS])),
        ],
        linkerSettings: [
            .linkedFramework("Foundation", .when(platforms: applePlatforms)),
            .linkedFramework("GameController", .when(platforms: applePlatforms)),
            .linkedFramework("QuartzCore", .when(platforms: applePlatforms)),
            .linkedFramework("AudioToolbox", .when(platforms: applePlatforms)),
            .linkedFramework("AVFoundation", .when(platforms: applePlatforms)),
            .linkedFramework("CoreFoundation", .when(platforms: applePlatforms)),
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
        name: "AndroidNativeAppGlue",
        path: "projects/SwiftPackage/AndroidNativeAppGlue",
        exclude: ["LICENSE", "README.md"],
        linkerSettings: [
            .linkedLibrary("android", .when(platforms: [.android])),
            .linkedLibrary("log", .when(platforms: [.android])),
        ]
    ),
]

#if os(macOS)
products.append(.library(name: "RaylibAppleHost", type: .static, targets: ["RaylibAppleHost"]))
targets.append(.target(
    name: "RaylibAppleHost",
    dependencies: [
        "CRaylib",
        .target(name: "RaylibAppleBridge", condition: .when(platforms: applePlatforms)),
    ],
    path: "projects/Xcode/AppleAppSupport",
    exclude: ["AppleGameHost.h", "AppleGameHost.m", "Info.plist", "Info-tvOS.plist",
              "Launch.c", "StandaloneExample.c", "StandaloneGLFW.m"],
    sources: ["ContentView.swift"]
))
#endif

let package = Package(
    name: "raylib",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: products,
    targets: targets,
    cLanguageStandard: .gnu11
)
