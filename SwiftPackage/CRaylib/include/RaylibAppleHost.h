#ifndef RAYLIB_APPLE_HOST_H
#define RAYLIB_APPLE_HOST_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call once, from the main thread. The host calls game on its rendering thread.
typedef int (*RaylibGameEntry)(void);
void RaylibRunSwiftUIApp(RaylibGameEntry game, bool manualFrameControl);

#ifdef __cplusplus
}
#endif

#endif
