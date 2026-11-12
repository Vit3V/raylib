/**********************************************************************************************
*
*   raylib - Apple platform backend for a SwiftUI-hosted C game loop
*
*   This software is provided under the zlib/libpng license. See LICENSE for details.
*
**********************************************************************************************/

#include "rcore_apple.h"
#include <dlfcn.h>

static AppleFrame appleFrame;
static bool appleNeedsFrame;
static bool appleStopped;
static char *appleClipboardText;

static Size AppleViewportSize(void)
{
    return (Size){ CORE.Window.render.width - CORE.Window.renderOffset.x,
                   CORE.Window.render.height - CORE.Window.renderOffset.y };
}

static void AppleUpdateViewport(void)
{
    float scale = fminf((float)appleFrame.width/CORE.Window.screen.width,
                        (float)appleFrame.height/CORE.Window.screen.height);
    int width = (int)fmaxf(1, roundf(CORE.Window.screen.width*scale));
    int height = (int)fmaxf(1, roundf(CORE.Window.screen.height*scale));
    CORE.Window.renderOffset = (Point){ appleFrame.width - width, appleFrame.height - height };
    CORE.Window.render = (Size){ appleFrame.width, appleFrame.height };
    CORE.Window.currentFbo = AppleViewportSize();
}

static Vector2 AppleInputPosition(float x, float y)
{
    Size viewport = AppleViewportSize();
    float pixelX = x*appleFrame.width/appleFrame.pointWidth;
    float pixelY = y*appleFrame.height/appleFrame.pointHeight;
    return (Vector2){
        (pixelX - CORE.Window.renderOffset.x/2)*CORE.Window.screen.width/viewport.width,
        (pixelY - (CORE.Window.renderOffset.y + 1)/2)*CORE.Window.screen.height/viewport.height
    };
}

static void AppleGesture(int action, int count, const int *ids, const Vector2 *positions)
{
#if SUPPORT_GESTURES_SYSTEM
    GestureEvent event = { .touchAction = action };
    event.pointCount = count;
    for (int i = 0; i < count; i++)
    {
        event.pointId[i] = ids[i];
        event.position[i] = (Vector2){ positions[i].x/CORE.Window.screen.width,
                                       positions[i].y/CORE.Window.screen.height };
    }
    ProcessGestureEvent(event);
#endif
}

static void AppleTouch(AppleInputEvent event)
{
    int count = CORE.Input.Touch.pointCount;
    int index = 0;
    while ((index < count) && (CORE.Input.Touch.pointId[index] != event.index)) index++;
    if (index == count)
    {
        if ((event.action != 1) || (count == MAX_TOUCH_POINTS)) return;
        CORE.Input.Touch.pointId[index] = event.index;
        CORE.Input.Touch.currentTouchState[index] = 1;
        CORE.Input.Touch.pointCount = ++count;
    }

    Vector2 position = AppleInputPosition(event.x, event.y);
    CORE.Input.Touch.position[index] = position;
    if (index == 0) CORE.Input.Mouse.currentPosition = position;
    AppleGesture(event.action, count, CORE.Input.Touch.pointId, CORE.Input.Touch.position);

    if ((event.action == 0) || (event.action == 3))
    {
        for (int i = index; i + 1 < count; i++)
        {
            CORE.Input.Touch.position[i] = CORE.Input.Touch.position[i + 1];
            CORE.Input.Touch.pointId[i] = CORE.Input.Touch.pointId[i + 1];
        }
        CORE.Input.Touch.pointId[count - 1] = -1;
        CORE.Input.Touch.currentTouchState[count - 1] = 0;
        CORE.Input.Touch.pointCount--;
    }

    CORE.Input.Mouse.currentButtonState[MOUSE_BUTTON_LEFT] = CORE.Input.Touch.pointCount > 0;
    if (CORE.Input.Touch.pointCount > 0) CORE.Input.Mouse.currentPosition = CORE.Input.Touch.position[0];
}

static void AppleClearInput(void)
{
    memset(CORE.Input.Keyboard.currentKeyState, 0, sizeof(CORE.Input.Keyboard.currentKeyState));
    memset(CORE.Input.Mouse.currentButtonState, 0, sizeof(CORE.Input.Mouse.currentButtonState));
    memset(CORE.Input.Touch.currentTouchState, 0, sizeof(CORE.Input.Touch.currentTouchState));
    memset(CORE.Input.Gamepad.currentButtonState, 0, sizeof(CORE.Input.Gamepad.currentButtonState));
    memset(CORE.Input.Gamepad.axisState, 0, sizeof(CORE.Input.Gamepad.axisState));
    for (int i = 0; i < MAX_GAMEPADS; i++)
    {
        CORE.Input.Gamepad.axisState[i][GAMEPAD_AXIS_LEFT_TRIGGER] = -1.0f;
        CORE.Input.Gamepad.axisState[i][GAMEPAD_AXIS_RIGHT_TRIGGER] = -1.0f;
    }
    CORE.Input.Keyboard.keyPressedQueueCount = 0;
    CORE.Input.Keyboard.charPressedQueueCount = 0;
    CORE.Input.Mouse.currentWheelMove = (Vector2){ 0 };
    CORE.Input.Touch.pointCount = 0;
    for (int i = 0; i < MAX_TOUCH_POINTS; i++) CORE.Input.Touch.pointId[i] = -1;
    AppleGesture(3, 0, NULL, NULL);
}

void PollInputEvents(void)
{
#if SUPPORT_GESTURES_SYSTEM
    UpdateGestures();
#endif
    CORE.Input.Keyboard.keyPressedQueueCount = 0;
    CORE.Input.Keyboard.charPressedQueueCount = 0;
    CORE.Input.Gamepad.lastButtonPressed = GAMEPAD_BUTTON_UNKNOWN;
    memcpy(CORE.Input.Keyboard.previousKeyState, CORE.Input.Keyboard.currentKeyState, sizeof(CORE.Input.Keyboard.currentKeyState));
    memset(CORE.Input.Keyboard.keyRepeatInFrame, 0, sizeof(CORE.Input.Keyboard.keyRepeatInFrame));
    memcpy(CORE.Input.Mouse.previousButtonState, CORE.Input.Mouse.currentButtonState, sizeof(CORE.Input.Mouse.currentButtonState));
    memcpy(CORE.Input.Touch.previousTouchState, CORE.Input.Touch.currentTouchState, sizeof(CORE.Input.Touch.currentTouchState));
    memcpy(CORE.Input.Gamepad.previousButtonState, CORE.Input.Gamepad.currentButtonState, sizeof(CORE.Input.Gamepad.currentButtonState));
    CORE.Input.Mouse.previousPosition = CORE.Input.Mouse.currentPosition;
    CORE.Input.Mouse.previousWheelMove = CORE.Input.Mouse.currentWheelMove;
    CORE.Input.Mouse.currentWheelMove = (Vector2){ 0 };

    AppleInputEvent event;
    while (AppleNextInput(&event))
    {
        int code = event.code;
        int index = event.index;
        switch (event.type)
        {
            case APPLE_INPUT_KEY:
            {
                if ((code <= 0) || (code >= MAX_KEYBOARD_KEYS)) break;
                if (event.action == 2) CORE.Input.Keyboard.keyRepeatInFrame[code] = 1;
                else CORE.Input.Keyboard.currentKeyState[code] = event.action != 0;
                if (event.action == 1)
                {
                    if (CORE.Input.Keyboard.keyPressedQueueCount < MAX_KEY_PRESSED_QUEUE)
                        CORE.Input.Keyboard.keyPressedQueue[CORE.Input.Keyboard.keyPressedQueueCount++] = code;
                    if (code == CORE.Input.Keyboard.exitKey) CORE.Window.shouldClose = true;
                }
            } break;
            case APPLE_INPUT_TEXT:
            {
                if (CORE.Input.Keyboard.charPressedQueueCount < MAX_CHAR_PRESSED_QUEUE)
                    CORE.Input.Keyboard.charPressedQueue[CORE.Input.Keyboard.charPressedQueueCount++] = code;
            } break;
            case APPLE_INPUT_MOUSE_POSITION:
            {
                if (CORE.Input.Mouse.cursorLocked)
                {
                    Vector2 scale = GetWindowScaleDPI();
                    CORE.Input.Mouse.currentPosition.x += event.x*appleFrame.width/appleFrame.pointWidth/scale.x;
                    CORE.Input.Mouse.currentPosition.y += event.y*appleFrame.height/appleFrame.pointHeight/scale.y;
                }
                else CORE.Input.Mouse.currentPosition = AppleInputPosition(event.x, event.y);
                Vector2 mouse = CORE.Input.Mouse.currentPosition;
                CORE.Input.Mouse.cursorOnScreen = (mouse.x >= 0) && (mouse.y >= 0) &&
                                                  (mouse.x < CORE.Window.screen.width) && (mouse.y < CORE.Window.screen.height);
                if (CORE.Input.Touch.pointCount == 0) CORE.Input.Touch.position[0] = mouse;
#if SUPPORT_MOUSE_GESTURES
                int mouseId = 0;
                if (CORE.Input.Mouse.currentButtonState[MOUSE_BUTTON_LEFT]) AppleGesture(2, 1, &mouseId, &CORE.Input.Mouse.currentPosition);
#endif
            } break;
            case APPLE_INPUT_MOUSE_BUTTON:
            {
                if ((code < 0) || (code >= MAX_MOUSE_BUTTONS)) break;
                CORE.Input.Mouse.currentButtonState[code] = event.action != 0;
#if SUPPORT_MOUSE_GESTURES
                int mouseId = 0;
                if (code == MOUSE_BUTTON_LEFT) AppleGesture(event.action, 1, &mouseId, &CORE.Input.Mouse.currentPosition);
#endif
            } break;
            case APPLE_INPUT_MOUSE_SCROLL:
            {
                CORE.Input.Mouse.currentWheelMove.x += event.x;
                CORE.Input.Mouse.currentWheelMove.y += event.y;
            } break;
            case APPLE_INPUT_TOUCH: AppleTouch(event); break;
            case APPLE_INPUT_GAMEPAD_CONNECT:
            {
                if ((index < 0) || (index >= MAX_GAMEPADS)) break;
                CORE.Input.Gamepad.ready[index] = event.action != 0;
                CORE.Input.Gamepad.axisCount[index] = event.action? 6 : 0;
                snprintf(CORE.Input.Gamepad.name[index], MAX_GAMEPAD_NAME_LENGTH, "%s", event.text? event.text : "");
                memset(CORE.Input.Gamepad.currentButtonState[index], 0, sizeof(CORE.Input.Gamepad.currentButtonState[index]));
                memset(CORE.Input.Gamepad.previousButtonState[index], 0, sizeof(CORE.Input.Gamepad.previousButtonState[index]));
                memset(CORE.Input.Gamepad.axisState[index], 0, sizeof(CORE.Input.Gamepad.axisState[index]));
                CORE.Input.Gamepad.axisState[index][GAMEPAD_AXIS_LEFT_TRIGGER] = -1.0f;
                CORE.Input.Gamepad.axisState[index][GAMEPAD_AXIS_RIGHT_TRIGGER] = -1.0f;
            } break;
            case APPLE_INPUT_GAMEPAD_BUTTON:
            {
                if ((index < 0) || (index >= MAX_GAMEPADS) || (code < 0) || (code >= MAX_GAMEPAD_BUTTONS)) break;
                if (event.action && !CORE.Input.Gamepad.currentButtonState[index][code]) CORE.Input.Gamepad.lastButtonPressed = code;
                CORE.Input.Gamepad.currentButtonState[index][code] = event.action != 0;
            } break;
            case APPLE_INPUT_GAMEPAD_AXIS:
            {
                if ((index < 0) || (index >= MAX_GAMEPADS) || (code < 0) || (code >= MAX_GAMEPAD_AXES)) break;
                CORE.Input.Gamepad.axisState[index][code] = event.x;
            } break;
            case APPLE_INPUT_RESET: AppleClearInput(); break;
            case APPLE_INPUT_DROP:
            {
                char **files = RL_REALLOC(CORE.Window.dropFilepaths, (CORE.Window.dropFileCount + 1)*sizeof(char *));
                if (files != NULL)
                {
                    CORE.Window.dropFilepaths = files;
                    CORE.Window.dropFilepaths[CORE.Window.dropFileCount++] = event.text;
                    event.text = NULL;
                }
            } break;
        }
        free(event.text);
    }
}

bool WindowShouldClose(void)
{
    if (!CORE.Window.ready || appleStopped) return true;
    if (appleNeedsFrame)
    {
        AppleFrame next = { 0 };
        if (!AppleWaitFrame(appleFrame.timestamp + CORE.Time.target, &next))
        {
            appleStopped = true;
            return true;
        }

        CORE.Window.resizedLastFrame = (next.width != appleFrame.width) || (next.height != appleFrame.height) ||
                                       (next.pointWidth != appleFrame.pointWidth) || (next.pointHeight != appleFrame.pointHeight);
        CORE.Time.frame = next.interval;
        appleFrame = next;
        AppleDisplay display = next.displays[next.displayIndex];
        CORE.Window.display = (Size){ display.width, display.height };
        if (next.focused) FLAG_CLEAR(CORE.Window.flags, FLAG_WINDOW_UNFOCUSED);
        else FLAG_SET(CORE.Window.flags, FLAG_WINDOW_UNFOCUSED);
        rlAppleDrawableFramebuffer = next.framebuffer;
        if (CORE.Window.resizedLastFrame)
        {
            AppleUpdateViewport();
            SetupViewport(next.width, next.height);
            rlSetFramebufferWidth(next.width);
            rlSetFramebufferHeight(next.height);
        }
        appleNeedsFrame = false;
#if !SUPPORT_CUSTOM_FRAME_CONTROL
        PollInputEvents();
#endif
    }
    bool requested = CORE.Window.shouldClose;
    CORE.Window.shouldClose = false;
    return requested || AppleStopRequested();
}

void SwapScreenBuffer(void)
{
    ApplePresentFrame();
    appleNeedsFrame = true;
}

double GetTime(void)
{
    return (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC) - CORE.Time.base)*1e-9;
}

#if defined(GRAPHICS_API_OPENGL_33)
static void *AppleGetProcAddress(const char *name) { return dlsym(RTLD_DEFAULT, name); }
#endif

int InitPlatform(void)
{
    appleStopped = false;
    if (!AppleWaitFrame(0, &appleFrame)) return -1;

    if (CORE.Window.screen.width == 0) CORE.Window.screen.width = (unsigned int)appleFrame.pointWidth;
    if (CORE.Window.screen.height == 0) CORE.Window.screen.height = (unsigned int)appleFrame.pointHeight;
    AppleDisplay display = appleFrame.displays[appleFrame.displayIndex];
    CORE.Window.display = (Size){ display.width, display.height };
    AppleUpdateViewport();
    rlAppleDrawableFramebuffer = appleFrame.framebuffer;
#if defined(GRAPHICS_API_OPENGL_33)
    rlLoadExtensions((void *)AppleGetProcAddress);
#else
    rlLoadExtensions(NULL);
#endif
    CORE.Time.base = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    InitTimer();
    CORE.Storage.basePath = GetWorkingDirectory();
    CORE.Window.ready = true;
    appleNeedsFrame = true;
    AppleClearInput();
    AppleSetWindow(APPLE_WINDOW_TITLE, 0, 0, CORE.Window.title);
    AppleSetWindow(APPLE_WINDOW_FLAGS, (float)CORE.Window.flags, 0, NULL);
    return 0;
}

void ClosePlatform(void)
{
    if (CORE.Window.dropFileCount > 0) UnloadDroppedFiles(LoadDroppedFiles());
    free(appleClipboardText);
    appleClipboardText = NULL;
    rlAppleDrawableFramebuffer = 0;
}

void ToggleFullscreen(void)
{
    FLAG_TOGGLE(CORE.Window.flags, FLAG_FULLSCREEN_MODE);
    AppleSetWindow(APPLE_WINDOW_FULLSCREEN, 0, 0, NULL);
}
void ToggleBorderlessWindowed(void)
{
    FLAG_TOGGLE(CORE.Window.flags, FLAG_BORDERLESS_WINDOWED_MODE);
    AppleSetWindow(APPLE_WINDOW_BORDERLESS, FLAG_IS_SET(CORE.Window.flags, FLAG_BORDERLESS_WINDOWED_MODE), 0, NULL);
}
void MaximizeWindow(void)
{
    FLAG_SET(CORE.Window.flags, FLAG_WINDOW_MAXIMIZED);
    AppleSetWindow(APPLE_WINDOW_MAXIMIZE, 0, 0, NULL);
}
void MinimizeWindow(void)
{
    FLAG_SET(CORE.Window.flags, FLAG_WINDOW_MINIMIZED);
    AppleSetWindow(APPLE_WINDOW_MINIMIZE, 0, 0, NULL);
}
void RestoreWindow(void)
{
    FLAG_CLEAR(CORE.Window.flags, FLAG_WINDOW_MINIMIZED | FLAG_WINDOW_MAXIMIZED);
    AppleSetWindow(APPLE_WINDOW_RESTORE, 0, 0, NULL);
}
void SetWindowState(unsigned int flags)
{
    FLAG_SET(CORE.Window.flags, flags);
    AppleSetWindow(APPLE_WINDOW_FLAGS, (float)CORE.Window.flags, 0, NULL);
}
void ClearWindowState(unsigned int flags)
{
    FLAG_CLEAR(CORE.Window.flags, flags);
    AppleSetWindow(APPLE_WINDOW_FLAGS, (float)CORE.Window.flags, 0, NULL);
}
void SetWindowIcon(Image image) { (void)image; }
void SetWindowIcons(Image *images, int count) { (void)images; (void)count; }
void SetWindowTitle(const char *title) { AppleSetWindow(APPLE_WINDOW_TITLE, 0, 0, title); }
void SetWindowPosition(int x, int y)
{
    CORE.Window.position = (Point){ x, y };
    AppleSetWindow(APPLE_WINDOW_POSITION, x, y, NULL);
}
void SetWindowMonitor(int monitor)
{
    if (monitor >= 0 && monitor < appleFrame.displayCount) AppleSetWindow(APPLE_WINDOW_MONITOR, monitor, 0, NULL);
}
void SetWindowMinSize(int width, int height) { AppleSetWindow(APPLE_WINDOW_MIN_SIZE, width, height, NULL); }
void SetWindowMaxSize(int width, int height) { AppleSetWindow(APPLE_WINDOW_MAX_SIZE, width, height, NULL); }
void SetWindowSize(int width, int height)
{
    if ((width <= 0) || (height <= 0)) return;
    CORE.Window.screen = (Size){ width, height };
    AppleUpdateViewport();
    SetupViewport(appleFrame.width, appleFrame.height);
    CORE.Window.resizedLastFrame = true;
    AppleSetWindow(APPLE_WINDOW_SIZE, width, height, NULL);
}
void SetWindowOpacity(float opacity) { AppleSetWindow(APPLE_WINDOW_OPACITY, opacity, 0, NULL); }
void SetWindowFocused(void) { AppleSetWindow(APPLE_WINDOW_FOCUS, 0, 0, NULL); }
void *GetWindowHandle(void) { return AppleWindowHandle(); }

static const AppleDisplay *AppleMonitor(int monitor)
{
    static const AppleDisplay empty = { 0 };
    return (monitor >= 0 && monitor < appleFrame.displayCount)? &appleFrame.displays[monitor] : &empty;
}

int GetMonitorCount(void) { return appleFrame.displayCount; }
int GetCurrentMonitor(void) { return appleFrame.displayIndex; }
Vector2 GetMonitorPosition(int monitor)
{
    const AppleDisplay *display = AppleMonitor(monitor);
    return (Vector2){ display->x, display->y };
}
int GetMonitorWidth(int monitor) { return AppleMonitor(monitor)->width; }
int GetMonitorHeight(int monitor) { return AppleMonitor(monitor)->height; }
int GetMonitorPhysicalWidth(int monitor) { return AppleMonitor(monitor)->physicalWidth; }
int GetMonitorPhysicalHeight(int monitor) { return AppleMonitor(monitor)->physicalHeight; }
int GetMonitorRefreshRate(int monitor) { return AppleMonitor(monitor)->refreshRate; }
const char *GetMonitorName(int monitor) { return AppleMonitor(monitor)->name; }
Vector2 GetWindowPosition(void) { return (Vector2){ appleFrame.windowX, appleFrame.windowY }; }
Vector2 GetWindowScaleDPI(void)
{
    Size size = AppleViewportSize();
    return (Vector2){ CORE.Window.screen.width? (float)size.width/CORE.Window.screen.width : 1.0f,
                      CORE.Window.screen.height? (float)size.height/CORE.Window.screen.height : 1.0f };
}

void SetClipboardText(const char *text) { AppleSetClipboard(text); }
const char *GetClipboardText(void)
{
    free(appleClipboardText);
    appleClipboardText = AppleCopyClipboard(false, NULL);
    return appleClipboardText;
}
Image GetClipboardImage(void)
{
    Image image = { 0 };
    int size = 0;
    char *data = AppleCopyClipboard(true, &size);
    if (data != NULL)
    {
        image = LoadImageFromMemory(".png", (const unsigned char *)data, size);
        free(data);
    }
    return image;
}

void ShowCursor(void)
{
    CORE.Input.Mouse.cursorHidden = false;
    AppleSetWindow(APPLE_WINDOW_CURSOR_MODE, 0, CORE.Input.Mouse.cursorLocked, NULL);
}
void HideCursor(void)
{
    CORE.Input.Mouse.cursorHidden = true;
    AppleSetWindow(APPLE_WINDOW_CURSOR_MODE, 1, CORE.Input.Mouse.cursorLocked, NULL);
}
void EnableCursor(void) { CORE.Input.Mouse.cursorLocked = false; ShowCursor(); }
void DisableCursor(void) { CORE.Input.Mouse.cursorLocked = true; HideCursor(); }
void SetMousePosition(int x, int y)
{
    CORE.Input.Mouse.currentPosition = (Vector2){ x, y };
    CORE.Input.Mouse.previousPosition = CORE.Input.Mouse.currentPosition;
    Vector2 scale = GetWindowScaleDPI();
    AppleSetWindow(APPLE_WINDOW_MOUSE_POSITION,
                   (x*scale.x + CORE.Window.renderOffset.x/2)*appleFrame.pointWidth/appleFrame.width,
                   (y*scale.y + (CORE.Window.renderOffset.y + 1)/2)*appleFrame.pointHeight/appleFrame.height, NULL);
}
void SetMouseCursor(int cursor) { AppleSetWindow(APPLE_WINDOW_CURSOR, cursor, 0, NULL); }
const char *GetKeyName(int key)
{
    static char name[2];
    name[0] = ((key >= 32) && (key <= 126))? (char)key : '\0';
    return name;
}
int SetGamepadMappings(const char *mappings) { (void)mappings; return 0; }
void SetGamepadVibration(int gamepad, float leftMotor, float rightMotor, float duration)
{
    (void)gamepad; (void)leftMotor; (void)rightMotor; (void)duration;
}
void OpenURL(const char *url)
{
    if ((url != NULL) && ((strncmp(url, "https://", 8) == 0) || (strncmp(url, "http://", 7) == 0))) AppleOpenURL(url);
}
