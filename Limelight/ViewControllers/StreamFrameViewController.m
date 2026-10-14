//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#include "StreamLayoutState.h"
#include "StreamVideoGeometry.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
    UIView* _videoContainer;
    NSArray<NSLayoutConstraint*>* _landscapeConstraints;
    NSArray<NSLayoutConstraint*>* _portraitConstraints;
    UIStackView* _streamButtons;
    UIButton* _rotationButton;
    BOOL _portraitLayout;
    BOOL _streamConnected;
    CGSize _lastVideoSize;
    UIInterfaceOrientationMask _orientationMask;
    StreamLayoutState _layoutState;
    BOOL _videoRotated;
#endif
}

- (void)startStreamWithLaidOutViewport {
    if (_streamMan != nil || self.view.window == nil) {
        return;
    }
    // The view must be attached and laid out before negotiating native pixels.
    [self.view layoutIfNeeded];
#if !TARGET_OS_TV
    if (self.streamConfig.nativeResolution) {
        CGRect viewport = _videoContainer.bounds;
        if (self.streamConfig.nativeResolutionUsesSafeArea) {
            CGRect safeArea = [self.view convertRect:self.view.safeAreaLayoutGuide.layoutFrame toView:_videoContainer];
            viewport = CGRectIntersection(viewport, safeArea);
        }
        StreamPixelSize pixels = StreamNativePixelsForViewport(viewport.size.width, viewport.size.height,
                                                               self.view.window.screen.scale);
        if (pixels.width > 0 && pixels.height > 0) {
            Log(LOG_I, @"Native video viewport: %.0fx%.0f pt -> %dx%d px (previous profile %dx%d)",
                viewport.size.width, viewport.size.height, pixels.width, pixels.height,
                self.streamConfig.width, self.streamConfig.height);
            self.streamConfig.width = pixels.width;
            self.streamConfig.height = pixels.height;
        }
    }
#endif
    [_streamView setStreamVideoSize:CGSizeMake(self.streamConfig.width, self.streamConfig.height)];
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                         renderView:_streamView
                                connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
    [self invalidateOrientationPolicy];
#endif
    [self startStreamWithLaidOutViewport];
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
#if !TARGET_OS_TV
    _orientationMask = UIInterfaceOrientationMaskLandscape;
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
#endif
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.bounds];
    _streamView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

#if !TARGET_OS_TV
    _videoContainer = [[UIView alloc] init];
    _videoContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _videoContainer.backgroundColor = [UIColor blackColor];
    _videoContainer.clipsToBounds = YES;
    [self.view addSubview:_videoContainer];
    UIView* videoParent = _videoContainer;
#else
    UIView* videoParent = self.view;
#endif
    
    // Only enable scroll and zoom in absolute touch mode
    if (_settings.absoluteTouchMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [videoParent addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [videoParent addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
#if !TARGET_OS_TV
    [self setupStreamLayout];
#endif
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
#if !TARGET_OS_TV
        _streamConnected = NO;
        [_streamView hideKeyboard];
#endif
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if !TARGET_OS_TV
- (void)setupStreamLayout {
    UILayoutGuide* safeArea = self.view.safeAreaLayoutGuide;
    _landscapeConstraints = @[
        [_videoContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_videoContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_videoContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_videoContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ];
    NSLayoutConstraint* halfHeight = [_videoContainer.heightAnchor constraintEqualToAnchor:safeArea.heightAnchor multiplier:0.5];
    // On smaller phones, leave room for keyboards taller than half the screen.
    halfHeight.priority = UILayoutPriorityDefaultHigh;
    _portraitConstraints = @[
        [_videoContainer.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [_videoContainer.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [_videoContainer.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        halfHeight,
        [_videoContainer.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]
    ];

    _rotationButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_rotationButton setImage:[UIImage systemImageNamed:@"rotate.right"] forState:UIControlStateNormal];
    _rotationButton.accessibilityLabel = @"Switch to portrait";
    [_rotationButton addTarget:self action:@selector(toggleStreamOrientation) forControlEvents:UIControlEventTouchUpInside];
    UIButton* keyboard = [UIButton buttonWithType:UIButtonTypeSystem];
    [keyboard setImage:[UIImage systemImageNamed:@"keyboard"] forState:UIControlStateNormal];
    keyboard.accessibilityLabel = @"Show or hide keyboard";
    [keyboard addTarget:_streamView action:@selector(toggleKeyboard) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton* button in @[_rotationButton, keyboard]) {
        button.tintColor = [UIColor whiteColor];
        button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
        button.layer.cornerRadius = 8;
        [button.widthAnchor constraintEqualToConstant:44].active = YES;
        [button.heightAnchor constraintEqualToConstant:44].active = YES;
    }
    _streamButtons = [[UIStackView alloc] initWithArrangedSubviews:@[keyboard, _rotationButton]];
    _streamButtons.spacing = 8;
    _streamButtons.translatesAutoresizingMaskIntoConstraints = NO;
    _streamButtons.userInteractionEnabled = NO;
    [self.view addSubview:_streamButtons];
    [NSLayoutConstraint activateConstraints:@[
        [_streamButtons.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8],
        [_streamButtons.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-8]
    ]];
    [self updateStreamLayoutForPortrait:StreamLayoutUsesKeyboard(&_layoutState, self.view.bounds.size.width, self.view.bounds.size.height)];
}

- (void)updateStreamLayoutForPortrait:(BOOL)portrait {
    [NSLayoutConstraint deactivateConstraints:_portraitLayout ? _portraitConstraints : _landscapeConstraints];
    _portraitLayout = portrait;
    [NSLayoutConstraint activateConstraints:portrait ? _portraitConstraints : _landscapeConstraints];
    _rotationButton.accessibilityLabel = portrait ? @"Switch to full-screen video" : @"Switch to video and keyboard";
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    BOOL portrait = StreamLayoutUsesKeyboard(&_layoutState, self.view.bounds.size.width, self.view.bounds.size.height);
    if (portrait != _portraitLayout) {
        [self updateStreamLayoutForPortrait:portrait];
    }
    CGSize containerSize = _videoContainer.bounds.size;
    BOOL rotateVideo = StreamLayoutRotatesVideo(&_layoutState, self.view.bounds.size.width, self.view.bounds.size.height);
    CGSize videoSize = rotateVideo ? CGSizeMake(containerSize.height, containerSize.width) : containerSize;
    if (!CGSizeEqualToSize(videoSize, _lastVideoSize) || rotateVideo != _videoRotated) {
        // Zoom transforms belong to the old viewport. Refit on viewport changes.
        [_scrollView setZoomScale:1.0 animated:NO];
        UIView* inputSurface = _scrollView != nil ? _scrollView : _streamView;
        inputSurface.autoresizingMask = UIViewAutoresizingNone;
        inputSurface.transform = CGAffineTransformIdentity;
        inputSurface.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
        inputSurface.center = CGPointMake(CGRectGetMidX(_videoContainer.bounds), CGRectGetMidY(_videoContainer.bounds));
        inputSurface.transform = rotateVideo ? CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
        if (_scrollView != nil) {
            _streamView.frame = _scrollView.bounds;
        }
        _scrollView.contentSize = videoSize;
        _lastVideoSize = videoSize;
        _videoRotated = rotateVideo;
        [_streamView setNeedsLayout];
    }
    _stageLabel.center = CGPointMake(CGRectGetMidX(_videoContainer.frame), CGRectGetMidY(_videoContainer.frame));
    _spinner.center = CGPointMake(_stageLabel.center.x, _stageLabel.center.y - _stageLabel.bounds.size.height - _spinner.bounds.size.height);
    _tipLabel.center = CGPointMake(_stageLabel.center.x, CGRectGetMaxY(_videoContainer.frame) - 40);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [_streamView releaseKeyboardKeys];
    BOOL portrait = StreamLayoutUsesKeyboard(&_layoutState, size.width, size.height);
    [self updateStreamLayoutForPortrait:portrait];
    if (!portrait) {
        [_streamView hideKeyboard];
    }
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (self->_streamConnected && self->_portraitLayout && self.view.window != nil) {
            [self->_streamView showKeyboard];
        }
    }];
}

- (void)invalidateOrientationPolicy {
    if (@available(iOS 16.0, *)) {
        // The reveal controller is the root container making rotation decisions.
        for (UIViewController* controller = self; controller != nil; controller = controller.parentViewController) {
            [controller setNeedsUpdateOfSupportedInterfaceOrientations];
        }
    }
}

- (void)toggleStreamOrientation {
    if (!_streamConnected) {
        return;
    }
    [_streamView releaseKeyboardKeys];
    BOOL keyboardLayout = StreamLayoutToggle(&_layoutState, self.view.bounds.size.width, self.view.bounds.size.height);
    [self updateStreamLayoutForPortrait:keyboardLayout];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    if (keyboardLayout) {
        [_streamView showKeyboard];
    } else {
        [_streamView hideKeyboard];
    }
    // The in-app layout works even in LiveContainer/native window modes which
    // prohibit requesting a different system interface orientation.
    if (_layoutState.sceneRotationUnavailable) {
        return;
    }
    uint64_t requestNumber = _layoutState.requestNumber;
    UIInterfaceOrientationMask previousMask = _orientationMask;
    _orientationMask = keyboardLayout ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscape;
    [self invalidateOrientationPolicy];
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS* preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:_orientationMask];
        __weak StreamFrameViewController* weakSelf = self;
        [self.view.window.windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                StreamFrameViewController* strongSelf = weakSelf;
                if (strongSelf == nil || !strongSelf->_streamConnected || strongSelf->_layoutState.requestNumber != requestNumber) return;
                StreamLayoutSceneRequestRejected(&strongSelf->_layoutState, requestNumber);
                strongSelf->_orientationMask = previousMask;
                [strongSelf invalidateOrientationPolicy];
                [strongSelf.view setNeedsLayout];
                [strongSelf.view layoutIfNeeded];
                Log(LOG_I, @"Scene rotation unavailable; keeping selected stream layout: %@", error);
            });
        }];
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return _orientationMask ?: UIInterfaceOrientationMaskLandscape;
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
#if !TARGET_OS_TV
    UIWindowScene* windowScene = self.view.window.windowScene;
    UIViewController* rootController = self.view.window.rootViewController;
    _streamConnected = NO;
    [_streamView hideKeyboard];
    _orientationMask = UIInterfaceOrientationMaskLandscape;
#endif
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
#if !TARGET_OS_TV
    [self invalidateOrientationPolicy];
    if (@available(iOS 16.0, *)) {
        [rootController setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowSceneGeometryPreferencesIOS* preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        if (!_layoutState.sceneRotationUnavailable) {
            [windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError* error) {
                Log(LOG_W, @"Restoring landscape after streaming failed: %@", error);
            }];
        }
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
#endif
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
#if !TARGET_OS_TV
    [_streamView releaseKeyboardKeys];
#endif
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
#if !TARGET_OS_TV
        self->_streamConnected = YES;
        self->_streamButtons.userInteractionEnabled = YES;
        if (self->_portraitLayout) {
            [self->_streamView showKeyboard];
        }
#endif
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
#if !TARGET_OS_TV
        self->_streamConnected = NO;
        self->_streamButtons.userInteractionEnabled = NO;
        [self->_streamView hideKeyboard];
#endif
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
