#import "DirectionalKeyControl.h"
#import "DirectionalKeyState.h"

#if !TARGET_OS_TV
@implementation DirectionalKeyControl {
    DirectionalKeyState _keyState;
    NSArray<UIButton*>* _buttons;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSMutableArray<UIButton*>* buttons = [NSMutableArray array];
        NSArray* titles = @[@"←", @"↑", @"↓", @"→"];
        NSArray* labels = @[@"Left arrow", @"Up arrow", @"Down arrow", @"Right arrow"];
        const unsigned short codes[] = {0x25, 0x26, 0x28, 0x27};
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton* button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.tag = codes[i];
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
            button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
            button.layer.cornerRadius = 8;
            button.accessibilityLabel = labels[i];
            button.accessibilityHint = @"Hold to keep the keyboard arrow pressed.";
            // Standard UIKit events: DOWN immediately, UP on lift, exit or cancel.
            [button addTarget:self action:@selector(pressDirection:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
            [button addTarget:self action:@selector(releaseDirection:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
            [buttons addObject:button];
        }
        _buttons = [buttons copy];
        UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:_buttons];
        row.spacing = 4;
        row.distribution = UIStackViewDistributionFillEqually;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:self.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
        ]];
    }
    return self;
}

- (void)setKey:(unsigned short)key pressed:(BOOL)pressed {
    DirectionalKeyTransition transition = DirectionalKeySetPressed(&_keyState, key, pressed);
    if (transition.keyUp && self.keyEventHandler) self.keyEventHandler(transition.keyUp, NO);
    if (transition.keyDown && self.keyEventHandler) self.keyEventHandler(transition.keyDown, YES);
    for (UIButton* button in _buttons) {
        button.selected = DirectionalKeyIsPressed(&_keyState, (unsigned short)button.tag);
        button.backgroundColor = button.selected ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.2 alpha:1.0];
    }
}

- (void)pressDirection:(UIButton*)button {
    [self setKey:(unsigned short)button.tag pressed:YES];
}

- (void)releaseDirection:(UIButton*)button {
    [self setKey:(unsigned short)button.tag pressed:NO];
}

- (void)releaseHeldKey {
    for (UIButton* button in _buttons) {
        [self setKey:(unsigned short)button.tag pressed:NO];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window == nil) [self releaseHeldKey];
}

@end
#endif
