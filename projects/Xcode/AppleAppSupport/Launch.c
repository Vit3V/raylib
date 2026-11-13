#include "RaylibAppleHost.h"

extern int RaylibGameMain(void);

#ifndef RAYLIB_MANUAL_FRAME_CONTROL
    #define RAYLIB_MANUAL_FRAME_CONTROL 0
#endif

int main(void)
{
    RaylibRunSwiftUIApp(RaylibGameMain, RAYLIB_MANUAL_FRAME_CONTROL);
    return 0;
}
