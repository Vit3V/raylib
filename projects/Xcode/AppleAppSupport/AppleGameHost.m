#import "AppleGameHost.h"
#import "platforms/rcore_apple.h"
#import "raylib.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <fcntl.h>
#import <unistd.h>

#if TARGET_OS_OSX
#import <OpenGL/gl3.h>
#import <ApplicationServices/ApplicationServices.h>
#else
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#endif

extern int RaylibGameMain(void);

enum { AppleInputCapacity = 2048, AppleControllerCount = 4, AppleControllerButtons = 18 };
static _Thread_local void *currentHost;
static __weak AppleGameHost *activeHost;

#if TARGET_OS_IOS
@interface AppleTouchRecognizer : UIGestureRecognizer
@property (nonatomic, weak) AppleGameHost *host;
- (void)clearTouches;
@end
#endif

@interface AppleGameHost ()
{
    NSCondition *_condition;
    AppleFrame _pendingFrame;
    AppleFrame _initialFrame;
    double _lastFrameTimestamp;
    double _nextFrameDeadline;
    double _framePeriod;
    BOOL _hasInitialFrame;
    BOOL _hasPendingFrame;
    BOOL _resetClock;
    BOOL _started;
    BOOL _finished;
    BOOL _sceneActive;
    BOOL _appActive;
    BOOL _drained;
    BOOL _stopRequested;
    BOOL _inputOverflow;
    AppleInputEvent _inputs[AppleInputCapacity];
    NSUInteger _inputRead;
    NSUInteger _inputCount;
    NSUInteger _frameInputCount;
    void *_windowHandle;

    CADisplayLink *_displayLink;
    NSMutableArray<id> *_observers;
    GCController *_controllers[AppleControllerCount];
    BOOL _controllerButtons[AppleControllerCount][AppleControllerButtons];
    float _controllerAxes[AppleControllerCount][6];
#if TARGET_OS_OSX
    NSOpenGLView *_view;
    NSOpenGLContext *_context;
    id _eventMonitor;
    BOOL _cursorHidden;
    BOOL _cursorLocked;
    BOOL _requestedCursorHidden;
    BOOL _requestedCursorLocked;
    NSRect _windowedFrame;
    NSWindowStyleMask _windowedStyle;
#else
    UIView *_view;
    CAEAGLLayer *_layer;
    EAGLContext *_context;
    GLuint _framebuffer;
    GLuint _colorBuffer;
    GLuint _depthStencilBuffer;
    int _allocatedWidth;
    int _allocatedHeight;
    int _drawableWidth;
    int _drawableHeight;
#endif
#if TARGET_OS_IOS
    AppleTouchRecognizer *_touchRecognizer;
#endif
#if TARGET_OS_TV
    BOOL _remoteKeys[6];
#endif
}

- (void)enqueue:(AppleInputEvent)event;
- (BOOL)readInput:(AppleInputEvent *)event;
- (BOOL)waitFrame:(double)minimumTimestamp frame:(AppleFrame *)frame;
- (BOOL)shouldStop;
- (void)present;
- (void *)windowHandle;
- (void)windowAction:(AppleWindowAction)action x:(float)x y:(float)y text:(nullable NSString *)text;
@end

@implementation AppleGameHost

- (instancetype)init
{
    if ((self = [super init]))
    {
        _condition = [NSCondition new];
        _observers = [NSMutableArray new];
        _resetClock = YES;
    }
    return self;
}

- (void)dealloc
{
    for (NSUInteger i = 0; i < _inputCount; i++) free(_inputs[(_inputRead + i) % AppleInputCapacity].text);
}

- (void)observe:(NSNotificationName)name block:(void (^)(AppleGameHost *, NSNotification *))block
{
    __weak AppleGameHost *weakSelf = self;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            AppleGameHost *host = weakSelf;
            if (host != nil) block(host, notification);
        }];
    [_observers addObject:observer];
}

- (void)reportFailure:(NSString *)message
{
    NSLog(@"raylib: %@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.reportError != nil) self.reportError(message);
    });
}

- (void)installObservers
{
#if TARGET_OS_OSX
    _appActive = NSApp.active;
    [self observe:NSApplicationWillResignActiveNotification block:^(AppleGameHost *host, NSNotification *note) {
        [host setAppActive:NO];
        [host restoreCursor];
    }];
    [self observe:NSApplicationDidBecomeActiveNotification block:^(AppleGameHost *host, NSNotification *note) {
        [host setAppActive:YES];
        [host applyCursorMode];
    }];
    [self observe:NSWindowDidBecomeKeyNotification block:^(AppleGameHost *host, NSNotification *note) {
        if (note.object == host->_view.window) [host applyCursorMode];
    }];
    [self observe:NSWindowDidResignKeyNotification block:^(AppleGameHost *host, NSNotification *note) {
        if (note.object == host->_view.window)
        {
            [host restoreCursor];
            [host resetInput];
        }
    }];
    [self observe:NSWindowWillCloseNotification block:^(AppleGameHost *host, NSNotification *note) {
        if (note.object == host->_view.window) [host stop];
    }];
#else
    _appActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    [self observe:UIApplicationWillResignActiveNotification block:^(AppleGameHost *host, NSNotification *note) {
        [host setAppActive:NO];
        [host waitUntilParked];
    }];
    [self observe:UIApplicationDidBecomeActiveNotification block:^(AppleGameHost *host, NSNotification *note) {
        [host setAppActive:YES];
    }];
    [self observe:UISceneDidActivateNotification block:^(AppleGameHost *host, NSNotification *note) {
        if (note.object == host->_view.window.windowScene) [host setAppActive:YES];
    }];
    [self observe:UISceneWillDeactivateNotification block:^(AppleGameHost *host, NSNotification *note) {
        if (note.object == host->_view.window.windowScene)
        {
            [host setAppActive:NO];
            [host waitUntilParked];
        }
    }];
#endif
}

#if TARGET_OS_OSX
- (NSView *)makeView
{
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core,
        NSOpenGLPFAAccelerated, NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADepthSize, 24, NSOpenGLPFAStencilSize, 8, 0
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    if (format == nil)
    {
        [self reportFailure:@"An OpenGL 4.1 Core pixel format is unavailable."];
        return [NSView new];
    }
    _view = [[NSOpenGLView alloc] initWithFrame:NSMakeRect(0, 0, 800, 450) pixelFormat:format];
    _view.wantsBestResolutionOpenGLSurface = YES;
    _context = _view.openGLContext;
    if (_context == nil)
    {
        [self reportFailure:@"Could not create the macOS OpenGL context."];
        return _view;
    }
    GLint swapInterval = 1;
    [_context setValues:&swapInterval forParameter:NSOpenGLContextParameterSwapInterval];
    [self installObservers];
    [self installEventMonitor];
    _displayLink = [_view displayLinkWithTarget:self selector:@selector(displayTick:)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return _view;
}
#else
- (UIViewController *)makeViewController
{
#if TARGET_OS_TV
    UIViewController *controller = [GCEventViewController new];
#else
    UIViewController *controller = [UIViewController new];
#endif
    _view = [UIView new];
    _view.backgroundColor = UIColor.blackColor;
    controller.view = _view;
    _layer = [CAEAGLLayer layer];
    _layer.opaque = YES;
    _layer.drawableProperties = @{ kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
                                  kEAGLDrawablePropertyRetainedBacking: @NO };
    [_view.layer addSublayer:_layer];
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (_context == nil)
    {
        [self reportFailure:@"Could not create an OpenGL ES 3.0 context."];
        return controller;
    }
#if TARGET_OS_IOS
    _view.multipleTouchEnabled = YES;
    _touchRecognizer = [AppleTouchRecognizer new];
    _touchRecognizer.host = self;
    _touchRecognizer.cancelsTouchesInView = NO;
    [_view addGestureRecognizer:_touchRecognizer];
#endif
    [self installObservers];
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return controller;
}
#endif

- (void)setSceneActive:(BOOL)active
{
    [_condition lock];
    BOOL changed = _sceneActive != active;
    _sceneActive = active;
    if (changed) [self activityChanged];
    [_condition unlock];
    if (changed && !active) [self resetInput];
}

- (void)setAppActive:(BOOL)active
{
    [_condition lock];
    BOOL changed = _appActive != active;
    _appActive = active;
    if (changed) [self activityChanged];
    [_condition unlock];
    if (changed && !active) [self resetInput];
}

// The caller holds the condition lock.
- (void)activityChanged
{
    _resetClock = YES;
    _nextFrameDeadline = 0;
    _hasPendingFrame = NO;
    [_condition broadcast];
}

#if !TARGET_OS_OSX
- (void)waitUntilParked
{
    // The render thread never synchronously calls UIKit while waiting to suspend.
    [_condition lock];
    while (_started && !_finished && !_drained) [_condition wait];
    [_condition unlock];
}
#endif

- (void)resetInput
{
#if TARGET_OS_IOS
    [_touchRecognizer clearTouches];
#endif
#if TARGET_OS_TV
    memset(_remoteKeys, 0, sizeof(_remoteKeys));
#endif
    memset(_controllerButtons, 0, sizeof(_controllerButtons));
    for (int i = 0; i < AppleControllerCount; i++)
    {
        memset(_controllerAxes[i], 0, sizeof(_controllerAxes[i]));
        _controllerAxes[i][GAMEPAD_AXIS_LEFT_TRIGGER] = -1.0f;
        _controllerAxes[i][GAMEPAD_AXIS_RIGHT_TRIGGER] = -1.0f;
    }
    [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_RESET }];
}

- (void)displayTick:(CADisplayLink *)link
{
    [_condition lock];
    BOOL finished = _finished;
    [_condition unlock];
    if (_view.window == nil || !_sceneActive || !_appActive || _stopRequested || finished) return;
    if (activeHost != nil && activeHost != self)
    {
        [self reportFailure:@"Another raylib game is already running in this app."];
        [self stop];
        return;
    }

    CGRect bounds = _view.bounds;
    AppleFrame frame = {
        .timestamp = link.targetTimestamp,
        .interval = link.targetTimestamp - link.timestamp,
        .pointWidth = bounds.size.width,
        .pointHeight = bounds.size.height,
    };
    if (frame.pointWidth < 1 || frame.pointHeight < 1) return;

#if TARGET_OS_OSX
    NSRect backing = [_view convertRectToBacking:bounds];
    NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
    frame.width = (int)lround(backing.size.width);
    frame.height = (int)lround(backing.size.height);
    NSArray<NSScreen *> *screens = NSScreen.screens;
    CGFloat top = NSMaxY(screens.firstObject.frame);
    frame.windowX = NSMinX(_view.window.frame);
    frame.windowY = top - NSMaxY(_view.window.frame);
    frame.displayCount = (int)MIN(screens.count, APPLE_MAX_DISPLAYS);
    for (int i = 0; i < frame.displayCount; i++)
    {
        NSScreen *display = screens[i];
        if (display == screen) frame.displayIndex = i;
        CGDirectDisplayID identifier = [display.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGSize physicalSize = CGDisplayScreenSize(identifier);
        AppleDisplay *info = &frame.displays[i];
        *info = (AppleDisplay){
            .x = NSMinX(display.frame), .y = top - NSMaxY(display.frame),
            .width = (int)CGDisplayPixelsWide(identifier), .height = (int)CGDisplayPixelsHigh(identifier),
            .physicalWidth = (int)physicalSize.width, .physicalHeight = (int)physicalSize.height,
            .refreshRate = (int)display.maximumFramesPerSecond
        };
        snprintf(info->name, sizeof(info->name), "%s", display.localizedName.UTF8String ?: "Apple display");
    }
    frame.focused = _view.window.isKeyWindow;
    _view.window.acceptsMouseMovedEvents = YES;
#else
    UIScreen *screen = _view.window.windowScene.screen;
    CGFloat scale = screen.scale ?: _view.contentScaleFactor;
    if (!CGRectEqualToRect(_layer.frame, bounds) || _layer.contentsScale != scale)
    {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _layer.frame = bounds;
        _layer.contentsScale = scale;
        [CATransaction commit];
    }
    frame.width = (int)lround(bounds.size.width*scale);
    frame.height = (int)lround(bounds.size.height*scale);
    frame.displayCount = 1;
    frame.displays[0] = (AppleDisplay){
        .width = (int)lround(screen.nativeBounds.size.width), .height = (int)lround(screen.nativeBounds.size.height),
        .refreshRate = (int)screen.maximumFramesPerSecond, .name = "Apple display"
    };
    frame.focused = YES;
#endif

    if (frame.focused) [self updateControllers];

    [_condition lock];
    _windowHandle = (__bridge void *)_view.window;
    _pendingFrame = frame;
    _hasPendingFrame = YES;
    if (!_started)
    {
        activeHost = self;
        _started = YES;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{ [self runGame]; }];
        thread.name = @"raylib rendering";
        thread.qualityOfService = NSQualityOfServiceUserInteractive;
        [thread start];
    }
    [_condition signal];
    [_condition unlock];
}

- (void)stop
{
    [_displayLink invalidate];
    _displayLink = nil;
#if TARGET_OS_OSX
    if (_eventMonitor != nil) [NSEvent removeMonitor:_eventMonitor];
    _eventMonitor = nil;
    [self restoreCursor];
#endif
    [_condition lock];
    _stopRequested = YES;
    [_condition broadcast];
    BOOL finished = !_started || _finished;
    [_condition unlock];
    // A suspended UIKit game retains the lifecycle observer until it can clean up.
    if (finished) [self removeObservers];
    self.reportError = nil;
}

- (void)removeObservers
{
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [_observers removeAllObjects];
}

- (void)enqueue:(AppleInputEvent)event
{
    [_condition lock];
    if ((_inputCount > _frameInputCount) &&
        (event.type == APPLE_INPUT_MOUSE_POSITION || (event.type == APPLE_INPUT_TOUCH && event.action == 2)))
    {
        NSUInteger tail = (_inputRead + _inputCount - 1) % AppleInputCapacity;
        AppleInputEvent previous = _inputs[tail];
        if (previous.type == event.type && previous.action == event.action && previous.index == event.index)
        {
#if TARGET_OS_OSX
            if (event.type == APPLE_INPUT_MOUSE_POSITION && _cursorLocked)
            {
                event.x += previous.x;
                event.y += previous.y;
            }
#endif
            _inputs[tail] = event;
            [_condition unlock];
            return;
        }
    }
    if (_inputCount == AppleInputCapacity)
    {
        _inputOverflow = YES;
        free(event.text);
    }
    else
    {
        NSUInteger index = (_inputRead + _inputCount) % AppleInputCapacity;
        _inputs[index] = event;
        _inputCount++;
    }
    [_condition unlock];
}

- (BOOL)readInput:(AppleInputEvent *)event
{
    [_condition lock];
    BOOL available = _frameInputCount != 0;
    if (available)
    {
        *event = _inputs[_inputRead];
        _inputRead = (_inputRead + 1) % AppleInputCapacity;
        _inputCount--;
        _frameInputCount--;
    }
    [_condition unlock];
    return available;
}

- (void *)windowHandle
{
    [_condition lock];
    void *handle = _windowHandle;
    [_condition unlock];
    return handle;
}

- (BOOL)shouldStop
{
    [_condition lock];
    BOOL stop = _stopRequested;
    [_condition unlock];
    return stop;
}

- (BOOL)waitFrame:(double)minimumTimestamp frame:(AppleFrame *)frame
{
    if (_hasInitialFrame)
    {
        _hasInitialFrame = NO;
        *frame = _initialFrame;
        // The first game update must exclude time spent loading resources after InitWindow.
        [_condition lock];
        _resetClock = YES;
        _nextFrameDeadline = 0;
        [_condition unlock];
        return YES;
    }

#if TARGET_OS_OSX
    CGLContextObj context = _context.CGLContextObj;
    CGLUnlockContext(context);
#endif
    [_condition lock];
    for (;;)
    {
#if TARGET_OS_OSX
        BOOL canStop = _stopRequested;
#else
        BOOL canStop = _stopRequested && _appActive;
        if (!_appActive && !_drained)
        {
            [_condition unlock];
            glFinish();
            [_condition lock];
            _drained = YES;
        }
#endif
        [_condition broadcast];
        if (canStop)
        {
            [_condition unlock];
#if TARGET_OS_OSX
            CGLLockContext(context);
#endif
            return NO;
        }

        double period = minimumTimestamp - _lastFrameTimestamp;
        double threshold = _nextFrameDeadline;
        if (period <= 0 || _resetClock) threshold = 0;
        else if (threshold <= 0 || fabs(period - _framePeriod) > 1e-6) threshold = minimumTimestamp;

        if (_sceneActive && _appActive && _hasPendingFrame &&
            _pendingFrame.timestamp + fmax(0, _pendingFrame.interval)*0.05 >= threshold)
        {
            *frame = _pendingFrame;
            _hasPendingFrame = NO;
            if (!_resetClock && _lastFrameTimestamp > 0) frame->interval = frame->timestamp - _lastFrameTimestamp;
            _lastFrameTimestamp = frame->timestamp;
            _framePeriod = period;
            _nextFrameDeadline = 0;
            if (period > 0)
            {
                double next = threshold + period;
                _nextFrameDeadline = (threshold > 0 && next > frame->timestamp)? next : frame->timestamp + period;
            }
            _resetClock = NO;
            _drained = NO;
            if (_inputOverflow)
            {
                // Reconcile held state if the producer filled the queue while the game was busy.
                for (NSUInteger i = 0; i < _inputCount; i++) free(_inputs[(_inputRead + i) % AppleInputCapacity].text);
                _inputRead = 0;
                _inputs[0] = (AppleInputEvent){ .type = APPLE_INPUT_RESET };
                _inputCount = 1;
                _inputOverflow = NO;
            }
            _frameInputCount = _inputCount;
            [_condition unlock];
#if TARGET_OS_OSX
            CGLLockContext(context);
#else
            if (![self bindDrawable:frame])
            {
                [self reportFailure:@"Could not create the OpenGL ES drawable."];
                return NO;
            }
#endif
            return YES;
        }
        [_condition wait];
    }
}

#if !TARGET_OS_OSX
- (BOOL)bindDrawable:(AppleFrame *)frame
{
    if (_framebuffer == 0)
    {
        glGenFramebuffers(1, &_framebuffer);
        glGenRenderbuffers(1, &_colorBuffer);
        glGenRenderbuffers(1, &_depthStencilBuffer);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);

    if (_allocatedWidth != frame->width || _allocatedHeight != frame->height)
    {
        glBindRenderbuffer(GL_RENDERBUFFER, _colorBuffer);
        if (![_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:_layer]) return NO;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_drawableWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_drawableHeight);
        if (_drawableWidth <= 0 || _drawableHeight <= 0) return NO;
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorBuffer);

        glBindRenderbuffer(GL_RENDERBUFFER, _depthStencilBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, _drawableWidth, _drawableHeight);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthStencilBuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depthStencilBuffer);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return NO;

        _allocatedWidth = frame->width;
        _allocatedHeight = frame->height;
    }
    frame->width = _drawableWidth;
    frame->height = _drawableHeight;
    frame->framebuffer = _framebuffer;
    return YES;
}
#endif

- (void)present
{
#if TARGET_OS_OSX
    CGLFlushDrawable(_context.CGLContextObj);
#else
    @autoreleasepool {
        glBindRenderbuffer(GL_RENDERBUFFER, _colorBuffer);
        [_context presentRenderbuffer:GL_RENDERBUFFER];
    }
#endif
}

- (BOOL)prepareWorkingDirectory:(NSError **)error
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSBundle *bundle = NSBundle.mainBundle;
#if TARGET_OS_TV
    NSSearchPathDirectory directory = NSCachesDirectory;
#else
    NSSearchPathDirectory directory = NSApplicationSupportDirectory;
#endif
    NSURL *root = [files URLForDirectory:directory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:error];
    if (root == nil) return NO;
    NSURL *work = [root URLByAppendingPathComponent:bundle.bundleIdentifier ?: @"raylib" isDirectory:YES];
    if (![files createDirectoryAtURL:work withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    NSURL *assets = [bundle.resourceURL URLByAppendingPathComponent:@"RaylibAssets/resources" isDirectory:YES];
    if (![files fileExistsAtPath:assets.path])
        assets = [bundle.resourceURL URLByAppendingPathComponent:@"resources" isDirectory:YES];
    NSURL *localAssets = [work URLByAppendingPathComponent:@"resources" isDirectory:YES];
    BOOL editable = [[bundle objectForInfoDictionaryKey:@"RaylibEditableResources"] boolValue];
    NSURL *existingLink = [files destinationOfSymbolicLinkAtPath:localAssets.path error:NULL] == nil? nil : localAssets;
    if (existingLink != nil && ![files removeItemAtURL:existingLink error:error]) return NO;
    if ([files fileExistsAtPath:assets.path] && ![files fileExistsAtPath:localAssets.path])
    {
        if (editable)
        {
            if (![files copyItemAtURL:assets toURL:localAssets error:error]) return NO;
        }
        else if (![files createSymbolicLinkAtURL:localAssets withDestinationURL:assets error:error]) return NO;
    }
    if (chdir(work.fileSystemRepresentation) == 0) return YES;
    if (error != NULL) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
}

- (void)runGame
{
    @autoreleasepool {
        currentHost = (__bridge void *)self;
        int originalDirectory = open(".", O_RDONLY | O_CLOEXEC);
        NSError *error = nil;
#if TARGET_OS_OSX
        BOOL completed = NO;
#endif
        if (originalDirectory < 0 || ![self prepareWorkingDirectory:&error])
        {
            [self reportFailure:error.localizedDescription ?: @"Could not open the raylib working directory."];
        }
        else
        {
#if TARGET_OS_OSX
            CGLContextObj context = _context.CGLContextObj;
            BOOL ready = CGLSetCurrentContext(context) == kCGLNoError;
            if (ready) CGLLockContext(context);
#else
            BOOL ready = [EAGLContext setCurrentContext:_context];
#endif
            if (ready)
            {
                if ([self waitFrame:0 frame:&_initialFrame])
                {
                    _hasInitialFrame = YES;
                    int result = RaylibGameMain();
                    if (IsWindowReady()) CloseWindow();
#if TARGET_OS_OSX
                    completed = result == 0;
#endif
                    if (result != 0) [self reportFailure:[NSString stringWithFormat:@"The raylib game exited with status %d.", result]];
                }
#if TARGET_OS_OSX
                CGLUnlockContext(context);
                CGLSetCurrentContext(NULL);
#else
                glDeleteFramebuffers(1, &_framebuffer);
                glDeleteRenderbuffers(1, &_colorBuffer);
                glDeleteRenderbuffers(1, &_depthStencilBuffer);
                glFinish();
                [EAGLContext setCurrentContext:nil];
#endif
            }
            else [self reportFailure:@"Could not activate the OpenGL context on the rendering thread."];
        }
        if (originalDirectory >= 0)
        {
            fchdir(originalDirectory);
            close(originalDirectory);
        }
        currentHost = NULL;
        [_condition lock];
        _finished = YES;
        while (_inputCount > 0)
        {
            free(_inputs[_inputRead].text);
            _inputRead = (_inputRead + 1) % AppleInputCapacity;
            _inputCount--;
        }
        [_condition broadcast];
        [_condition unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (activeHost == self) activeHost = nil;
#if TARGET_OS_OSX
            if (completed && ![self shouldStop]) [self->_view.window close];
#endif
            [self stop];
        });
    }
}

- (void)dropFile:(NSURL *)url
{
    if (!url.isFileURL) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *destination = [directory URLByAppendingPathComponent:url.lastPathComponent];
    if ([files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL] &&
        [files copyItemAtURL:url toURL:destination error:NULL])
    {
        [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_DROP, .text = strdup(destination.fileSystemRepresentation) }];
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
}

#if TARGET_OS_OSX
// macOS virtual key codes describe physical keys. Text comes from NSEvent separately.
static int MacKey(unsigned short code)
{
    static const int keys[127] = {
        [0] = KEY_A, [1] = KEY_S, [2] = KEY_D, [3] = KEY_F, [4] = KEY_H,
        [5] = KEY_G, [6] = KEY_Z, [7] = KEY_X, [8] = KEY_C, [9] = KEY_V,
        [11] = KEY_B, [12] = KEY_Q, [13] = KEY_W, [14] = KEY_E, [15] = KEY_R,
        [16] = KEY_Y, [17] = KEY_T, [18] = KEY_ONE, [19] = KEY_TWO, [20] = KEY_THREE,
        [21] = KEY_FOUR, [22] = KEY_SIX, [23] = KEY_FIVE, [24] = KEY_EQUAL, [25] = KEY_NINE,
        [26] = KEY_SEVEN, [27] = KEY_MINUS, [28] = KEY_EIGHT, [29] = KEY_ZERO,
        [30] = KEY_RIGHT_BRACKET, [31] = KEY_O, [32] = KEY_U, [33] = KEY_LEFT_BRACKET,
        [34] = KEY_I, [35] = KEY_P, [36] = KEY_ENTER, [37] = KEY_L, [38] = KEY_J,
        [39] = KEY_APOSTROPHE, [40] = KEY_K, [41] = KEY_SEMICOLON, [42] = KEY_BACKSLASH,
        [43] = KEY_COMMA, [44] = KEY_SLASH, [45] = KEY_N, [46] = KEY_M, [47] = KEY_PERIOD,
        [48] = KEY_TAB, [49] = KEY_SPACE, [50] = KEY_GRAVE, [51] = KEY_BACKSPACE, [53] = KEY_ESCAPE,
        [54] = KEY_RIGHT_SUPER, [55] = KEY_LEFT_SUPER, [56] = KEY_LEFT_SHIFT, [57] = KEY_CAPS_LOCK,
        [58] = KEY_LEFT_ALT, [59] = KEY_LEFT_CONTROL, [60] = KEY_RIGHT_SHIFT,
        [61] = KEY_RIGHT_ALT, [62] = KEY_RIGHT_CONTROL,
        [65] = KEY_KP_DECIMAL, [67] = KEY_KP_MULTIPLY, [69] = KEY_KP_ADD, [71] = KEY_NUM_LOCK,
        [75] = KEY_KP_DIVIDE, [76] = KEY_KP_ENTER, [78] = KEY_KP_SUBTRACT, [81] = KEY_KP_EQUAL,
        [82] = KEY_KP_0, [83] = KEY_KP_1, [84] = KEY_KP_2, [85] = KEY_KP_3, [86] = KEY_KP_4,
        [87] = KEY_KP_5, [88] = KEY_KP_6, [89] = KEY_KP_7, [91] = KEY_KP_8, [92] = KEY_KP_9,
        [96] = KEY_F5, [97] = KEY_F6, [98] = KEY_F7, [99] = KEY_F3, [100] = KEY_F8,
        [101] = KEY_F9, [103] = KEY_F11, [109] = KEY_F10, [111] = KEY_F12,
        [115] = KEY_HOME, [116] = KEY_PAGE_UP, [117] = KEY_DELETE, [118] = KEY_F4,
        [119] = KEY_END, [120] = KEY_F2, [121] = KEY_PAGE_DOWN, [122] = KEY_F1,
        [123] = KEY_LEFT, [124] = KEY_RIGHT, [125] = KEY_DOWN, [126] = KEY_UP
    };
    return code < sizeof(keys)/sizeof(keys[0])? keys[code] : KEY_NULL;
}

- (void)installEventMonitor
{
    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged |
        NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
        NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown |
        NSEventMaskOtherMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
        NSEventMaskOtherMouseDragged | NSEventMaskScrollWheel;
    __weak AppleGameHost *weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        return [weakSelf handleEvent:event]? nil : event;
    }];
}

- (BOOL)handleEvent:(NSEvent *)event
{
    if (!_sceneActive || !_appActive || _view.window == nil || event.window != _view.window) return NO;
    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp)
    {
        int code = MacKey(event.keyCode);
        int action = event.type == NSEventTypeKeyUp? 0 : event.isARepeat? 2 : 1;
        [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_KEY, .code = code, .action = action }];
        if (action != 0 && !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)))
        {
            NSString *characters = event.characters;
            for (NSUInteger i = 0; i < characters.length; i++)
            {
                int scalar = [characters characterAtIndex:i];
                if (CFStringIsSurrogateHighCharacter((UniChar)scalar) && i + 1 < characters.length)
                {
                    UniChar low = [characters characterAtIndex:i + 1];
                    if (CFStringIsSurrogateLowCharacter(low))
                        scalar = (int)CFStringGetLongCharacterForSurrogatePair((UniChar)scalar, [characters characterAtIndex:++i]);
                }
                if (scalar >= 32 && !(scalar >= 0xf700 && scalar <= 0xf8ff))
                    [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_TEXT, .code = scalar }];
            }
        }
        return code != KEY_NULL && !(event.modifierFlags & NSEventModifierFlagCommand);
    }
    if (event.type == NSEventTypeFlagsChanged)
    {
        int code = MacKey(event.keyCode);
        // The low bits report each side independently when both modifiers are held.
        static const NSUInteger masks[] = { 0x02, 0x01, 0x20, 0x08, 0x04, 0x2000, 0x40, 0x10 };
        if (code >= KEY_LEFT_SHIFT && code <= KEY_RIGHT_SUPER)
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_KEY, .code = code,
                                            .action = (event.modifierFlags & masks[code - KEY_LEFT_SHIFT]) != 0 }];
        else if (code == KEY_CAPS_LOCK)
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_KEY, .code = code,
                                            .action = (event.modifierFlags & NSEventModifierFlagCapsLock) != 0 }];
        return NO;
    }

    NSPoint point = [_view convertPoint:event.locationInWindow fromView:nil];
    NSRect bounds = _view.bounds;
    BOOL inside = NSPointInRect(point, bounds);
    float x = _cursorLocked? event.deltaX : point.x - NSMinX(bounds);
    float y = _cursorLocked? event.deltaY : NSMaxY(bounds) - point.y;
    [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_MOUSE_POSITION, .x = x, .y = y }];
    switch (event.type)
    {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
            if (inside || _cursorLocked)
                [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_MOUSE_BUTTON, .code = (int)event.buttonNumber, .action = 1 }];
            break;
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp:
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_MOUSE_BUTTON, .code = (int)event.buttonNumber }];
            break;
        case NSEventTypeScrollWheel:
            if (inside || _cursorLocked)
                [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_MOUSE_SCROLL, .x = event.deltaX, .y = event.deltaY }];
            break;
        default: break;
    }
    return NO;
}

- (void)applyCursorMode
{
    if (!_appActive || !_view.window.isKeyWindow)
    {
        [self restoreCursor];
        return;
    }
    if (_cursorHidden != _requestedCursorHidden)
    {
        _cursorHidden = _requestedCursorHidden;
        if (_cursorHidden) [NSCursor hide];
        else [NSCursor unhide];
    }
    if (_cursorLocked != _requestedCursorLocked)
    {
        _cursorLocked = _requestedCursorLocked;
        CGAssociateMouseAndMouseCursorPosition(!_cursorLocked);
    }
}

- (void)restoreCursor
{
    if (_cursorHidden) [NSCursor unhide];
    if (_cursorLocked) CGAssociateMouseAndMouseCursorPosition(true);
    _cursorHidden = NO;
    _cursorLocked = NO;
}
#endif

- (void)windowAction:(AppleWindowAction)action x:(float)x y:(float)y text:(NSString *)text
{
#if TARGET_OS_OSX
    NSWindow *window = _view.window;
    if (window == nil) return;
    switch (action)
    {
        case APPLE_WINDOW_TITLE: if (text != nil) window.title = text; break;
        case APPLE_WINDOW_SIZE:
        {
            if (window.styleMask & NSWindowStyleMaskFullScreen) break;

            // Size the usable area below the title bar and toolbar in window points.
            NSSize layoutSize = window.contentLayoutRect.size;
            CGFloat widthChange = x - layoutSize.width;
            CGFloat heightChange = y - layoutSize.height;
            if (widthChange == 0 && heightChange == 0) break;

            NSRect frame = window.frame;
            frame.size.width += widthChange;
            frame.size.height += heightChange;
            frame.origin.y -= heightChange;
            [window setFrame:frame display:YES];
        } break;
        case APPLE_WINDOW_POSITION: [window setFrameTopLeftPoint:NSMakePoint(x, NSMaxY(NSScreen.screens.firstObject.frame) - y)]; break;
        case APPLE_WINDOW_MONITOR:
        {
            NSArray<NSScreen *> *screens = NSScreen.screens;
            if (x >= 0 && (NSUInteger)x < screens.count)
            {
                NSRect screen = screens[(NSUInteger)x].visibleFrame;
                [window setFrameOrigin:NSMakePoint(NSMidX(screen) - NSWidth(window.frame)/2,
                                                   NSMidY(screen) - NSHeight(window.frame)/2)];
            }
        } break;
        case APPLE_WINDOW_MIN_SIZE: window.contentMinSize = NSMakeSize(x, y); break;
        case APPLE_WINDOW_MAX_SIZE: window.contentMaxSize = NSMakeSize(x, y); break;
        case APPLE_WINDOW_FULLSCREEN: [window toggleFullScreen:nil]; break;
        case APPLE_WINDOW_BORDERLESS:
            if (x != 0)
            {
                _windowedFrame = window.frame;
                _windowedStyle = window.styleMask;
                window.styleMask = NSWindowStyleMaskBorderless;
                [window setFrame:window.screen.frame display:YES];
            }
            else if (!NSIsEmptyRect(_windowedFrame))
            {
                window.styleMask = _windowedStyle;
                [window setFrame:_windowedFrame display:YES];
                _windowedFrame = NSZeroRect;
            }
            break;
        case APPLE_WINDOW_MINIMIZE: [window miniaturize:nil]; break;
        case APPLE_WINDOW_MAXIMIZE: if (!window.isZoomed) [window zoom:nil]; break;
        case APPLE_WINDOW_RESTORE:
            if (window.isMiniaturized) [window deminiaturize:nil];
            if (window.isZoomed) [window zoom:nil];
            break;
        case APPLE_WINDOW_FOCUS: [window makeKeyAndOrderFront:nil]; break;
        case APPLE_WINDOW_OPACITY: window.alphaValue = fmaxf(0, fminf(x, 1)); break;
        case APPLE_WINDOW_CURSOR:
        {
            switch ((int)x)
            {
                case MOUSE_CURSOR_IBEAM: [NSCursor.IBeamCursor set]; break;
                case MOUSE_CURSOR_CROSSHAIR: [NSCursor.crosshairCursor set]; break;
                case MOUSE_CURSOR_POINTING_HAND: [NSCursor.pointingHandCursor set]; break;
                case MOUSE_CURSOR_RESIZE_EW: [NSCursor.resizeLeftRightCursor set]; break;
                case MOUSE_CURSOR_RESIZE_NS: [NSCursor.resizeUpDownCursor set]; break;
                case MOUSE_CURSOR_NOT_ALLOWED: [NSCursor.operationNotAllowedCursor set]; break;
                default: [NSCursor.arrowCursor set]; break;
            }
        } break;
        case APPLE_WINDOW_CURSOR_MODE:
            _requestedCursorHidden = x != 0;
            _requestedCursorLocked = y != 0;
            [self applyCursorMode];
            break;
        case APPLE_WINDOW_MOUSE_POSITION:
        {
            NSRect bounds = _view.bounds;
            NSPoint point = [_view convertPoint:NSMakePoint(NSMinX(bounds) + x, NSMaxY(bounds) - y) toView:nil];
            point = [window convertPointToScreen:point];
            CGWarpMouseCursorPosition(CGPointMake(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y));
        } break;
        case APPLE_WINDOW_FLAGS:
        {
            unsigned int flags = (unsigned int)x;
            window.titlebarAppearsTransparent = (flags & FLAG_WINDOW_UNDECORATED) != 0;
            if (flags & FLAG_WINDOW_RESIZABLE) window.styleMask |= NSWindowStyleMaskResizable;
            else window.styleMask &= ~NSWindowStyleMaskResizable;
            window.level = (flags & FLAG_WINDOW_TOPMOST)? NSFloatingWindowLevel : NSNormalWindowLevel;
            if (flags & FLAG_WINDOW_MINIMIZED) [window miniaturize:nil];
            if ((flags & FLAG_WINDOW_MAXIMIZED) && !window.isZoomed) [window zoom:nil];
            if (((flags & FLAG_FULLSCREEN_MODE) != 0) != ((window.styleMask & NSWindowStyleMaskFullScreen) != 0))
                [window toggleFullScreen:nil];
        } break;
    }
#endif
}

- (void)updateControllers
{
    NSArray<GCController *> *connected = GCController.controllers;
    for (int i = 0; i < AppleControllerCount; i++)
    {
        if (_controllers[i] != nil && ![connected containsObject:_controllers[i]])
        {
            _controllers[i] = nil;
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_GAMEPAD_CONNECT, .index = i }];
        }
    }

#if TARGET_OS_TV
    const int remoteKeyCodes[] = { KEY_UP, KEY_RIGHT, KEY_DOWN, KEY_LEFT, KEY_ENTER, KEY_SPACE };
    BOOL remoteKeys[6] = { 0 };
#endif
    for (GCController *controller in connected)
    {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (gamepad == nil)
        {
#if TARGET_OS_TV
            GCMicroGamepad *remote = controller.microGamepad;
            if (remote != nil)
            {
                remoteKeys[0] |= remote.dpad.up.isPressed;
                remoteKeys[1] |= remote.dpad.right.isPressed;
                remoteKeys[2] |= remote.dpad.down.isPressed;
                remoteKeys[3] |= remote.dpad.left.isPressed;
                remoteKeys[4] |= remote.buttonA.isPressed;
                remoteKeys[5] |= remote.buttonX.isPressed;
            }
#endif
            continue;
        }
        int slot = -1;
        for (int i = 0; i < AppleControllerCount; i++)
        {
            if (_controllers[i] == controller)
            {
                slot = i;
                break;
            }
        }
        if (slot < 0)
        {
            for (int i = 0; i < AppleControllerCount; i++)
            {
                if (_controllers[i] == nil)
                {
                    slot = i;
                    break;
                }
            }
            if (slot < 0) continue;
            _controllers[slot] = controller;
            memset(_controllerButtons[slot], 0, sizeof(_controllerButtons[slot]));
            memset(_controllerAxes[slot], 0, sizeof(_controllerAxes[slot]));
            _controllerAxes[slot][GAMEPAD_AXIS_LEFT_TRIGGER] = -1.0f;
            _controllerAxes[slot][GAMEPAD_AXIS_RIGHT_TRIGGER] = -1.0f;
            NSString *name = controller.vendorName ?: controller.productCategory;
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_GAMEPAD_CONNECT, .index = slot, .action = 1,
                                            .text = strdup(name.UTF8String ?: "Apple game controller") }];
        }

        BOOL buttons[AppleControllerButtons] = {
            [GAMEPAD_BUTTON_LEFT_FACE_UP] = gamepad.dpad.up.isPressed,
            [GAMEPAD_BUTTON_LEFT_FACE_RIGHT] = gamepad.dpad.right.isPressed,
            [GAMEPAD_BUTTON_LEFT_FACE_DOWN] = gamepad.dpad.down.isPressed,
            [GAMEPAD_BUTTON_LEFT_FACE_LEFT] = gamepad.dpad.left.isPressed,
            [GAMEPAD_BUTTON_RIGHT_FACE_UP] = gamepad.buttonY.isPressed,
            [GAMEPAD_BUTTON_RIGHT_FACE_RIGHT] = gamepad.buttonB.isPressed,
            [GAMEPAD_BUTTON_RIGHT_FACE_DOWN] = gamepad.buttonA.isPressed,
            [GAMEPAD_BUTTON_RIGHT_FACE_LEFT] = gamepad.buttonX.isPressed,
            [GAMEPAD_BUTTON_LEFT_TRIGGER_1] = gamepad.leftShoulder.isPressed,
            [GAMEPAD_BUTTON_RIGHT_TRIGGER_1] = gamepad.rightShoulder.isPressed,
            [GAMEPAD_BUTTON_LEFT_TRIGGER_2] = gamepad.leftTrigger.isPressed,
            [GAMEPAD_BUTTON_RIGHT_TRIGGER_2] = gamepad.rightTrigger.isPressed,
            [GAMEPAD_BUTTON_MIDDLE_LEFT] = gamepad.buttonOptions.isPressed,
            [GAMEPAD_BUTTON_MIDDLE] = gamepad.buttonHome.isPressed,
            [GAMEPAD_BUTTON_MIDDLE_RIGHT] = gamepad.buttonMenu.isPressed,
            [GAMEPAD_BUTTON_LEFT_THUMB] = gamepad.leftThumbstickButton.isPressed,
            [GAMEPAD_BUTTON_RIGHT_THUMB] = gamepad.rightThumbstickButton.isPressed,
        };
        float axes[] = { gamepad.leftThumbstick.xAxis.value, -gamepad.leftThumbstick.yAxis.value,
                         gamepad.rightThumbstick.xAxis.value, -gamepad.rightThumbstick.yAxis.value,
                         gamepad.leftTrigger.value*2.0f - 1.0f, gamepad.rightTrigger.value*2.0f - 1.0f };
        for (int i = 1; i < AppleControllerButtons; i++)
        {
            if (buttons[i] == _controllerButtons[slot][i]) continue;
            _controllerButtons[slot][i] = buttons[i];
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_GAMEPAD_BUTTON, .index = slot, .code = i, .action = buttons[i] }];
        }
        for (int i = 0; i < 6; i++)
        {
            if (axes[i] == _controllerAxes[slot][i]) continue;
            _controllerAxes[slot][i] = axes[i];
            [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_GAMEPAD_AXIS, .index = slot, .code = i, .x = axes[i] }];
        }
    }
#if TARGET_OS_TV
    for (int i = 0; i < 6; i++)
    {
        if (remoteKeys[i] == _remoteKeys[i]) continue;
        _remoteKeys[i] = remoteKeys[i];
        [self enqueue:(AppleInputEvent){ .type = APPLE_INPUT_KEY, .code = remoteKeyCodes[i], .action = remoteKeys[i] }];
    }
#endif
}
@end

#if TARGET_OS_IOS
@implementation AppleTouchRecognizer
{
    NSMutableDictionary<NSValue *, NSNumber *> *_touches;
    int _nextID;
}

- (void)clearTouches { [_touches removeAllObjects]; }

- (void)forwardTouches:(NSSet<UITouch *> *)touches action:(int)action
{
    if (_touches == nil) _touches = [NSMutableDictionary new];
    for (UITouch *touch in touches)
    {
        NSValue *key = [NSValue valueWithNonretainedObject:touch];
        NSNumber *identifier = _touches[key];
        if (action == 1)
        {
            identifier = @(_nextID++);
            _touches[key] = identifier;
        }
        if (identifier == nil) continue;
        CGPoint location = [touch locationInView:self.view];
        [self.host enqueue:(AppleInputEvent){ .type = APPLE_INPUT_TOUCH, .index = identifier.intValue,
                                             .action = action, .x = location.x, .y = location.y }];
        if (action == 0 || action == 3) [_touches removeObjectForKey:key];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self forwardTouches:touches action:1]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self forwardTouches:touches action:2]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self forwardTouches:touches action:0];
    if (_touches.count == 0) self.state = UIGestureRecognizerStateFailed;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self forwardTouches:touches action:3];
    if (_touches.count == 0) self.state = UIGestureRecognizerStateFailed;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
@end
#endif

static AppleGameHost *CurrentHost(void) { return (__bridge AppleGameHost *)currentHost; }
bool AppleWaitFrame(double minimumTimestamp, AppleFrame *frame) { return [CurrentHost() waitFrame:minimumTimestamp frame:frame]; }
bool AppleStopRequested(void) { return [CurrentHost() shouldStop]; }
void ApplePresentFrame(void) { [CurrentHost() present]; }
bool AppleNextInput(AppleInputEvent *event) { return [CurrentHost() readInput:event]; }
void *AppleWindowHandle(void) { return [CurrentHost() windowHandle]; }

void AppleSetWindow(AppleWindowAction action, float x, float y, const char *text)
{
    @autoreleasepool {
        AppleGameHost *host = CurrentHost();
        NSString *value = text != NULL? [NSString stringWithUTF8String:text] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [host windowAction:action x:x y:y text:value]; });
    }
}

void AppleOpenURL(const char *url)
{
#if !TARGET_OS_TV
    @autoreleasepool {
        NSString *value = [NSString stringWithUTF8String:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *link = [NSURL URLWithString:value];
            if (link == nil) return;
#if TARGET_OS_OSX
            [NSWorkspace.sharedWorkspace openURL:link];
#else
            [UIApplication.sharedApplication openURL:link options:@{} completionHandler:nil];
#endif
        });
    }
#endif
}

void AppleSetClipboard(const char *text)
{
#if !TARGET_OS_TV
    if (text == NULL) return;
    @autoreleasepool {
        NSString *value = [NSString stringWithUTF8String:text];
        dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_OSX
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:value ?: @"" forType:NSPasteboardTypeString];
#else
            UIPasteboard.generalPasteboard.string = value;
#endif
        });
    }
#endif
}

char *AppleCopyClipboard(bool image, int *size)
{
#if !TARGET_OS_TV
    @autoreleasepool {
        __block NSData *data;
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_OSX
            if (image)
            {
                NSData *tiff = [NSPasteboard.generalPasteboard dataForType:NSPasteboardTypeTIFF];
                if (tiff != nil)
                {
                    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:tiff];
                    data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                }
            }
            else data = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
#else
            if (image)
            {
                UIImage *pasteboardImage = UIPasteboard.generalPasteboard.image;
                if (pasteboardImage != nil) data = UIImagePNGRepresentation(pasteboardImage);
            }
            else data = [UIPasteboard.generalPasteboard.string dataUsingEncoding:NSUTF8StringEncoding];
#endif
            dispatch_semaphore_signal(completed);
        });

        // UIKit may be synchronously waiting for the render thread to park.
        if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC)) != 0) return NULL;
        if (data == nil || data.length > INT_MAX) return NULL;
        char *bytes = calloc(data.length + 1, 1);
        if (bytes == NULL) return NULL;
        [data getBytes:bytes length:data.length];
        if (size != NULL) *size = (int)data.length;
        return bytes;
    }
#else
    return NULL;
#endif
}
