#if os(Android)
import CRaylib

// NativeActivity starts raylib's android_main, which calls this game entry point.
@_cdecl("main")
public func raylibAndroidGameMain(
    _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    InitWindow(320, 240, "raylib SwiftPM smoke test")
    guard IsWindowReady() else { return 1 }
    defer { CloseWindow() }

    while !WindowShouldClose() {
        BeginDrawing()
        ClearBackground(CRaylib.Color(r: 245, g: 245, b: 245, a: 255))
        EndDrawing()
    }
    return 0
}
#endif
