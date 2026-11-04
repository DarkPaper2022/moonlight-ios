#import "DevelopmentDiagnostics.h"
#import "NetworkTraceBuffer.h"
#import <Network/Network.h>
#import <UIKit/UIKit.h>
#include <zlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static MLNetworkTraceBuffer traceBuffer;
static int traceActive;

static void CaptureTrace(void* context, const LI_NETWORK_TRACE_EVENT* event) {
    (void)context;
    if (__atomic_load_n(&traceActive, __ATOMIC_RELAXED)) MLNetworkTraceBufferPush(&traceBuffer, event);
}

static NSData* GzipTrace(NSData* input) {
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_BEST_SPEED, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    NSMutableData* output = [NSMutableData dataWithLength:compressBound(input.length) + 32];
    stream.next_in = (Bytef*)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)output.length;
    int result = deflate(&stream, Z_FINISH);
    output.length = stream.total_out;
    deflateEnd(&stream);
    return result == Z_STREAM_END ? output : nil;
}

@implementation MLDevelopmentDiagnostics {
    BOOL _enabled;
    NSDictionary* _configuration;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSURLSession* _uploader;
    NSURL* _spool;
    NSString* _sessionID;
    NSUInteger _batchNumber;
    NSUInteger _endpointIndex;
    NSUInteger _failures;
    uint64_t _uploadedBytes;
    uint64_t _uploadedBatches;
    uint64_t _spoolDroppedBatches;
    NSTimeInterval _retryAt;
    BOOL _uploading;
    NSString* _lastError;
    NSDictionary* _pathState;
    nw_path_monitor_t _pathMonitor;
    NSMapTable<NSString*, UIControl*>* _controls;
}

+ (instancetype)shared {
    static MLDevelopmentDiagnostics* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSURL* configURL = [[NSBundle mainBundle] URLForResource:@"MoonlightDiagnostics" withExtension:@"plist"];
    _configuration = configURL ? [NSDictionary dictionaryWithContentsOfURL:configURL] : nil;
    NSArray* endpoints = _configuration[@"EndpointURLs"];
    if (![_configuration[@"Enabled"] boolValue] || endpoints.count == 0 ||
        [_configuration[@"BearerToken"] length] < 32) return self;
    for (NSString* endpoint in endpoints) {
        if (![[NSURL URLWithString:endpoint].scheme isEqualToString:@"https"]) return self;
    }
    _Static_assert(sizeof(LI_NETWORK_TRACE_EVENT) == 32, "trace schema requires 32-byte records");
    if (CFByteOrderGetCurrent() != CFByteOrderLittleEndian || !MLNetworkTraceBufferInit(&traceBuffer, 65536)) return self;
    _enabled = YES;
    _queue = dispatch_queue_create("moonlight.development.diagnostics", DISPATCH_QUEUE_SERIAL);
    _spool = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
              URLByAppendingPathComponent:@"MoonlightDiagnostics" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:_spool withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSURLSessionConfiguration* session = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    session.timeoutIntervalForRequest = 10;
    session.timeoutIntervalForResource = 20;
    session.waitsForConnectivity = NO;
    session.HTTPMaximumConnectionsPerHost = 1;
    session.networkServiceType = NSURLNetworkServiceTypeBackground;
    _uploader = [NSURLSession sessionWithConfiguration:session];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    __weak MLDevelopmentDiagnostics* weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        MLDevelopmentDiagnostics* strongSelf = weakSelf;
        [strongSelf flushTrace];
        [strongSelf uploadNext];
    });
    dispatch_resume(_timer);
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, _queue);
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        MLDevelopmentDiagnostics* strongSelf = weakSelf;
        if (!strongSelf) return;
        uint32_t flags = (nw_path_has_ipv4(path) ? 1 : 0) | (nw_path_has_ipv6(path) ? 2 : 0) |
                         (nw_path_is_expensive(path) ? 4 : 0) | (nw_path_is_constrained(path) ? 8 : 0);
        uint32_t interface = nw_path_uses_interface_type(path, nw_interface_type_wifi) ? 1 :
                             nw_path_uses_interface_type(path, nw_interface_type_cellular) ? 2 :
                             nw_path_uses_interface_type(path, nw_interface_type_wired) ? 3 : 0;
        strongSelf->_pathState = @{@"status":@(nw_path_get_status(path)), @"interface":@(interface), @"flags":@(flags)};
        LiEmitNetworkTrace(LI_TRACE_NETWORK_PATH, 3, 0, 0, interface, nw_path_get_status(path), flags, 0);
    });
    nw_path_monitor_start(_pathMonitor);
    [self startControlServer];
    return self;
}

- (void)startWithConfiguration:(StreamConfiguration*)configuration {
    if (!_enabled) return;
    dispatch_sync(_queue, ^{
        uint32_t discarded;
        MLNetworkTraceBufferTake(&traceBuffer, &discarded);
        __atomic_store_n(&traceBuffer.dropped, 0, __ATOMIC_RELAXED);
        self->_sessionID = NSUUID.UUID.UUIDString.lowercaseString;
        self->_batchNumber = 0;
        NSURL* directory = [self->_spool URLByAppendingPathComponent:self->_sessionID isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        NSISO8601DateFormatter* formatter = [[NSISO8601DateFormatter alloc] init];
        NSDictionary* manifest = @{
            @"schema":@1, @"record_bytes":@32, @"session":self->_sessionID,
            @"started_at":[formatter stringFromDate:NSDate.date],
            @"monotonic_us":@(LiGetNetworkTraceTimeUs()),
            @"wall_us":@((uint64_t)(NSDate.date.timeIntervalSince1970 * 1000000)),
            @"app_version":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
            @"system_version":UIDevice.currentDevice.systemVersion,
            @"width":@(configuration.width), @"height":@(configuration.height),
            @"fps":@(configuration.frameRate), @"bitrate_kbps":@(configuration.bitRate),
            @"audio_playout_delay_ms":@([[NSUserDefaults standardUserDefaults] integerForKey:@"targetAudioBufferMs"] ?: 150),
            @"path":self->_pathState ?: @{},
            @"trace_policy":@"metadata-only; bounded nonblocking producer; explicit dropped-record counters"
        };
        NSData* bytes = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
        [bytes writeToURL:[directory URLByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:nil];
    });
    __atomic_store_n(&traceActive, 1, __ATOMIC_RELAXED);
    LiSetNetworkTraceCallback(CaptureTrace, NULL);
    LiEmitNetworkTrace(LI_TRACE_SESSION, 3, 0, 0, 1, 0, 0, 0);
}

- (void)stop {
    if (!_enabled) return;
    LiEmitNetworkTrace(LI_TRACE_SESSION, 3, 0, 0, 0, 0, 0, 0);
    LiSetNetworkTraceCallback(NULL, NULL);
    __atomic_store_n(&traceActive, 0, __ATOMIC_RELAXED);
    dispatch_sync(_queue, ^{ [self flushTrace]; [self uploadNext]; });
}

- (void)flushTrace {
    if (!_sessionID) return;
    uint32_t count = 0;
    const LI_NETWORK_TRACE_EVENT* records = MLNetworkTraceBufferTake(&traceBuffer, &count);
    if (count == 0) return;
    struct {
        char magic[8]; uint32_t version; uint32_t recordBytes; uint32_t count; uint32_t reserved; uint64_t dropped;
    } header = {{'M','L','T','R','A','C','E','1'},1,32,count,0,MLNetworkTraceBufferDropped(&traceBuffer)};
    _Static_assert(sizeof(header) == 32, "trace header size");
    NSMutableData* bytes = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    [bytes appendBytes:records length:(NSUInteger)count * sizeof(*records)];
    NSData* compressed = GzipTrace(bytes);
    if (!compressed) { _spoolDroppedBatches++; return; }
    NSURL* directory = [_spool URLByAppendingPathComponent:_sessionID isDirectory:YES];
    NSString* name = [NSString stringWithFormat:@"%010lu.mtrace.gz", (unsigned long)_batchNumber++];
    if (![compressed writeToURL:[directory URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil]) _spoolDroppedBatches++;
    [self pruneSpool];
    LiEmitNetworkTrace(LI_TRACE_MARKER, 3, 0, 0, 2, (uint32_t)_spoolDroppedBatches, 0, 0);
}

- (NSArray<NSURL*>*)pendingFiles {
    NSMutableArray<NSURL*>* files = [NSMutableArray array];
    NSDirectoryEnumerator* enumerator = [[NSFileManager defaultManager] enumeratorAtURL:_spool
                           includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey] options:0 errorHandler:nil];
    for (NSURL* url in enumerator) {
        if ([url.lastPathComponent isEqualToString:@"manifest.json"] || [url.lastPathComponent hasSuffix:@".mtrace.gz"]) [files addObject:url];
    }
    return [files sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
        NSComparisonResult order = [a.URLByDeletingLastPathComponent.lastPathComponent compare:b.URLByDeletingLastPathComponent.lastPathComponent];
        if (order != NSOrderedSame) return order;
        if ([a.lastPathComponent isEqualToString:@"manifest.json"]) return NSOrderedAscending;
        if ([b.lastPathComponent isEqualToString:@"manifest.json"]) return NSOrderedDescending;
        return [a.lastPathComponent compare:b.lastPathComponent];
    }];
}

- (void)pruneSpool {
    NSArray<NSURL*>* files = [self pendingFiles];
    uint64_t size = 0;
    for (NSURL* file in files) {
        NSNumber* bytes; [file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil]; size += bytes.unsignedLongLongValue;
    }
    // A disconnected developer endpoint cannot exhaust the iPad's storage.
    for (NSURL* file in files) {
        if (size <= 32 * 1024 * 1024) break;
        if (![file.lastPathComponent hasSuffix:@".mtrace.gz"]) continue;
        NSNumber* bytes; [file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
        if ([[NSFileManager defaultManager] removeItemAtURL:file error:nil]) {
            size -= bytes.unsignedLongLongValue; _spoolDroppedBatches++;
        }
    }
}

- (void)uploadNext {
    if (_uploading || NSDate.date.timeIntervalSince1970 < _retryAt) return;
    NSURL* file = [self pendingFiles].firstObject;
    if (!file) return;
    NSString* session = file.URLByDeletingLastPathComponent.lastPathComponent;
    BOOL manifest = [file.lastPathComponent isEqualToString:@"manifest.json"];
    NSString* suffix = manifest ? @"manifest" : [@"batches/" stringByAppendingString:[file.lastPathComponent componentsSeparatedByString:@"."].firstObject];
    NSArray* endpoints = _configuration[@"EndpointURLs"];
    NSString* base = endpoints[_endpointIndex % endpoints.count];
    NSURL* endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"%@/sessions/%@/%@",base,session,suffix]];
    NSData* body = [NSData dataWithContentsOfURL:file];
    if (!body) return;
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    [request setValue:[@"Bearer " stringByAppendingString:_configuration[@"BearerToken"]] forHTTPHeaderField:@"Authorization"];
    [request setValue:manifest ? @"application/json" : @"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%lu",(unsigned long)body.length] forHTTPHeaderField:@"Content-Length"];
    if (!manifest) [request setValue:@"gzip" forHTTPHeaderField:@"Content-Encoding"];
    _uploading = YES;
    [[_uploader uploadTaskWithRequest:request fromData:body completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        dispatch_async(self->_queue, ^{
            self->_uploading = NO;
            NSInteger status = [(NSHTTPURLResponse*)response statusCode];
            if (!error && status >= 200 && status < 300) {
                [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
                self->_uploadedBytes += body.length;
                self->_uploadedBatches += !manifest;
                self->_failures = 0; self->_lastError = nil;
                self->_retryAt = NSDate.date.timeIntervalSince1970 + 0.1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 100), self->_queue, ^{ [self uploadNext]; });
            } else {
                self->_lastError = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld",(long)status];
                self->_endpointIndex++;
                self->_failures++;
                self->_retryAt = NSDate.date.timeIntervalSince1970 + MIN(30, 1 << MIN(5,self->_failures));
            }
        });
    }] resume];
}

- (NSDictionary*)snapshot {
    __block NSDictionary* result;
    dispatch_sync(_queue, ^{
        result = @{@"enabled":@(self->_enabled), @"active":@(__atomic_load_n(&traceActive,__ATOMIC_RELAXED)),
                   @"session":self->_sessionID ?: @"", @"dropped_records":@(MLNetworkTraceBufferDropped(&traceBuffer)),
                   @"spool_dropped_batches":@(self->_spoolDroppedBatches), @"pending_files":@([self pendingFiles].count),
                   @"uploaded_batches":@(self->_uploadedBatches), @"uploaded_bytes":@(self->_uploadedBytes),
                   @"last_upload_error":self->_lastError ?: @"", @"path":self->_pathState ?: @{},
                   @"audio":self.audioState ?: @{},
                   @"version":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""};
    });
    return result;
}

// These controls are invoked through UIKit's public action dispatch on the main
// thread. They do not synthesize private UITouch objects or affect other apps.
- (void)collectControls:(UIView*)view result:(NSMutableArray*)result {
    if (view.hidden || view.alpha < 0.01 || result.count > 500) return;
    if ([view isKindOfClass:UIControl.class]) {
        NSString* identifier = [NSString stringWithFormat:@"%lu",(unsigned long)_controls.count];
        [_controls setObject:(UIControl*)view forKey:identifier];
        NSMutableArray* labels = [NSMutableArray array];
        NSMutableArray* pending = [NSMutableArray arrayWithObject:view];
        while (pending.count && labels.count < 8) {
            UIView* item = pending.lastObject; [pending removeLastObject];
            if ([item isKindOfClass:UILabel.class] && ((UILabel*)item).text.length) [labels addObject:((UILabel*)item).text];
            [pending addObjectsFromArray:item.subviews];
        }
        [result addObject:@{@"id":identifier, @"class":NSStringFromClass(view.class), @"labels":labels,
                            @"enabled":@(((UIControl*)view).enabled), @"frame":NSStringFromCGRect([view convertRect:view.bounds toView:view.window])}];
    }
    for (UIView* child in view.subviews) [self collectControls:child result:result];
}

- (NSDictionary*)controlUI:(NSString*)path {
    __block NSDictionary* result;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if ([path isEqualToString:@"/ui"]) {
            self->_controls = [NSMapTable strongToWeakObjectsMapTable];
            NSMutableArray* controls = [NSMutableArray array];
            for (UIWindow* window in UIApplication.sharedApplication.windows) [self collectControls:window result:controls];
            result = @{@"controls":controls};
        } else {
            UIControl* control = [self->_controls objectForKey:path.lastPathComponent];
            if (control && control.window && control.enabled) {
                UIControlEvents event = (control.allControlEvents & UIControlEventPrimaryActionTriggered) ? UIControlEventPrimaryActionTriggered : UIControlEventTouchUpInside;
                [control sendActionsForControlEvents:event];
                result = @{@"activated":@YES};
            } else result = @{@"error":@"control missing; refresh /ui"};
        }
    });
    return result;
}

- (void)startControlServer {
    if (![_configuration[@"ControlEnabled"] boolValue]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
        struct sockaddr_in address = {0}; address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(9537);
        if (bind(listener,(struct sockaddr*)&address,sizeof(address)) != 0 || listen(listener,8) != 0) { close(listener); return; }
        while (YES) {
            int client = accept(listener,NULL,NULL);
            if (client < 0) break;
            @autoreleasepool {
                struct timeval timeout = {2,0};
                setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
                setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
                char bytes[8193] = {0}; ssize_t count = 0;
                while (count < 8192 && !strstr(bytes,"\r\n\r\n")) {
                    ssize_t readBytes = recv(client,bytes+count,8192-count,0);
                    if (readBytes <= 0) break;
                    count += readBytes; bytes[count] = 0;
                }
                NSString* text = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding] ?: @"";
                NSArray* lines = [text componentsSeparatedByString:@"\r\n"];
                NSArray* first = [lines.firstObject componentsSeparatedByString:@" "];
                NSString* path = first.count >= 2 ? first[1] : @"";
                BOOL authorized = NO;
                for (NSString* line in lines) {
                    if ([[line lowercaseString] hasPrefix:@"authorization:"]) {
                        NSString* value = [[line substringFromIndex:14] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        authorized = [value isEqualToString:[@"Bearer " stringByAppendingString:self->_configuration[@"BearerToken"]]];
                    }
                }
                int status = authorized ? 404 : 401;
                NSDictionary* result = @{@"error":authorized ? @"not found" : @"unauthorized"};
                if (authorized && ([path isEqualToString:@"/ui"] ||
                    ([first.firstObject isEqualToString:@"POST"] && [path hasPrefix:@"/ui/activate/"]))) {
                    status = 200; result = [self controlUI:path];
                }
                if (authorized && [path isEqualToString:@"/status"]) { status = 200; result = [self snapshot]; }
                if (authorized && [first.firstObject isEqualToString:@"POST"] && [path isEqualToString:@"/stream/resume"]) {
                    __block BOOL resumed = NO;
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        BOOL (^handler)(void) = self.resumeHandler;
                        if (!__atomic_load_n(&traceActive,__ATOMIC_RELAXED) && handler) resumed = handler();
                    });
                    status = resumed ? 202 : 409;
                    result = resumed ? @{@"queued":@YES} : @{@"error":@"no running application to resume"};
                }
                if (authorized && [first.firstObject isEqualToString:@"POST"] &&
                    ([path isEqualToString:@"/audio/pause-output"] || [path isEqualToString:@"/audio/rebuild"])) {
                    if (__atomic_load_n(&traceActive,__ATOMIC_RELAXED) && self.commandHandler) {
                        self.commandHandler(path); status = 202; result = @{@"queued":@YES};
                    } else { status = 409; result = @{@"error":@"no active stream"}; }
                }
                NSData* body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                NSString* head = [NSString stringWithFormat:@"HTTP/1.1 %d Response\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",status,(unsigned long)body.length];
                NSData* headers = [head dataUsingEncoding:NSUTF8StringEncoding];
                send(client,headers.bytes,headers.length,0); send(client,body.bytes,body.length,0);
            }
            close(client);
        }
        close(listener);
    });
}
@end
