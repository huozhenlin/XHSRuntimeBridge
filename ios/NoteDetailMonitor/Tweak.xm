#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <os/log.h>

static NSString *const NDMCollectorURL =
    @"http://172.18.177.3:8901/events";
static NSString *const NDMCollectorTokenKey = @"XRBCollectorToken";
static NSString *const NDMCollectorURLKey = @"XRBCollectorEndpoint";
static NSString *const NDMMarkerHeader = @"X-NoteDetail-Monitor";
static NSString *const NDMLogDirectory = @"NoteDetailMonitor";
static NSString *const NDMLogFile = @"events.ndjson";

static os_log_t NDMLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.huozhenlin.notedetailmonitor", "runtime");
    });
    return log;
}

static NSString *NDMShortString(id value) {
    if (!value) return nil;
    NSString *text = [value isKindOfClass:NSString.class]
        ? value
        : [value description];
    if (text.length > 256) {
        text = [text substringToIndex:256];
    }
    return text;
}

static id NDMJSONSafe(id value) {
    if (!value) return [NSNull null];
    if ([value isKindOfClass:NSString.class] ||
        [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSNull.class]) {
        return value;
    }
    if ([value isKindOfClass:NSURL.class]) {
        return [value absoluteString] ?: @"";
    }
    return NDMShortString(value) ?: [NSNull null];
}

static NSURL *NDMEndpoint(void) {
    NSString *configured =
        [NSUserDefaults.standardUserDefaults stringForKey:NDMCollectorURLKey];
    NSString *value = configured.length > 0 ? configured : NDMCollectorURL;
    if (![value containsString:@"://"]) {
        value = [@"http://" stringByAppendingString:value];
    }
    if (NSURL *url = [NSURL URLWithString:value]) {
        if (url.path.length == 0) {
            return [NSURL URLWithString:
                [value stringByAppendingString:@"/events"]];
        }
        return url;
    }
    return nil;
}

static NSString *NDMToken(void) {
    return [NSUserDefaults.standardUserDefaults
        stringForKey:NDMCollectorTokenKey] ?: @"";
}

static NSURL *NDMLocalLogURL(void) {
    NSArray<NSURL *> *documents = [
        NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask
    ];
    NSURL *directory = [[documents firstObject]
        URLByAppendingPathComponent:NDMLogDirectory
        isDirectory:YES];
    [NSFileManager.defaultManager
        createDirectoryAtURL:directory
        withIntermediateDirectories:YES
        attributes:nil
        error:nil];
    return [directory URLByAppendingPathComponent:NDMLogFile];
}

static void NDMPostEvent(NSDictionary *event) {
    if (!event) return;

    NSMutableDictionary *payload = [NSMutableDictionary
        dictionaryWithDictionary:event];
    payload[@"event_time_ms"] = @(
        (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)
    );
    payload[@"pid"] = @(NSProcessInfo.processInfo.processIdentifier);
    payload[@"bundle_id"] =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    NSError *error = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:&error];
    if (!body || error) return;

    NSURL *localURL = NDMLocalLogURL();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSFileHandle *handle = [
                NSFileHandle fileHandleForWritingToURL:localURL
                                                 error:nil
            ];
            if (!handle) {
                [body writeToURL:localURL options:NSDataWritingAtomic error:nil];
                handle = [NSFileHandle fileHandleForWritingToURL:localURL
                                                            error:nil];
            }
            [handle seekToEndOfFile];
            [handle writeData:body];
            [handle writeData:[@"\n"
                dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    });

    NSURL *endpoint = NDMEndpoint();
    if (!endpoint) return;

    NSMutableURLRequest *request = [
        NSMutableURLRequest requestWithURL:endpoint
    ];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json"
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"1" forHTTPHeaderField:NDMMarkerHeader];
    NSString *token = NDMToken();
    if (token.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token]
       forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [
        [NSURLSession sessionWithConfiguration:
            NSURLSessionConfiguration.ephemeralSessionConfiguration]
        dataTaskWithRequest:request
        completionHandler:^(
            __unused NSData *responseData,
            __unused NSURLResponse *response,
            NSError *postError
        ) {
            if (postError) {
                os_log_error(NDMLog(), "POST failed: %{public}@",
                             postError.localizedDescription);
            }
        }
    ];
    [task resume];
}

static BOOL NDMIsSensitiveKey(NSString *key) {
    NSString *normalized = [[key lowercaseString]
        stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [normalized containsString:@"token"] ||
        [normalized containsString:@"cookie"] ||
        [normalized containsString:@"session"] ||
        [normalized isEqualToString:@"sid"] ||
        [normalized isEqualToString:@"did"];
}

static NSArray<NSString *> *NDMKeys(void) {
    return @[
        @"noteId", @"noteID", @"note_id",
        @"userId", @"userID", @"user_id", @"authorId", @"author_id",
        @"source", @"sourceType", @"source_type", @"scene", @"entry",
        @"feedId", @"feed_id"
    ];
}

static BOOL NDMHasDirectGetter(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!selector) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    const char *encoding = method_getTypeEncoding(method);
    return encoding && encoding[0] == '@';
}

static id NDMReadKnownValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    if ([object isKindOfClass:NSDictionary.class]) {
        return [(NSDictionary *)object objectForKey:key];
    }

    Class cls = object_getClass(object);
    if (!NDMHasDirectGetter(cls, key)) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSDictionary *NDMExtractBusinessFields(id object) {
    if (!object) {
        return @{
            @"note_id": [NSNull null],
            @"user_id": [NSNull null],
            @"source": [NSNull null]
        };
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in NDMKeys()) {
        if (NDMIsSensitiveKey(key)) continue;
        id value = NDMReadKnownValue(object, key);
        if (!value) continue;

        NSString *normalized = [key lowercaseString];
        NSString *outputKey = key;
        if ([normalized containsString:@"note"]) {
            outputKey = @"note_id";
        } else if ([normalized containsString:@"user"] ||
                   [normalized containsString:@"author"]) {
            outputKey = @"user_id";
        } else if ([normalized containsString:@"source"] ||
                   [normalized containsString:@"scene"] ||
                   [normalized containsString:@"entry"]) {
            outputKey = @"source";
        } else if ([normalized containsString:@"feed"]) {
            outputKey = @"feed_id";
        } else if ([normalized containsString:@"router"] ||
                   [normalized containsString:@"route"]) {
            outputKey = @"router_params";
        }
        if (!result[outputKey]) result[outputKey] = NDMJSONSafe(value);
    }

    if (!result[@"note_id"]) result[@"note_id"] = [NSNull null];
    if (!result[@"user_id"]) result[@"user_id"] = [NSNull null];
    if (!result[@"source"]) result[@"source"] = [NSNull null];
    return result;
}

static NSString *NDMControllerName(UIViewController *controller) {
    return controller ? NSStringFromClass(controller.class) : @"";
}

static BOOL NDMLooksLikeDetailController(UIViewController *controller) {
    NSString *name = NDMControllerName(controller).lowercaseString;
    return [name containsString:@"notedetail"] ||
        [name containsString:@"note_detail"] ||
        [name containsString:@"detailviewcontroller"];
}

static void NDMReportController(
    UIViewController *controller,
    NSString *navigationKind,
    NSDictionary *routeFields
) {
    if (!NDMLooksLikeDetailController(controller)) return;

    Class controllerClass = controller.class;
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": @"note_detail_candidate",
        @"navigation": navigationKind ?: @"",
        @"controller": NDMControllerName(controller),
        @"superclass": NSStringFromClass(class_getSuperclass(controllerClass)) ?: @""
    }];
    if (routeFields) [event addEntriesFromDictionary:routeFields];

    NSDictionary *controllerFields = NDMExtractBusinessFields(controller);
    [event addEntriesFromDictionary:controllerFields];

    for (NSString *modelKey in @[
        @"note", @"noteModel", @"contentNoteModel", @"noteFeed", @"feed"
    ]) {
        id model = NDMReadKnownValue(controller, modelKey);
        if (!model) continue;
        NSDictionary *modelFields = NDMExtractBusinessFields(model);
        for (NSString *key in @[@"note_id", @"user_id", @"source", @"feed_id"]) {
            id value = modelFields[key];
            if (value && value != [NSNull null] && ![event[key] isEqual:value]) {
                if (!event[key] || event[key] == [NSNull null]) {
                    event[key] = value;
                }
            }
        }
        event[@"model_class"] = NSStringFromClass(object_getClass(model));
        break;
    }
    NDMPostEvent(event);
}

%group NoteDetailNavigation

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController
                  animated:(BOOL)animated {
    NDMReportController(viewController, @"push", nil);
    %orig;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewController
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    NDMReportController(viewController, @"present", nil);
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (NDMLooksLikeDetailController(self)) {
        NDMReportController(self, @"appear", nil);
    }
}

%end

%end

%ctor {
    @autoreleasepool {
        NDMPostEvent(@{
            @"event": @"note_detail_monitor_loaded"
        });
        %init(NoteDetailNavigation);
        NSLog(@"[NoteDetailMonitor] loaded");
    }
}
