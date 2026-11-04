#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <pthread.h>

#import "XHSRuntimeLogger.h"

void XRBInstallSettingsUI(void);

static NSString *const XRBNoteDetailPath = @"/api/sns/v10/note";

typedef struct XRBMethodHookEntry {
    Class cls;
    SEL selector;
    IMP original;
    struct XRBMethodHookEntry *next;
} XRBMethodHookEntry;

static XRBMethodHookEntry *gBusinessHooks;
static pthread_mutex_t gBusinessHooksLock = PTHREAD_MUTEX_INITIALIZER;

static NSArray<NSString *> *XRBInterestingSelectors(void) {
    return @[
        @"makeFetchNoteDetailAPI:",
        @"fetchNoteDetailWithNoteId:",
        @"fetchDataFromNoteDetailWithParams:",
        @"requestNoteDetail:completion:",
        @"requestNoteDetailForNote:completion:",
        @"requestNoteDetailWithCompletion:",
        @"preloadNoteDetailApi:completetion:",
        @"preloadNoteDetailsWith:userInfo:",
        @"openNoteDetailWithNoteID:",
        @"setContentNoteModel:",
        @"contentNoteModel"
    ];
}

static NSArray<NSString *> *XRBQueryNames(NSURL *URL) {
    NSURLComponents *components = [
        NSURLComponents componentsWithURL:URL
        resolvingAgainstBaseURL:NO
    ];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (item.name.length > 0 && ![names containsObject:item.name]) {
            [names addObject:item.name];
        }
    }
    return names;
}

static NSDictionary *XRBResponseSummary(
    NSData *data,
    NSURLResponse *response,
    NSError *error
) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"success"] = @(!error);
    summary[@"body_size"] = @(data.length);

    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        summary[@"http_code"] =
            @(((NSHTTPURLResponse *)response).statusCode);
    }
    if (error) {
        summary[@"error_domain"] = error.domain ?: @"";
        summary[@"error_code"] = @(error.code);
    }

    if (data.length > 0) {
        id JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([JSON isKindOfClass:NSDictionary.class]) {
            NSArray *keys = [[(NSDictionary *)JSON allKeys]
                sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
                    return [[left description] compare:[right description]];
                }];
            summary[@"json_type"] = @"dictionary";
            summary[@"top_level_keys"] = keys;
        } else if ([JSON isKindOfClass:NSArray.class]) {
            summary[@"json_type"] = @"array";
            summary[@"array_count"] = @([(NSArray *)JSON count]);
        } else {
            summary[@"json_type"] = @"non_json";
        }
    }
    return summary;
}

static NSString *XRBShortDescription(id value) {
    if (!value) return @"<nil>";
    NSString *text = [value description] ?: @"";
    if (text.length > 256) {
        text = [text substringToIndex:256];
    }
    return text;
}

static IMP XRBOriginalImplementation(id self, SEL selector) {
    Class cls = object_getClass(self);
    pthread_mutex_lock(&gBusinessHooksLock);
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        for (XRBMethodHookEntry *entry = gBusinessHooks;
             entry;
             entry = entry->next) {
            if (entry->cls == current && entry->selector == selector) {
                IMP original = entry->original;
                pthread_mutex_unlock(&gBusinessHooksLock);
                return original;
            }
        }
    }
    pthread_mutex_unlock(&gBusinessHooksLock);
    return NULL;
}

static void XRBLogBusinessEnter(
    id self,
    SEL selector,
    NSDictionary *extra
) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:@{
        @"class": NSStringFromClass(object_getClass(self)) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @""
    }];
    if (extra) [fields addEntriesFromDictionary:extra];
    XRBLogEvent(@"business_method_enter", fields);
}

static void XRBHookVoidObject(id self, SEL selector, id argument) {
    XRBLogBusinessEnter(self, selector, @{
        @"argument_class": argument ? NSStringFromClass(object_getClass(argument)) : @"<nil>",
        @"argument_description": XRBShortDescription(argument)
    });
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id))original)(self, selector, argument);
    }
}

static id XRBHookObjectObject(id self, SEL selector, id argument) {
    XRBLogBusinessEnter(self, selector, @{
        @"argument_class": argument ? NSStringFromClass(object_getClass(argument)) : @"<nil>",
        @"argument_description": XRBShortDescription(argument)
    });
    IMP original = XRBOriginalImplementation(self, selector);
    if (!original) return nil;
    id result = ((id (*)(id, SEL, id))original)(self, selector, argument);
    XRBLogEvent(@"business_method_exit", @{
        @"class": NSStringFromClass(object_getClass(self)) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"result_class": result ? NSStringFromClass(object_getClass(result)) : @"<nil>"
    });
    return result;
}

static id XRBHookObjectNoArgument(id self, SEL selector) {
    XRBLogBusinessEnter(self, selector, nil);
    IMP original = XRBOriginalImplementation(self, selector);
    if (!original) return nil;
    id result = ((id (*)(id, SEL))original)(self, selector);
    XRBLogEvent(@"business_method_exit", @{
        @"class": NSStringFromClass(object_getClass(self)) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"result_class": result ? NSStringFromClass(object_getClass(result)) : @"<nil>"
    });
    return result;
}

static void XRBHookObjectCompletion(
    id self,
    SEL selector,
    id argument,
    id completion
) {
    XRBLogBusinessEnter(self, selector, @{
        @"argument_class": argument ? NSStringFromClass(object_getClass(argument)) : @"<nil>",
        @"argument_description": XRBShortDescription(argument),
        @"completion_class": completion
            ? NSStringFromClass(object_getClass(completion))
            : @"<nil>"
    });
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id))original)(
            self,
            selector,
            argument,
            completion
        );
    }
}

static Method XRBDirectMethod(Class cls, SEL selector) {
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

static void XRBRememberBusinessHook(
    Class cls,
    SEL selector,
    IMP original
) {
    XRBMethodHookEntry *entry = calloc(1, sizeof(XRBMethodHookEntry));
    entry->cls = cls;
    entry->selector = selector;
    entry->original = original;
    pthread_mutex_lock(&gBusinessHooksLock);
    entry->next = gBusinessHooks;
    gBusinessHooks = entry;
    pthread_mutex_unlock(&gBusinessHooksLock);
}

static void XRBInstallBusinessHook(
    NSString *className,
    NSString *selectorName
) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !selector) return;

    Method method = XRBDirectMethod(cls, selector);
    if (!method) return;

    const char *encoding = method_getTypeEncoding(method);
    IMP replacement = NULL;
    NSString *kind = nil;
    if (strcmp(encoding, "v24@0:8@16") == 0) {
        replacement = (IMP)XRBHookVoidObject;
        kind = @"void_object";
    } else if (strcmp(encoding, "@24@0:8@16") == 0) {
        replacement = (IMP)XRBHookObjectObject;
        kind = @"object_object";
    } else if (strcmp(encoding, "@16@0:8") == 0) {
        replacement = (IMP)XRBHookObjectNoArgument;
        kind = @"object_no_argument";
    } else if (strcmp(encoding, "v32@0:8@16@?24") == 0) {
        replacement = (IMP)XRBHookObjectCompletion;
        kind = @"void_object_completion";
    } else {
        XRBLogEvent(@"business_hook_unsupported", @{
            @"class": className,
            @"selector": selectorName,
            @"type_encoding": encoding ? [NSString stringWithUTF8String:encoding] : @""
        });
        return;
    }

    pthread_mutex_lock(&gBusinessHooksLock);
    BOOL alreadyInstalled = NO;
    for (XRBMethodHookEntry *entry = gBusinessHooks;
         entry;
         entry = entry->next) {
        if (entry->cls == cls && entry->selector == selector) {
            alreadyInstalled = YES;
            break;
        }
    }
    pthread_mutex_unlock(&gBusinessHooksLock);
    if (alreadyInstalled) return;

    IMP original = method_setImplementation(method, replacement);
    XRBRememberBusinessHook(cls, selector, original);
    XRBLogEvent(@"business_hook_installed", @{
        @"class": className,
        @"selector": selectorName,
        @"type_encoding": encoding ? [NSString stringWithUTF8String:encoding] : @"",
        @"hook_kind": kind
    });
}

static void XRBInstallBusinessHooks(void) {
    NSArray<NSArray<NSString *> *> *targets = @[
        @[@"XYNoteAPI", @"fetchNoteDetailWithNoteId:"],
        @[@"XYAPINoteRouter", @"makeFetchNoteDetailAPI:"],
        @[@"XYPHFeedNoteContentSource", @"requestNoteDetailForNote:completion:"],
        @[@"XYVFVideoContentDataSource", @"requestNoteDetail:completion:"],
        @[@"XYVFVideoContentDataSource", @"requestNoteDetailWithCompletion:"],
        @[@"XYVFVideoContentViewModel", @"setContentNoteModel:"],
        @[@"XYVFVideoContentViewModel", @"contentNoteModel"],
        @[@"XYVTPlayerConfigModel", @"setContentNoteModel:"],
        @[@"XYVTPlayerConfigModel", @"contentNoteModel"]
    ];
    for (NSArray<NSString *> *target in targets) {
        XRBInstallBusinessHook(target[0], target[1]);
    }
}

@interface NSURLSession (XHSRuntimeBridge)

- (NSURLSessionDataTask *)xrb_dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData * _Nullable data,
                                NSURLResponse * _Nullable response,
                                NSError * _Nullable error))completionHandler;

@end

@implementation NSURLSession (XHSRuntimeBridge)

- (NSURLSessionDataTask *)xrb_dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *data,
                                NSURLResponse *response,
                                NSError *error))completionHandler {
    if (XRBIsCollectorRequest(request)) {
        return [self xrb_dataTaskWithRequest:request
                          completionHandler:completionHandler];
    }

    NSURL *URL = request.URL;
    BOOL isNoteDetail = [URL.path containsString:XRBNoteDetailPath];
    if (!isNoteDetail) {
        return [self xrb_dataTaskWithRequest:request
                          completionHandler:completionHandler];
    }

    XRBLogEvent(@"note_detail_request", @{
        @"method": request.HTTPMethod ?: @"",
        @"url_scheme": URL.scheme ?: @"",
        @"url_host": URL.host ?: @"",
        @"url_path": URL.path ?: @"",
        @"query_names": XRBQueryNames(URL),
        @"request_body_length": @(request.HTTPBody.length)
    });

    void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            XRBLogEvent(
                @"note_detail_response",
                XRBResponseSummary(data, response, error)
            );
            if (completionHandler) {
                completionHandler(data, response, error);
            }
        };

    return [self xrb_dataTaskWithRequest:request
                      completionHandler:wrappedCompletion];
}

@end

static void XRBInstallURLSessionObservation(void) {
    Class sessionClass = NSURLSession.class;
    SEL originalSelector =
        @selector(dataTaskWithRequest:completionHandler:);
    SEL replacementSelector =
        @selector(xrb_dataTaskWithRequest:completionHandler:);

    Method original = class_getInstanceMethod(sessionClass, originalSelector);
    Method replacement =
        class_getInstanceMethod(sessionClass, replacementSelector);
    if (!original || !replacement) {
        XRBLogEvent(@"logger_error", @{
            @"stage": @"install_urlsession_hook",
            @"reason": @"method_not_found"
        });
        return;
    }

    method_exchangeImplementations(original, replacement);
    XRBLogEvent(@"hook_installed", @{
        @"class": NSStringFromClass(sessionClass),
        @"selector": NSStringFromSelector(originalSelector)
    });
}

static void XRBScanRuntime(void) {
    NSArray<NSString *> *interesting = XRBInterestingSelectors();
    NSSet<NSString *> *interestingSet = [NSSet setWithArray:interesting];
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;

    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc(
            (size_t)classCount,
            sizeof(Class)
        );
    classCount = objc_getClassList(classes, classCount);

    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0;
             methodIndex < methodCount;
             methodIndex++) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *name = NSStringFromSelector(selector);
            if (![interestingSet containsObject:name]) continue;

            const char *encoding = method_getTypeEncoding(methods[methodIndex]);
            XRBLogEvent(@"selector_discovered", @{
                @"kind": @"instance",
                @"class": NSStringFromClass(cls),
                @"selector": name,
                @"type_encoding": encoding
                    ? [NSString stringWithUTF8String:encoding]
                    : @""
            });
        }
        free(methods);

        Class metaClass = object_getClass(cls);
        methodCount = 0;
        methods = class_copyMethodList(metaClass, &methodCount);
        for (unsigned int methodIndex = 0;
             methodIndex < methodCount;
             methodIndex++) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *name = NSStringFromSelector(selector);
            if (![interestingSet containsObject:name]) continue;

            const char *encoding = method_getTypeEncoding(methods[methodIndex]);
            XRBLogEvent(@"selector_discovered", @{
                @"kind": @"class",
                @"class": NSStringFromClass(cls),
                @"selector": name,
                @"type_encoding": encoding
                    ? [NSString stringWithUTF8String:encoding]
                    : @""
            });
        }
        free(methods);
    }
    free(classes);
}

__attribute__((constructor))
static void XHSRuntimeBridgeInitialize(void) {
    @autoreleasepool {
        XRBStartLogger();
        XRBLogEvent(@"dylib_loaded", @{
            @"image": @"XHSRuntimeBridge.dylib"
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            XRBInstallSettingsUI();
            XRBInstallURLSessionObservation();
            dispatch_async(
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                ^{
                    XRBScanRuntime();
                    XRBInstallBusinessHooks();
                    XRBLogEvent(@"runtime_scan_completed", nil);
                }
            );
        });
    }
}
