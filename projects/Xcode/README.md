# raylib with SwiftUI

Open **RaylibProject.xcodeproj** for a blank app or **RaylibExamples.xcodeproj** to run the examples. Choose a scheme and a Mac, iPhone, iPad, Apple TV, or simulator destination in Xcode. Device builds need a signing team. The minimum versions are macOS 14, iOS/iPadOS 17, and tvOS 17.

## Bring a C game

Replace `Game.c` with the game's `int main(void)` source. Keep the calls to `InitWindow()`, `WindowShouldClose()`, `BeginDrawing()`, `EndDrawing()`, and `CloseWindow()`. The source with `main` needs the existing per-file `-Dmain=RaylibGameMain` flag. Add any other C sources to the app target without that flag. If you move the project out of this checkout, update its references to the raylib source directory.

The C entry point and OpenGL calls run on the same rendering thread. Keep graphics and raylib input calls on that thread. Each iteration should check `WindowShouldClose()` so the host can pause and stop the loop at a frame boundary. The project hosts one active raylib surface per process. SwiftUI manages the window and app lifecycle.

The width and height passed to `InitWindow()` define the logical canvas. The host fits that canvas into the SwiftUI view and maps pointer and touch coordinates back to it. Use `GetRenderWidth()` and `GetRenderHeight()` for the drawable's physical pixel dimensions. `SetTargetFPS()` caps the display-synchronized loop, subject to the display's cadence.

Add a folder named `resources` to the app's **Copy Bundle Resources** phase as a folder reference. The host makes it available at `resources/` relative to the C working directory. Saves and screenshots go into the app's writable directory in Application Support on macOS and iOS, or Caches on tvOS. The hot-reload example copies its assets there so you can edit `resources/shaders/glsl330/reload.fs` on macOS or `glsl300/reload.fs` on UIKit.

## Examples and platform behavior

Run an individual example using its named scheme. The **All Examples** scheme builds every example app for the selected destination. Regenerate the projects after adding or removing an example and use `--check` to verify the generated files.

```sh
python3 projects/Xcode/generate_projects.py
python3 projects/Xcode/generate_projects.py --check
xcodebuild -project projects/Xcode/RaylibExamples.xcodeproj \
    -scheme 'All Examples' -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

The shared host uses the existing OpenGL 3.3 renderer in a 4.1 Core context on macOS and the existing OpenGL ES 3.0 renderer on iOS and tvOS. Apple deprecates these APIs. The compute example needs OpenGL 4.3, and the standalone GLFW example runs on macOS. Examples whose defining feature is unavailable show an explanation on the affected destinations.

Touch on iOS also drives the primary mouse button. On tvOS, use the Siri Remote's directions, Select, and Play/Pause as arrow keys, Enter, and Space. Back/Menu follows system navigation. Extended GameController profiles supply buttons and axes on all three platforms. Examples that rely on particular desktop keys or pointer motion are best exercised on macOS. The hosted backend exposes system clipboard and file drops where the OS supports them. Controller rumble and custom controller mappings are currently unavailable.
