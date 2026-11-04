#import "XHSRuntimeLogger.h"

#import <os/log.h>

static NSString *const XRBMarkerHeader = @"X-XHS-Runtime-Logger";
static NSString *const XRBDefaultLogDirectory = @"XHSRuntimeBridge";
static NSString *const XRBDefaultLogFile = @"events.ndjson";
static const NSUInteger XRBMaximumEventBytes = 512 * 1024;

@interface XRBLogger : NSObject

@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURL *endpoint;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong) NSURL *localLogURL;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL includeResponseBody;
@property(nonatomic, assign) NSUInteger maximumResponseBytes;

+ (instancetype)shared;
- (void)start;
- (void)appendEvent:(NSString *)event fields:(nullable NSDictionary *)fields;

@end

static os_log_t XRBSystemLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.xhs.runtimebridge", "runtime");
    });
    return log;
}

static id XRBSanitizeObject(id value);

static BOOL XRBLooksSensitive(NSString *key) {
    NSString *normalized = [[key lowercaseString]
        stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if ([normalized hasSuffix:@"_present"] ||
        [normalized hasSuffix:@"_length"]) {
        return NO;
    }

    static NSSet<NSString *> *exactKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactKeys = [NSSet setWithArray:@[
            @"authorization", @"cookie", @"set_cookie",
            @"password", @"passwd", @"secret",
            @"access_token", @"refresh_token",
            @"session", @"session_id", @"sid", @"fid", @"did",
            @"device_id", @"x_s", @"x_t", @"xsec_token", @"api_key"
        ]];
    });
    return [exactKeys containsObject:normalized] ||
        [normalized hasSuffix:@"_authorization"] ||
        [normalized hasSuffix:@"_cookie"] ||
        [normalized hasSuffix:@"_token"] ||
        [normalized hasSuffix:@"_secret"];
}

static id XRBSanitizeObject(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:
            ^(id key, id child, BOOL *stop) {
                (void)stop;
                NSString *textKey = [key description] ?: @"unknown";
                result[textKey] = XRBLooksSensitive(textKey)
                    ? @"<redacted>"
                    : XRBSanitizeObject(child);
            }];
        return result;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id child in (NSArray *)value) {
            [result addObject:XRBSanitizeObject(child)];
        }
        return result;
    }
    if ([value isKindOfClass:NSString.class] ||
        [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSNull.class]) {
        return value;
    }
    if ([value isKindOfClass:NSURL.class]) {
        return [(NSURL *)value absoluteString] ?: @"";
    }
    return [value description] ?: @"<unknown>";
}

static NSDictionary *XRBLoadConfiguration(void) {
    NSMutableDictionary *configuration = [NSMutableDictionary dictionary];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;

    id endpoint = info[@"XHSRuntimeCollectorURL"];
    id token = info[@"XHSRuntimeCollectorToken"];
    id includeBody = info[@"XHSRuntimeIncludeResponseBody"];
    id maximumBytes = info[@"XHSRuntimeMaximumResponseBytes"];

    if (endpoint) configuration[@"endpoint"] = endpoint;
    if (token) configuration[@"token"] = token;
    if (includeBody) configuration[@"include_response_body"] = includeBody;
    if (maximumBytes) configuration[@"maximum_response_bytes"] = maximumBytes;

    NSArray<NSURL *> *documents = [
        NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask
    ];
    NSURL *fileURL = [[documents firstObject]
        URLByAppendingPathComponent:@"xhs-runtime-logger.json"];
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (data.length > 0) {
        NSDictionary *fileConfiguration = [
            NSJSONSerialization JSONObjectWithData:data options:0 error:nil
        ];
        if ([fileConfiguration isKindOfClass:NSDictionary.class]) {
            [configuration addEntriesFromDictionary:fileConfiguration];
        }
    }
    return configuration;
}

@implementation XRBLogger

+ (instancetype)shared {
    static XRBLogger *logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = [[self alloc] initPrivate];
    });
    return logger;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;

    _queue = dispatch_queue_create(
        "com.xhs.runtimebridge.logger",
        DISPATCH_QUEUE_SERIAL
    );

    NSURLSessionConfiguration *configuration =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 5.0;
    configuration.timeoutIntervalForResource = 10.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:configuration];
    _token = @"";
    _enabled = YES;
    _includeResponseBody = NO;
    _maximumResponseBytes = 64 * 1024;

    NSArray<NSURL *> *documents = [
        NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask
    ];
    NSURL *directory = [[documents firstObject]
        URLByAppendingPathComponent:XRBDefaultLogDirectory
        isDirectory:YES];
    [NSFileManager.defaultManager
        createDirectoryAtURL:directory
        withIntermediateDirectories:YES
        attributes:nil
        error:nil];
    _localLogURL = [directory URLByAppendingPathComponent:XRBDefaultLogFile];
    return self;
}

- (instancetype)init {
    [NSException raise:NSInternalInconsistencyException
                format:@"Use +[XRBLogger shared]"];
    return nil;
}

- (void)start {
    NSDictionary *configuration = XRBLoadConfiguration();
    id enabled = configuration[@"enabled"];
    if ([enabled respondsToSelector:@selector(boolValue)]) {
        self.enabled = [enabled boolValue];
    }

    NSString *endpoint = configuration[@"endpoint"];
    if ([endpoint isKindOfClass:NSString.class]) {
        self.endpoint = [NSURL URLWithString:endpoint];
    }

    NSString *token = configuration[@"token"];
    if ([token isKindOfClass:NSString.class]) {
        self.token = token;
    }

    id includeBody = configuration[@"include_response_body"];
    if ([includeBody respondsToSelector:@selector(boolValue)]) {
        self.includeResponseBody = [includeBody boolValue];
    }

    id maximumBytes = configuration[@"maximum_response_bytes"];
    if ([maximumBytes respondsToSelector:@selector(unsignedIntegerValue)]) {
        NSUInteger requested = [maximumBytes unsignedIntegerValue];
        self.maximumResponseBytes = MAX(
            1024,
            MIN(requested, XRBMaximumEventBytes)
        );
    }

    os_log_error(
        XRBSystemLog(),
        "XHSRuntimeBridge logger started endpoint=%{public}@ local=%{public}@",
        self.endpoint.absoluteString ?: @"<local-only>",
        self.localLogURL.path
    );
}

- (void)appendEvent:(NSString *)event fields:(NSDictionary *)fields {
    if (!self.enabled || event.length == 0) return;

    dispatch_async(self.queue, ^{
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[@"event"] = event;
        payload[@"time"] = @(
            (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)
        );
        payload[@"pid"] = @(NSProcessInfo.processInfo.processIdentifier);
        payload[@"thread"] = NSThread.isMainThread ? @"main" : @"background";
        payload[@"bundle_id"] =
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        payload[@"app_version"] =
            [NSBundle.mainBundle objectForInfoDictionaryKey:
                @"CFBundleShortVersionString"] ?: @"unknown";
        if (fields.count > 0) {
            [payload addEntriesFromDictionary:fields];
        }

        NSDictionary *sanitized = XRBSanitizeObject(payload);
        if (![NSJSONSerialization isValidJSONObject:sanitized]) return;

        NSError *error = nil;
        NSData *body = [
            NSJSONSerialization dataWithJSONObject:sanitized
            options:0
            error:&error
        ];
        if (body.length == 0 || body.length > XRBMaximumEventBytes || error) {
            return;
        }

        [self appendLocally:body];
        [self postBody:body];
    });
}

- (void)appendLocally:(NSData *)body {
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:
        self.localLogURL error:nil];
    if (!handle) {
        [body writeToURL:self.localLogURL options:NSDataWritingAtomic error:nil];
        handle = [NSFileHandle fileHandleForWritingToURL:
            self.localLogURL error:nil];
    }
    if (!handle) return;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:body];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

- (void)postBody:(NSData *)body {
    if (!self.endpoint) return;

    NSMutableURLRequest *request = [
        NSMutableURLRequest requestWithURL:self.endpoint
    ];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"1" forHTTPHeaderField:XRBMarkerHeader];
    if (self.token.length > 0) {
        [request setValue:
            [@"Bearer " stringByAppendingString:self.token]
            forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [self.session
        dataTaskWithRequest:request
        completionHandler:^(
            NSData *data,
            NSURLResponse *response,
            NSError *error
        ) {
            (void)data;
            (void)response;
            if (error) {
                os_log_error(
                    XRBSystemLog(),
                    "collector POST failed: %{public}@",
                    error.localizedDescription
                );
            }
        }];
    [task resume];
}

@end

void XRBStartLogger(void) {
    [[XRBLogger shared] start];
}

void XRBLogEvent(NSString *event, NSDictionary<NSString *, id> *fields) {
    [[XRBLogger shared] appendEvent:event fields:fields];
}

BOOL XRBIsCollectorRequest(NSURLRequest *request) {
    return [[request valueForHTTPHeaderField:XRBMarkerHeader] isEqualToString:@"1"];
}
