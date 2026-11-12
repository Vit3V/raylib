#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface AppleGameHost : NSObject
@property (nonatomic, copy, nullable) void (^reportError)(NSString *);

#if TARGET_OS_OSX
- (NSView *)makeView;
#else
- (UIViewController *)makeViewController;
#endif

- (void)setSceneActive:(BOOL)active;
- (void)stop;
- (void)dropFile:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
