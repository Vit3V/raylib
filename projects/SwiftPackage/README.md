# raylib with Swift Package Manager

Add this repository as a Swift package dependency and link the `raylib` product. Swift code uses `import CRaylib`. Both local checkouts and Git dependencies use the manifest at the repository root. The [Apple platform guide](../Xcode/README.md) covers the `RaylibAppleHost` product and the Xcode projects.

## Windows and Linux

On Windows, use the official Swift toolchain with the Visual C++ build tools and a Windows SDK. The package uses the bundled GLFW Win32 backend and needs a working OpenGL 3.3 driver to open a window. See [Swift’s Windows installation guide](https://www.swift.org/install/windows/manual/).

On Ubuntu 24.04, install Swift and the X11 and OpenGL development libraries. Wayland sessions need XWayland. See [Swift’s Ubuntu installation guide](https://www.swift.org/install/linux/ubuntu/24_04/).

```sh
sudo apt install libgl-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxext-dev
```

From the raylib checkout, run `swift build --product raylib` to build the library. To build and run a separate Swift consumer, use `swift run --package-path projects/SwiftPackage/Smoke DesktopSmoke --window`. The window check draws three frames and closes. Omit `--window` to test the image, math, and audio APIs without a display or audio device.

Use a regular Swift executable for a desktop game. Run windowing and drawing on its main thread.

```swift
import CRaylib

InitWindow(800, 450, "raylib")
if IsWindowReady() {
    SetTargetFPS(60)
    while !WindowShouldClose() {
        BeginDrawing()
        ClearBackground(CRaylib.Color(r: 245, g: 245, b: 245, a: 255))
        EndDrawing()
    }
    CloseWindow()
}
```

## Android

Install a matching open-source Swift toolchain and Swift SDK for Android on macOS or Linux, plus the Android NDK version required by that SDK. Set `ANDROID_NDK_HOME` to the NDK location and run the SDK bundle’s `swift-android/scripts/setup-android-sdk.sh` to link its sysroot. The commands below use Swift 6.4.2, NDK r30, and Android API 29. See [Swift’s Android SDK guide](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html) for the matching SDK installation command.

```sh
swift build --swift-sdk swift-6.4.2-RELEASE_android \
    --triple aarch64-unknown-linux-android29 --product raylib
swift build --package-path projects/SwiftPackage/Smoke \
    --swift-sdk swift-6.4.2-RELEASE_android \
    --triple aarch64-unknown-linux-android29 --product AndroidSmoke
```

Use `x86_64-unknown-linux-android29` for the `x86_64` ABI. `aarch64` maps to Android’s `arm64-v8a` ABI. The smoke fixture builds a shared library to verify linkage.

In an existing [NativeActivity app](https://developer.android.com/ndk/guides/concepts), build the game as a dynamic SwiftPM library that links the `raylib` product. Export a C-callable `main(int, char **)` from a Swift library source using `@_cdecl("main")`, as shown in the [Android smoke fixture](Smoke/Sources/AndroidSmoke/Game.swift). The NDK glue starts raylib’s `android_main` on its native activity thread, and raylib invokes the game function there. The package includes the NDK glue, so link it once.

Pass `-Xlinker --undefined=ANativeActivity_onCreate -Xlinker --wrap=fopen` to the Swift driver at the app’s final shared-library link. The first flag retains the symbol NativeActivity loads. The second preserves loading assets from the APK and writing files to the app’s internal data directory. The [smoke manifest](Smoke/Package.swift) shows how to set the flags on the consuming target.

Package the library under `lib/<abi>/` and set `android.app.lib_name` in the NativeActivity manifest to its name without the `lib` prefix or `.so` suffix. Include any Swift runtime libraries and `libc++_shared.so` required by the linked library for each ABI. The NDK’s `llvm-readelf -d` lists dynamic dependencies. Add game files under the APK’s `assets/` directory and use paths relative to it from raylib.
