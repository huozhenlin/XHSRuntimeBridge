#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "XHSRuntimeLogger.h"

static NSString *const XRBNoteDetailPath = @"/api/sns/v10/note";

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

    Class *classes = calloc((size_t)classCount, sizeof(Class));
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
            XRBInstallURLSessionObservation();
            dispatch_async(
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                ^{
                    XRBScanRuntime();
                    XRBLogEvent(@"runtime_scan_completed", nil);
                }
            );
        });
    }
}
