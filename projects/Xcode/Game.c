#include "raylib.h"

int main(void)
{
    SetConfigFlags(FLAG_WINDOW_RESIZABLE);
    InitWindow(800, 450, "RaylibProject");
    if (!IsWindowReady()) return 1;

    while (!WindowShouldClose())
    {
        BeginDrawing();
        ClearBackground(BLACK);
        EndDrawing();
    }

    CloseWindow();
    return 0;
}
