import CRaylib

let background = CRaylib.Color(r: 245, g: 245, b: 245, a: 255)
let image = GenImageColor(8, 8, background)
precondition(IsImageValid(image))
UnloadImage(image)
precondition(Vector2Length(Vector2(x: 3, y: 4)) == 5)

// Four samples of silence in a 16-bit mono PCM wave.
let pcmWave: [UInt8] = [
    0x52, 0x49, 0x46, 0x46, 44, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
    0x66, 0x6d, 0x74, 0x20, 16, 0, 0, 0, 1, 0, 1, 0,
    0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0,
    0x64, 0x61, 0x74, 0x61, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]
let wave = pcmWave.withUnsafeBufferPointer { samples in
    LoadWaveFromMemory(".wav", samples.baseAddress, Int32(samples.count))
}
precondition(IsWaveValid(wave) && wave.frameCount == 4)
UnloadWave(wave)

if CommandLine.arguments.contains("--window") {
    InitWindow(320, 240, "raylib SwiftPM smoke test")
    precondition(IsWindowReady())
    defer { CloseWindow() }

    for _ in 0..<3 {
        precondition(!WindowShouldClose())
        BeginDrawing()
        ClearBackground(background)
        EndDrawing()
    }
    print("Rendered three frames")
}

print("raylib image, math, and audio checks passed")
