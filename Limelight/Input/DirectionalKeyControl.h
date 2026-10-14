#import <UIKit/UIKit.h>

#if !TARGET_OS_TV
@interface DirectionalKeyControl : UIView

@property(nonatomic, copy) void (^keyEventHandler)(unsigned short keyCode, BOOL down);

- (void)releaseHeldKey;

@end
#endif
