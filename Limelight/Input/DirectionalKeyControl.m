#import "DirectionalKeyControl.h"
#import "DirectionalKeyState.h"

#if !TARGET_OS_TV
@implementation DirectionalKeyControl {
    DirectionalKeyState _keyState;
    CGPoint _dragOrigin;
    BOOL _directionTracking;
    UILabel* _directionLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        self.layer.cornerRadius = 8;
        self.exclusiveTouch = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Direction keys";
        self.accessibilityHint = @"Press and drag up, down, left, or right. Hold to keep the key pressed.";
        self.accessibilityTraits = UIAccessibilityTraitButton;

        _directionLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _directionLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _directionLabel.textAlignment = NSTextAlignmentCenter;
        _directionLabel.textColor = [UIColor whiteColor];
        _directionLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        _directionLabel.text = @"↕ ↔";
        [self addSubview:_directionLabel];
    }
    return self;
}

- (void)setHeldKey:(unsigned short)key {
    DirectionalKeyTransition transition = DirectionalKeySetHeldKey(&_keyState, key);
    // Release the old direction first; repeated move events do not repeat DOWN.
    if (transition.keyUp && self.keyEventHandler) {
        self.keyEventHandler(transition.keyUp, NO);
    }
    if (transition.keyDown && self.keyEventHandler) {
        self.keyEventHandler(transition.keyDown, YES);
    }

    switch (key) {
        case 0x25: _directionLabel.text = @"←"; break;
        case 0x26: _directionLabel.text = @"↑"; break;
        case 0x27: _directionLabel.text = @"→"; break;
        case 0x28: _directionLabel.text = @"↓"; break;
        default: _directionLabel.text = @"↕ ↔"; break;
    }
    self.backgroundColor = key ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.2 alpha:1.0];
}

- (BOOL)beginTracking:(UITouch*)touch withEvent:(UIEvent*)event {
    [self releaseHeldKey];
    _directionTracking = YES;
    // Window coordinates keep the origin stable when the finger leaves the bar.
    _dragOrigin = [touch locationInView:self.window];
    return YES;
}

- (BOOL)continueTracking:(UITouch*)touch withEvent:(UIEvent*)event {
    if (!_directionTracking) {
        return NO;
    }
    CGPoint location = [touch locationInView:self.window];
    [self setHeldKey:DirectionalKeyForOffset(location.x - _dragOrigin.x,
                                           location.y - _dragOrigin.y)];
    return YES;
}

- (void)endTracking:(UITouch*)touch withEvent:(UIEvent*)event {
    [self releaseHeldKey];
}

- (void)cancelTrackingWithEvent:(UIEvent*)event {
    [self releaseHeldKey];
}

- (void)releaseHeldKey {
    _directionTracking = NO;
    [self setHeldKey:0];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window == nil) {
        [self releaseHeldKey];
    }
}

@end
#endif
