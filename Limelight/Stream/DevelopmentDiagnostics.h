#import <Foundation/Foundation.h>
#import "StreamConfiguration.h"

// Activated only by a private MoonlightDiagnostics.plist in the app bundle.
@interface MLDevelopmentDiagnostics : NSObject
+ (instancetype)shared;
@property(atomic, copy) NSDictionary* audioState;
@property(atomic, copy) void (^commandHandler)(NSString* command);
@property(atomic, copy) BOOL (^resumeHandler)(void);
- (void)startWithConfiguration:(StreamConfiguration*)configuration;
- (void)stop;
@end
