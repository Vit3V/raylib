/**********************************************************************************************
*
*   raylib - Interface between the Apple backend and its SwiftUI host
*
*   This software is provided under the zlib/libpng license. See LICENSE for details.
*
**********************************************************************************************/

#ifndef RCORE_APPLE_H
#define RCORE_APPLE_H

#include <stdbool.h>

enum { APPLE_MAX_DISPLAYS = 16 };

typedef struct AppleDisplay {
    float x;
    float y;
    int width;
    int height;
    int physicalWidth;
    int physicalHeight;
    int refreshRate;
    char name[128];
} AppleDisplay;

typedef struct AppleFrame {
    double timestamp;
    double interval;
    int width;
    int height;
    float pointWidth;
    float pointHeight;
    int displayCount;
    int displayIndex;
    float windowX;
    float windowY;
    unsigned int windowFlags;
    AppleDisplay displays[APPLE_MAX_DISPLAYS];
    unsigned int framebuffer;
    bool focused;
} AppleFrame;

typedef enum AppleInputType {
    APPLE_INPUT_KEY, APPLE_INPUT_TEXT, APPLE_INPUT_MOUSE_POSITION, APPLE_INPUT_MOUSE_BUTTON,
    APPLE_INPUT_MOUSE_SCROLL, APPLE_INPUT_TOUCH, APPLE_INPUT_GAMEPAD_CONNECT,
    APPLE_INPUT_GAMEPAD_BUTTON, APPLE_INPUT_GAMEPAD_AXIS, APPLE_INPUT_RESET, APPLE_INPUT_DROP
} AppleInputType;

typedef struct AppleInputEvent {
    AppleInputType type;
    int index;
    int code;
    int action;
    float x;
    float y;
    char *text; // Ownership passes to the consumer
} AppleInputEvent;

typedef enum AppleWindowAction {
    APPLE_WINDOW_TITLE, APPLE_WINDOW_SIZE, APPLE_WINDOW_POSITION, APPLE_WINDOW_MONITOR, APPLE_WINDOW_MIN_SIZE,
    APPLE_WINDOW_MAX_SIZE, APPLE_WINDOW_FULLSCREEN, APPLE_WINDOW_BORDERLESS, APPLE_WINDOW_MINIMIZE, APPLE_WINDOW_MAXIMIZE,
    APPLE_WINDOW_RESTORE, APPLE_WINDOW_FOCUS, APPLE_WINDOW_OPACITY, APPLE_WINDOW_CURSOR,
    APPLE_WINDOW_CURSOR_MODE, APPLE_WINDOW_MOUSE_POSITION, APPLE_WINDOW_FLAGS
} AppleWindowAction;

// Called exclusively on the C entry point's rendering thread.
bool AppleWaitFrame(double minimumTimestamp, AppleFrame *frame);
bool AppleStopRequested(void);
bool AppleUsesManualFrameControl(void);
void ApplePresentFrame(void);
bool AppleNextInput(AppleInputEvent *event);
void *AppleWindowHandle(void);
void AppleSetWindow(AppleWindowAction action, float x, float y, const char *text);
void AppleOpenURL(const char *url);
void AppleSetClipboard(const char *text);
char *AppleCopyClipboard(bool image, int *size);

#endif
