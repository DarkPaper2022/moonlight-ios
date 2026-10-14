#import <UIKit/UIKit.h>
#import "../Limelight/Input/DirectionalKeyControl.h"

// Exercise actual UIButton target/action wiring in a running UIKit application.
// The former control passed state tests but never received UIKit callbacks.
static void Check(BOOL condition) {
    if (!condition) abort();
}

@interface DirectionTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation DirectionTestApp
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    DirectionalKeyControl* control = [[DirectionalKeyControl alloc] initWithFrame:CGRectMake(0, 0, 188, 44)];
    [self.window.rootViewController.view addSubview:control];
    [control layoutIfNeeded];
    UIStackView* row = (UIStackView*)control.subviews.firstObject;
    Check([row isKindOfClass:UIStackView.class] && row.arrangedSubviews.count == 4);
    NSMutableArray* events = [NSMutableArray array];
    control.keyEventHandler = ^(unsigned short key, BOOL down) {
        [events addObject:@[@(key), @(down)]];
    };
    for (UIButton* button in row.arrangedSubviews) {
        Check([button isKindOfClass:UIButton.class] && button.bounds.size.width == 44);
        [button sendActionsForControlEvents:UIControlEventTouchDown];
        Check(events.count == 1 && [events.lastObject isEqual:@[@(button.tag), @YES]]);
        Check(button.selected);
        // A stationary finger must not need movement to press or remain held.
        [button sendActionsForControlEvents:UIControlEventTouchDown];
        Check(events.count == 1);
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        Check(events.count == 2 && [events.lastObject isEqual:@[@(button.tag), @NO]]);
        Check(!button.selected);
        [events removeAllObjects];
        const UIControlEvents releaseEvents[] = {UIControlEventTouchUpOutside, UIControlEventTouchCancel, UIControlEventTouchDragExit};
        for (unsigned i = 0; i < 3; i++) {
            [button sendActionsForControlEvents:UIControlEventTouchDown];
            [button sendActionsForControlEvents:releaseEvents[i]];
            Check(events.count == 2 && [events.lastObject isEqual:@[@(button.tag), @NO]]);
            [events removeAllObjects];
        }
        [button sendActionsForControlEvents:UIControlEventTouchDragEnter];
        [control releaseHeldKey];
        [control releaseHeldKey];
        Check(events.count == 2 && !button.selected);
        [events removeAllObjects];
    }
    UIButton* left = (UIButton*)row.arrangedSubviews[0];
    UIButton* up = (UIButton*)row.arrangedSubviews[1];
    [left sendActionsForControlEvents:UIControlEventTouchDown];
    [up sendActionsForControlEvents:UIControlEventTouchDown];
    [left sendActionsForControlEvents:UIControlEventTouchUpInside];
    Check(!left.selected && up.selected && events.count == 3);
    [control removeFromSuperview];
    Check(!up.selected && events.count == 4);
    NSString* result = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/directional-result.txt"];
    Check([@"PASS: UIKit button wiring, immediate press, hold, lift, cancellation, diagonals and removal\n"
           writeToFile:result atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    return YES;
}
@end

int main(int argc, char** argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(DirectionTestApp.class));
    }
}
