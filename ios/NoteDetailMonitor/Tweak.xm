#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <os/log.h>

static NSString *const NDMCollectorURL =
    @"http://172.18.177.3:8901/events";
static NSString *const NDMCollectorTokenKey = @"XRBCollectorToken";
static NSString *const NDMCollectorURLKey = @"XRBCollectorEndpoint";
static NSString *const NDMMarkerHeader = @"X-NoteDetail-Monitor";
static NSString *const NDMLogDirectory = @"NoteDetailMonitor";
static NSString *const NDMLogFile = @"events.ndjson";

static __weak id gLastRouteObject;
static SEL gRouteSelector;
static IMP gRouteOriginal;
static BOOL gRouteReturnsObject;
static NSString *gPendingRequestID;

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
        @"from", @"entrance", @"pageSource", @"openSource",
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
                   [normalized containsString:@"entry"] ||
                   [normalized containsString:@"from"] ||
                   [normalized containsString:@"entrance"]) {
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

static NSArray<NSString *> *NDMCallStack(void) {
    NSArray<NSString *> *symbols = NSThread.callStackSymbols;
    NSUInteger count = MIN((NSUInteger)20, symbols.count);
    return count > 0 ? [symbols subarrayWithRange:NSMakeRange(0, count)] : @[];
}

static NSArray<NSString *> *NDMDictionaryKeys(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in [(NSDictionary *)value allKeys]) {
        NSString *text = [key description] ?: @"";
        if (!NDMIsSensitiveKey(text) && text.length > 0) {
            [keys addObject:text];
        }
    }
    [keys sortUsingSelector:@selector(compare:)];
    return keys;
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
        @"superclass": NSStringFromClass(class_getSuperclass(controllerClass)) ?: @"",
        @"call_stack": NDMCallStack()
    }];
    if (routeFields) [event addEntriesFromDictionary:routeFields];

    NSDictionary *controllerFields = NDMExtractBusinessFields(controller);
    [event addEntriesFromDictionary:controllerFields];
    for (NSString *routeKey in @[@"routerParams", @"routeParams"]) {
        id routeParams = NDMReadKnownValue(controller, routeKey);
        NSArray<NSString *> *keys = NDMDictionaryKeys(routeParams);
        if (keys.count > 0) {
            event[@"route_param_keys"] = keys;
            break;
        }
    }

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
    id noteID = event[@"note_id"];
    if ([navigationKind isEqualToString:@"appear"] &&
        noteID && noteID != [NSNull null] &&
        [noteID isKindOfClass:NSString.class] &&
        [noteID length] > 0) {
        event[@"event"] = @"note_detail_open";
    }
    if (gPendingRequestID.length > 0) {
        event[@"request_id"] = gPendingRequestID;
        if ([event[@"event"] isEqualToString:@"note_detail_open"]) {
            gPendingRequestID = nil;
        }
    }
    NDMPostEvent(event);
}

static void NDMRouteObserved(id self, SEL selector, NSString *noteID) {
    gLastRouteObject = self;
    gRouteSelector = selector;
    Class runtimeClass = object_isClass(self)
        ? (Class)self
        : object_getClass(self);
    NDMPostEvent(@{
        @"event": @"note_route_observed",
        @"class": NSStringFromClass(runtimeClass) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"note_id": noteID ?: [NSNull null]
    });
}

static Method NDMDirectMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static void NDMScanRouteCandidates(void) {
    NSArray<NSString *> *selectorNames = @[
        @"openNoteDetail",
        @"transitionToNoteDetailWithNote:",
        @"routeToNoteDetailWithItem:atIndexPath:channel:anchorIndex:isDynamicCover:",
        @"routeToNoteDetailsWith:title:note:extraSkuInfos:",
        @"presentNoteDetailWithConfig:saveActionHandler:saveActionTrackHandler:shareToFriendResult:delegate:"
    ];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        for (NSString *selectorName in selectorNames) {
            SEL selector = NSSelectorFromString(selectorName);
            Method instanceMethod = NDMDirectMethod(cls, selector);
            if (instanceMethod) {
                const char *encoding = method_getTypeEncoding(instanceMethod);
                NDMPostEvent(@{
                    @"event": @"route_candidate_discovered",
                    @"class": NSStringFromClass(cls) ?: @"",
                    @"owner_kind": @"instance",
                    @"selector": selectorName,
                    @"type_encoding": encoding
                        ? [NSString stringWithUTF8String:encoding]
                        : @""
                });
            }

            Class metaClass = object_getClass(cls);
            Method classMethod = NDMDirectMethod(metaClass, selector);
            if (classMethod) {
                const char *encoding = method_getTypeEncoding(classMethod);
                NDMPostEvent(@{
                    @"event": @"route_candidate_discovered",
                    @"class": NSStringFromClass(cls) ?: @"",
                    @"owner_kind": @"class",
                    @"selector": selectorName,
                    @"type_encoding": encoding
                        ? [NSString stringWithUTF8String:encoding]
                        : @""
                });
            }
        }
    }
    free(classes);
}

static void NDMRouteHookVoid(id self, SEL selector, id noteID) {
    NDMRouteObserved(self, selector, NDMShortString(noteID));
    if (gRouteOriginal) {
        ((void (*)(id, SEL, id))gRouteOriginal)(self, selector, noteID);
    }
}

static id NDMRouteHookObject(id self, SEL selector, id noteID) {
    NDMRouteObserved(self, selector, NDMShortString(noteID));
    if (!gRouteOriginal) return nil;
    return ((id (*)(id, SEL, id))gRouteOriginal)(self, selector, noteID);
}

static void NDMInstallRouteHook(void) {
    if (gRouteOriginal) return;
    SEL selector = @selector(openNoteDetailWithNoteID:);
    NSMutableArray<NSString *> *foundClasses = [NSMutableArray array];

    NSArray<NSString *> *preferredClasses = @[
        @"XYPKPostNotesProgressTracker",
        @"XYNoteDetailRouter",
        @"XYNoteDetailServiceImp"
    ];

    for (NSString *className in preferredClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        Class owner = cls;
        NSString *ownerKind = @"instance";
        Method method = NDMDirectMethod(owner, selector);
        if (!method) {
            owner = object_getClass(cls);
            ownerKind = @"class";
            method = NDMDirectMethod(owner, selector);
        }
        if (!method) continue;
        [foundClasses addObject:className];

        const char *encoding = method_getTypeEncoding(method);
        IMP replacement = NULL;
        if (strcmp(encoding, "v24@0:8@16") == 0) {
            replacement = (IMP)NDMRouteHookVoid;
            gRouteReturnsObject = NO;
        } else if (strcmp(encoding, "@24@0:8@16") == 0) {
            replacement = (IMP)NDMRouteHookObject;
            gRouteReturnsObject = YES;
        } else {
            NDMPostEvent(@{
                @"event": @"route_hook_unsupported",
                @"class": className,
                @"selector": NSStringFromSelector(selector),
                @"type_encoding": encoding
                    ? [NSString stringWithUTF8String:encoding]
                    : @""
            });
            continue;
        }

        if (!NDMDirectMethod(owner, selector)) {
            class_addMethod(
                owner,
                selector,
                method_getImplementation(method),
                encoding
            );
            method = class_getInstanceMethod(owner, selector);
        }
        gRouteOriginal = method_setImplementation(method, replacement);
        gRouteSelector = selector;
        NDMPostEvent(@{
            @"event": @"route_hook_installed",
            @"class": className,
            @"owner_kind": ownerKind,
            @"selector": NSStringFromSelector(selector),
            @"type_encoding": encoding
                ? [NSString stringWithUTF8String:encoding]
                : @""
        });
        return;
    }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0;
             methodIndex < methodCount;
             methodIndex++) {
            Method method = methods[methodIndex];
            if (method_getName(method) != selector) continue;

            const char *encoding = method_getTypeEncoding(method);
            IMP replacement = NULL;
            if (strcmp(encoding, "v24@0:8@16") == 0) {
                replacement = (IMP)NDMRouteHookVoid;
                gRouteReturnsObject = NO;
            } else if (strcmp(encoding, "@24@0:8@16") == 0) {
                replacement = (IMP)NDMRouteHookObject;
                gRouteReturnsObject = YES;
            } else {
                NDMPostEvent(@{
                    @"event": @"route_hook_unsupported",
                    @"class": NSStringFromClass(cls) ?: @"",
                    @"selector": NSStringFromSelector(selector),
                    @"type_encoding": encoding
                        ? [NSString stringWithUTF8String:encoding]
                        : @""
                });
                continue;
            }

            gRouteOriginal = method_setImplementation(method, replacement);
            gRouteSelector = selector;
            NDMPostEvent(@{
                @"event": @"route_hook_installed",
                @"class": NSStringFromClass(cls) ?: @"",
                @"selector": NSStringFromSelector(selector),
                @"type_encoding": encoding
                    ? [NSString stringWithUTF8String:encoding]
                    : @""
            });
            free(methods);
            free(classes);
            return;
        }
        free(methods);
    }
    free(classes);
    NDMPostEvent(@{
        @"event": @"route_scan_completed",
        @"candidate_classes": foundClasses
    });
}

static NSURL *NDMCommandURL(void) {
    NSURL *endpoint = NDMEndpoint();
    if (!endpoint) return nil;
    NSURLComponents *components = [
        NSURLComponents componentsWithURL:endpoint
        resolvingAgainstBaseURL:NO
    ];
    components.path = @"/commands/next";
    components.query = nil;
    return components.URL;
}

static void NDMStartCommandPoll(void);

static void NDMExecuteCommand(NSDictionary *command) {
    NSString *name = command[@"command"];
    NSString *requestID = command[@"request_id"];
    NSString *noteID = command[@"note_id"];
    if (![name isEqualToString:@"open_note"] || noteID.length == 0) {
        return;
    }

    SEL selector = gRouteSelector ?: @selector(openNoteDetailWithNoteID:);
    id route = gLastRouteObject;
    if (!route || ![route respondsToSelector:selector]) {
        Class knownRouter = NSClassFromString(
            @"XYPKPostNotesProgressTracker"
        );
        if (knownRouter && [knownRouter respondsToSelector:selector]) {
            route = knownRouter;
            gRouteSelector = selector;
            gRouteReturnsObject = NO;
            NDMPostEvent(@{
                @"event": @"route_fallback_class",
                @"class": NSStringFromClass(knownRouter),
                @"selector": NSStringFromSelector(selector)
            });
        }
    }

    if (!route || ![route respondsToSelector:selector]) {
        NDMPostEvent(@{
            @"event": @"open_note_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID,
            @"reason": @"route_instance_not_observed"
        });
        return;
    }

    gPendingRequestID = requestID;
    NDMPostEvent(@{
        @"event": @"open_note_requested",
        @"request_id": requestID ?: @"",
        @"note_id": noteID,
        @"route_class": NSStringFromClass(
            object_isClass(route) ? (Class)route : object_getClass(route)
        ) ?: @""
    });

    BOOL returnsObject = gRouteReturnsObject;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (returnsObject) {
            ((id (*)(id, SEL, id))objc_msgSend)(route, selector, noteID);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(route, selector, noteID);
        }
    });
}

static void NDMPollCommands(void) {
    NDMInstallRouteHook();
    NSURL *URL = NDMCommandURL();
    if (!URL) {
        NDMStartCommandPoll();
        return;
    }

    NSMutableURLRequest *request = [
        NSMutableURLRequest requestWithURL:URL
    ];
    request.HTTPMethod = @"GET";
    [request setValue:@"1" forHTTPHeaderField:NDMMarkerHeader];
    NSString *token = NDMToken();
    if (token.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token]
       forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [
        [NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, __unused NSURLResponse *response,
                            __unused NSError *error) {
            if (data.length > 0) {
                NSDictionary *JSON = [
                    NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:nil
                ];
                NSDictionary *command = JSON[@"command"];
                if ([command isKindOfClass:NSDictionary.class]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NDMExecuteCommand(command);
                    });
                }
            }
            NDMStartCommandPoll();
        }
    ];
    [task resume];
}

static void NDMStartCommandPoll(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            NDMPollCommands();
        }
    );
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
        dispatch_async(dispatch_get_main_queue(), ^{
            NDMInstallRouteHook();
            NDMScanRouteCandidates();
            NDMStartCommandPoll();
        });
    }
}
