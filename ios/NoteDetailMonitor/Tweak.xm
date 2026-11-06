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
static NSString *gPendingNoteID;
static IMP gShoppingRouteOriginal;
static IMP gHomeFeedRouteOriginal;
static IMP gCommercialWSROriginal;
static IMP gDebugViewModelOriginal;
static IMP gWidgetModelOriginal;
static IMP gPickDataOriginal;
static IMP gWidgetModelSetterOriginal;
static IMP gPickDataSetterOriginal;
static IMP gDisplayImageOriginal;
static IMP gDisplayImageSetterOriginal;
static IMP gCurrentImageIDOriginal;
static IMP gCurrentImageIDSetterOriginal;
static IMP gWidgetInjectOriginal;
static IMP gWidgetInjectDictOriginal;
static IMP gImageCacheStoreSetterOriginal;
static IMP gImageRestoreOriginal;
static IMP gImageBrowserRecordLoadOriginal;
static IMP gImageBrowserWillDisplayOriginal;
static void NDMInstallDetailViewModelHooks(void);
static void NDMInstallImageBrowserHooks(void);

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

static id NDMReadKnownValue(id object, NSString *key);
static NSArray<NSString *> *NDMCallStack(void);
static NSDictionary *NDMTraceContext(id object);
static id NDMDeepSnapshot(
    id object,
    NSUInteger depth,
    NSMutableSet<NSValue *> *seen,
    NSUInteger *budget
);

static NSString *NDMURLString(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        return [(NSURL *)value absoluteString];
    }
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return nil;
}

static void NDMReportImageBrowserMedia(
    id browser,
    id cell,
    long long index,
    id directURL
) {
    id asset = NDMReadKnownValue(cell, @"asset");
    NSString *noteID = NDMShortString(NDMReadKnownValue(browser, @"noteId"));
    if (noteID.length == 0) {
        noteID = gPendingNoteID;
    }

    NSString *url = NDMURLString(directURL);
    if (url.length == 0) {
        url = NDMURLString(NDMReadKnownValue(cell, @"url"));
    }
    if (url.length == 0) {
        url = NDMURLString(NDMReadKnownValue(cell, @"originalUrl"));
    }
    if (url.length == 0) {
        url = NDMURLString(NDMReadKnownValue(cell, @"weakUrl"));
    }

    NSString *liveVideo = NDMURLString(
        NDMReadKnownValue(asset, @"livePhotoVideoURL")
    );
    NSString *liveImage = NDMURLString(
        NDMReadKnownValue(asset, @"livePhotoImageURL")
    );
    id fileID = NDMReadKnownValue(asset, @"livePhotoVideoFileId");

    if (url.length == 0 && liveVideo.length == 0 && liveImage.length == 0) {
        return;
    }

    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": @"image_media_observed",
        @"source": @"ImageBrowser",
        @"note_id": noteID ?: [NSNull null],
        @"index": @(index),
        @"cell_class": cell
            ? NSStringFromClass(object_getClass(cell)) : @"<nil>",
        @"url": url ?: [NSNull null],
        @"live_photo_video_url": liveVideo ?: [NSNull null],
        @"live_photo_image_url": liveImage ?: [NSNull null],
        @"live_photo_video_file_id": fileID ?: [NSNull null],
        @"call_stack": NDMCallStack()
    }];
    NSUInteger cellBudget = 140;
    event[@"cell_snapshot"] = NDMDeepSnapshot(
        cell, 0, [NSMutableSet set], &cellBudget
    ) ?: [NSNull null];
    event[@"cell_remaining_budget"] = @(cellBudget);
    NSUInteger assetBudget = 80;
    event[@"asset_snapshot"] = NDMDeepSnapshot(
        asset, 0, [NSMutableSet set], &assetBudget
    ) ?: [NSNull null];
    event[@"asset_remaining_budget"] = @(assetBudget);
    NSUInteger browserBudget = 60;
    event[@"browser_snapshot"] = NDMDeepSnapshot(
        browser, 0, [NSMutableSet set], &browserBudget
    ) ?: [NSNull null];
    event[@"browser_remaining_budget"] = @(browserBudget);
    [event addEntriesFromDictionary:NDMTraceContext(browser)];
    NDMPostEvent(event);
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
        @"source", @"sourceType", @"source_type", @"sourceId",
        @"sourceIDForRouter", @"scene", @"entry",
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
    SEL objectForKey = @selector(objectForKey:);
    if ([object respondsToSelector:objectForKey]) {
        @try {
            id (*lookup)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id value = lookup(object, objectForKey, key);
            if (value) return value;
        } @catch (__unused NSException *exception) {
        }
    }

    Class cls = object_getClass(object);
    if (NDMHasDirectGetter(cls, key)) {
        @try {
            return [object valueForKey:key];
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
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
                   [normalized containsString:@"sourceid"] ||
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

static void NDMEmitControllerMetadata(UIViewController *controller) {
    static NSMutableSet<NSString *> *sent;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sent = [NSMutableSet set];
    });

    NSString *className = NDMControllerName(controller);
    @synchronized (sent) {
        if ([sent containsObject:className]) return;
        [sent addObject:className];
    }

    NSMutableArray<NSString *> *properties = [NSMutableArray array];
    NSMutableArray<NSString *> *methods = [NSMutableArray array];
    for (Class cls = object_getClass(controller);
         cls && cls != NSObject.class;
         cls = class_getSuperclass(cls)) {
        unsigned int propertyCount = 0;
        objc_property_t *propertyList =
            class_copyPropertyList(cls, &propertyCount);
        for (unsigned int index = 0; index < propertyCount; index++) {
            const char *name = property_getName(propertyList[index]);
            NSString *text = name ? [NSString stringWithUTF8String:name] : @"";
            NSString *lower = text.lowercaseString;
            if ([lower containsString:@"note"] ||
                [lower containsString:@"detail"] ||
                [lower containsString:@"model"] ||
                [lower containsString:@"data"] ||
                [lower containsString:@"feed"] ||
                [lower containsString:@"source"]) {
                if (![properties containsObject:text]) {
                    [properties addObject:text];
                }
            }
        }
        free(propertyList);

        unsigned int methodCount = 0;
        Method *methodList = class_copyMethodList(cls, &methodCount);
        for (unsigned int index = 0; index < methodCount; index++) {
            NSString *text = NSStringFromSelector(
                method_getName(methodList[index])
            );
            NSString *lower = text.lowercaseString;
            if ([lower containsString:@"note"] ||
                [lower containsString:@"detail"] ||
                [lower containsString:@"model"] ||
                [lower containsString:@"data"] ||
                [lower containsString:@"feed"] ||
                [lower containsString:@"source"]) {
                if (![methods containsObject:text]) {
                    [methods addObject:text];
                }
            }
        }
        free(methodList);
    }

    NDMPostEvent(@{
        @"event": @"detail_controller_metadata",
        @"controller": className ?: @"",
        @"properties": properties,
        @"methods": methods
    });
}

static NSArray<NSString *> *NDMCallStack(void) {
    NSArray<NSString *> *symbols = NSThread.callStackSymbols;
    NSUInteger count = MIN((NSUInteger)20, symbols.count);
    return count > 0 ? [symbols subarrayWithRange:NSMakeRange(0, count)] : @[];
}

static NSDictionary *NDMTraceContext(id object) {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    if (gPendingRequestID.length > 0) {
        context[@"request_id"] = gPendingRequestID;
    }
    NSString *noteID = gPendingNoteID;
    if (noteID.length == 0 && object) {
        id value = NDMReadKnownValue(object, @"noteId");
        if ([value isKindOfClass:NSString.class]) {
            noteID = value;
        }
    }
    if (noteID.length > 0) {
        context[@"note_id_context"] = noteID;
    }
    return context;
}

static NSArray<NSString *> *NDMDictionaryKeys(id value) {
    if (!value) return @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSArray *rawKeys = nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        rawKeys = [(NSDictionary *)value allKeys];
    } else if ([value respondsToSelector:@selector(allKeys)]) {
        @try {
            rawKeys = [value allKeys];
        } @catch (__unused NSException *exception) {
            rawKeys = nil;
        }
    }
    for (id key in rawKeys ?: @[]) {
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

static BOOL NDMLooksLikeAuthController(UIViewController *controller) {
    NSString *name = NDMControllerName(controller).lowercaseString;
    return [name containsString:@"login"] ||
        [name containsString:@"signin"] ||
        [name containsString:@"verify"] ||
        [name containsString:@"captcha"] ||
        [name containsString:@"account"];
}

static id NDMDeepSnapshot(
    id object,
    NSUInteger depth,
    NSMutableSet<NSValue *> *seen,
    NSUInteger *budget
);

static void NDMCollectDetailChildren(
    UIViewController *controller,
    NSUInteger depth,
    NSMutableArray<NSDictionary *> *rows,
    NSUInteger *budget
) {
    if (!controller || depth > 4 || *budget == 0) return;
    (*budget)--;

    NSString *className = NDMControllerName(controller);
    NSDictionary *fields = NDMExtractBusinessFields(controller);
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{
        @"class": className ?: @"",
        @"depth": @(depth),
        @"child_count": @(
            controller.childViewControllers.count
        ),
        @"note_id": fields[@"note_id"] ?: [NSNull null],
        @"user_id": fields[@"user_id"] ?: [NSNull null]
    }];
    NSMutableArray<NSDictionary *> *candidateMethods = [NSMutableArray array];
    for (Class cls = object_getClass(controller);
         cls && cls != NSObject.class && candidateMethods.count < 80;
         cls = class_getSuperclass(cls)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int index = 0;
             index < methodCount && candidateMethods.count < 80;
             index++) {
            SEL selector = method_getName(methods[index]);
            NSString *name = NSStringFromSelector(selector) ?: @"";
            NSString *lower = name.lowercaseString;
            BOOL interesting =
                [lower containsString:@"note"] ||
                [lower containsString:@"detail"] ||
                [lower containsString:@"model"] ||
                [lower containsString:@"data"] ||
                [lower containsString:@"content"] ||
                [lower containsString:@"request"] ||
                [lower containsString:@"fetch"] ||
                [lower containsString:@"load"] ||
                [lower containsString:@"source"] ||
                [lower containsString:@"image"] ||
                [lower containsString:@"video"] ||
                [lower containsString:@"widget"] ||
                [lower containsString:@"pick"];
            if (!interesting) continue;
            const char *encoding = method_getTypeEncoding(methods[index]);
            [candidateMethods addObject:@{
                @"selector": name,
                @"type_encoding": encoding
                    ? [NSString stringWithUTF8String:encoding] : @""
            }];
        }
        free(methods);
    }
    row[@"candidate_methods"] = candidateMethods;

    for (NSString *key in @[
        @"pu_debugCurrentViewModel", @"wgt_getWidgetModel",
        @"xyps_pickData", @"contentNoteModel", @"noteModel",
        @"noteDetailModel", @"data", @"model"
    ]) {
        id value = NDMReadKnownValue(controller, key);
        if (!value) continue;
        row[@"model_property"] = key;
        row[@"model_class"] = NSStringFromClass(object_getClass(value))
            ?: @"";
        row[@"model_fields"] = NDMExtractBusinessFields(value);
        NSUInteger snapshotBudget = 160;
        row[@"model_snapshot"] = NDMDeepSnapshot(
            value, 0, [NSMutableSet set], &snapshotBudget
        ) ?: [NSNull null];
        break;
    }
    [rows addObject:row];

    for (UIViewController *child in controller.childViewControllers) {
        NDMCollectDetailChildren(child, depth + 1, rows, budget);
        if (*budget == 0) break;
    }
}

static void NDMReportDetailHierarchy(UIViewController *controller) {
    if (!controller) return;
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSUInteger budget = 80;
    NDMCollectDetailChildren(controller, 0, rows, &budget);
    NDMPostEvent(@{
        @"event": @"detail_child_hierarchy",
        @"controller": NDMControllerName(controller),
        @"rows": rows,
        @"remaining_budget": @(budget)
    });
}

static void NDMReportController(
    UIViewController *controller,
    NSString *navigationKind,
    NSDictionary *routeFields
) {
    if (!NDMLooksLikeDetailController(controller)) return;
    NDMEmitControllerMetadata(controller);

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
        @"note", @"noteModel", @"contentNoteModel", @"noteFeed", @"feed",
        @"pu_debugCurrentViewModel", @"wgt_getWidgetModel", @"xyps_pickData"
    ]) {
        id model = NDMReadKnownValue(controller, modelKey);
        if (!model) continue;
        NDMPostEvent(@{
            @"event": @"detail_viewmodel_observed",
            @"property": modelKey,
            @"model_class": NSStringFromClass(object_getClass(model)) ?: @"",
            @"fields": NDMExtractBusinessFields(model)
        });
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
        @"presentNoteDetailWithConfig:saveActionHandler:saveActionTrackHandler:shareToFriendResult:delegate:",
        @"fetchNoteDetailWithNoteId:",
        @"makeFetchNoteDetailAPI:",
        @"requestWithWsrurl:keyPath:customContent:completion:"
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

static void NDMShoppingRouteHook(
    id self,
    SEL selector,
    id context,
    id title,
    id note,
    id extra
) {
    NSMutableDictionary *fields =
        [NSMutableDictionary dictionaryWithDictionary:
            NDMExtractBusinessFields(note)];
    fields[@"class"] = NSStringFromClass((Class)self) ?: @"";
    fields[@"selector"] = NSStringFromSelector(selector) ?: @"";
    fields[@"title_class"] = title
        ? NSStringFromClass(object_getClass(title))
        : @"<nil>";
    fields[@"extra_class"] = extra
        ? NSStringFromClass(object_getClass(extra))
        : @"<nil>";
    fields[@"call_stack"] = NDMCallStack();
    fields[@"event"] = @"route_invoked";
    NDMPostEvent(fields);
    if (gShoppingRouteOriginal) {
        ((void (*)(id, SEL, id, id, id, id))gShoppingRouteOriginal)(
            self, selector, context, title, note, extra
        );
    }
}

static id NDMDeepSnapshot(
    id object,
    NSUInteger depth,
    NSMutableSet<NSValue *> *seen,
    NSUInteger *budget
) {
    if (!object || *budget == 0) return [NSNull null];
    if (depth > 3) return @"<max-depth>";
    (*budget)--;
    if ([object isKindOfClass:NSNull.class] ||
        [object isKindOfClass:NSNumber.class]) return object;
    if ([object isKindOfClass:NSString.class]) {
        NSString *text = object;
        return text.length > 2048 ? [text substringToIndex:2048] : text;
    }
    if ([object isKindOfClass:NSURL.class]) return [object absoluteString];
    NSString *className = NSStringFromClass(object_getClass(object)) ?: @"";
    for (NSString *prefix in @[
        @"NS", @"UI", @"CF", @"CG", @"CA", @"AV", @"PH", @"NSURL"
    ]) {
        if ([className hasPrefix:prefix]) {
            return @{@"__class": className};
        }
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *values = [NSMutableArray array];
        NSUInteger count = MIN((NSUInteger)[(NSArray *)object count],
                               (NSUInteger)32);
        for (NSUInteger index = 0; index < count && *budget > 0; index++) {
            [values addObject:NDMDeepSnapshot(
                [(NSArray *)object objectAtIndex:index],
                depth + 1,
                seen,
                budget
            ) ?: [NSNull null]];
        }
        return values;
    }
    BOOL dictionaryLike = [object isKindOfClass:NSDictionary.class] ||
        ([object respondsToSelector:@selector(allKeys)] &&
         [object respondsToSelector:@selector(objectForKey:)]);
    if (dictionaryLike) {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        NSUInteger count = 0;
        NSArray *keys = nil;
        @try {
            keys = [object allKeys];
        } @catch (__unused NSException *exception) {
            keys = nil;
        }
        for (id key in keys ?: @[]) {
            if (count++ >= 64 || *budget == 0) break;
            NSString *name = [key description] ?: @"";
            id child = nil;
            @try {
                child = [object objectForKey:key];
            } @catch (__unused NSException *exception) {
            }
            values[name] = NDMDeepSnapshot(
                child, depth + 1, seen, budget
            ) ?: [NSNull null];
        }
        return values;
    }

    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([seen containsObject:identity]) return @"<cycle>";
    [seen addObject:identity];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    values[@"__class"] = NSStringFromClass(object_getClass(object)) ?: @"";
    Class cls = object_getClass(object);
    for (; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        for (unsigned int index = 0; index < count && *budget > 0; index++) {
            const char *rawName = property_getName(properties[index]);
            if (!rawName) continue;
            NSString *name = [NSString stringWithUTF8String:rawName];
            NSString *lower = name.lowercaseString;
            BOOL safe = [lower containsString:@"note"] ||
                [lower containsString:@"user"] ||
                [lower containsString:@"author"] ||
                [lower containsString:@"title"] ||
                [lower containsString:@"desc"] ||
                [lower containsString:@"url"] ||
                [lower containsString:@"image"] ||
                [lower containsString:@"video"] ||
                [lower containsString:@"media"] ||
                [lower containsString:@"model"] ||
                [lower containsString:@"data"] ||
                [lower containsString:@"info"] ||
                [lower containsString:@"count"] ||
                [lower isEqualToString:@"id"] ||
                [lower containsString:@"source"];
            if (!safe) continue;
            @try {
                id value = [object valueForKey:name];
                if (value) values[name] = NDMDeepSnapshot(
                    value, depth + 1, seen, budget
                );
            } @catch (__unused NSException *exception) {
            }
        }
        free(properties);
    }
    return values;
}

static void NDMHomeFeedRouteHook(
    id self,
    SEL selector,
    id item,
    id indexPath,
    id channel,
    long anchorIndex,
    BOOL dynamicCover
) {
    NSMutableDictionary *fields =
        [NSMutableDictionary dictionaryWithDictionary:
            NDMExtractBusinessFields(item)];
    fields[@"class"] = NSStringFromClass((Class)self) ?: @"";
    fields[@"selector"] = NSStringFromSelector(selector) ?: @"";
    fields[@"anchor_index"] = @(anchorIndex);
    fields[@"dynamic_cover"] = @(dynamicCover);
    fields[@"index_path_class"] = indexPath
        ? NSStringFromClass(object_getClass(indexPath))
        : @"<nil>";
    fields[@"channel_class"] = channel
        ? NSStringFromClass(object_getClass(channel))
        : @"<nil>";
    fields[@"call_stack"] = NDMCallStack();
    fields[@"event"] = @"route_invoked";
    NDMPostEvent(fields);
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSUInteger budget = 300;
    NDMPostEvent(@{
        @"event": @"route_item_dump",
        @"note_id": fields[@"note_id"] ?: [NSNull null],
        @"item_class": item
            ? NSStringFromClass(object_getClass(item))
            : @"<nil>",
        @"snapshot": NDMDeepSnapshot(item, 0, seen, &budget),
        @"remaining_budget": @(budget)
    });
    if (gHomeFeedRouteOriginal) {
        ((void (*)(id, SEL, id, id, id, long, BOOL))gHomeFeedRouteOriginal)(
            self, selector, item, indexPath, channel, anchorIndex, dynamicCover
        );
    }
}

static void NDMCommercialWSRHook(
    id self,
    SEL selector,
    id wsrURL,
    id keyPath,
    id customContent,
    id completion
) {
    NSString *keyPathDescription = NDMShortString(keyPath) ?: @"";
    NDMPostEvent(@{
        @"event": @"wsr_request_enter",
        @"class": NSStringFromClass((Class)self) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"wsr_url_class": wsrURL
            ? NSStringFromClass(object_getClass(wsrURL))
            : @"<nil>",
        @"key_path_class": keyPath
            ? NSStringFromClass(object_getClass(keyPath))
            : @"<nil>",
        @"key_path_length": @(keyPathDescription.length),
        @"custom_content_class": customContent
            ? NSStringFromClass(object_getClass(customContent))
            : @"<nil>",
        @"completion_class": completion
            ? NSStringFromClass(object_getClass(completion))
            : @"<nil>"
    });
    if (gCommercialWSROriginal) {
        ((void (*)(id, SEL, id, id, id, id))gCommercialWSROriginal)(
            self, selector, wsrURL, keyPath, customContent, completion
        );
    }
}

static void NDMHookObservedRoutes(void) {
    Class shopping = NSClassFromString(@"XYShopping.SRouter");
    SEL shoppingSelector =
        NSSelectorFromString(@"routeToNoteDetailsWith:title:note:extraSkuInfos:");
    Method shoppingMethod = shopping
        ? class_getClassMethod(shopping, shoppingSelector)
        : NULL;
    if (shoppingMethod &&
        strcmp(method_getTypeEncoding(shoppingMethod),
               "v48@0:8@16@24@32@40") == 0 &&
        !gShoppingRouteOriginal) {
        gShoppingRouteOriginal = method_setImplementation(
            shoppingMethod,
            (IMP)NDMShoppingRouteHook
        );
        NDMPostEvent(@{
            @"event": @"route_hook_installed",
            @"class": @"XYShopping.SRouter",
            @"selector": NSStringFromSelector(shoppingSelector),
            @"type_encoding": @"v48@0:8@16@24@32@40"
        });
    }

    Class home = NSClassFromString(@"XYEXHomeFeedRouter");
    SEL homeSelector = NSSelectorFromString(
        @"routeToNoteDetailWithItem:atIndexPath:channel:anchorIndex:isDynamicCover:"
    );
    Method homeMethod = home ? class_getClassMethod(home, homeSelector) : NULL;
    if (homeMethod &&
        strcmp(method_getTypeEncoding(homeMethod),
               "v52@0:8@16@24@32q40B48") == 0 &&
        !gHomeFeedRouteOriginal) {
        gHomeFeedRouteOriginal = method_setImplementation(
            homeMethod,
            (IMP)NDMHomeFeedRouteHook
        );
        NDMPostEvent(@{
            @"event": @"route_hook_installed",
            @"class": @"XYEXHomeFeedRouter",
            @"selector": NSStringFromSelector(homeSelector),
            @"type_encoding": @"v52@0:8@16@24@32q40B48"
        });
    }

    Class commercial = NSClassFromString(
        @"XYCommercialAPISet.CommercialNetwork"
    );
    SEL wsrSelector = NSSelectorFromString(
        @"requestWithWsrurl:keyPath:customContent:completion:"
    );
    Method wsrMethod = commercial
        ? class_getClassMethod(commercial, wsrSelector)
        : NULL;
    if (wsrMethod &&
        strcmp(method_getTypeEncoding(wsrMethod),
               "v48@0:8@16@24@32@?40") == 0 &&
        !gCommercialWSROriginal) {
        gCommercialWSROriginal = method_setImplementation(
            wsrMethod,
            (IMP)NDMCommercialWSRHook
        );
        NDMPostEvent(@{
            @"event": @"wsr_hook_installed",
            @"class": @"XYCommercialAPISet.CommercialNetwork",
            @"selector": NSStringFromSelector(wsrSelector),
            @"type_encoding": @"v48@0:8@16@24@32@?40"
        });
    }
}

static id NDMObserveDetailGetter(
    id self,
    SEL selector,
    IMP original
) {
    if (!original) return nil;
    id result = ((id (*)(id, SEL))original)(self, selector);
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": @"detail_viewmodel_observed",
        @"property": NSStringFromSelector(selector) ?: @"",
        @"model_class": result
            ? NSStringFromClass(object_getClass(result))
            : @"<nil>",
        @"fields": NDMExtractBusinessFields(result),
        @"call_stack": NDMCallStack()
    }];
    [event addEntriesFromDictionary:NDMTraceContext(self)];
    NDMPostEvent(event);
    return result;
}

static id NDMDebugViewModelGetter(id self, SEL selector) {
    return NDMObserveDetailGetter(self, selector, gDebugViewModelOriginal);
}

static id NDMWidgetModelGetter(id self, SEL selector) {
    return NDMObserveDetailGetter(self, selector, gWidgetModelOriginal);
}

static id NDMPickDataGetter(id self, SEL selector) {
    return NDMObserveDetailGetter(self, selector, gPickDataOriginal);
}

static void NDMObserveDetailSetter(
    id self,
    SEL selector,
    id value,
    IMP original
) {
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": @"detail_viewmodel_observed",
        @"property": NSStringFromSelector(selector) ?: @"",
        @"model_class": value
            ? NSStringFromClass(object_getClass(value))
            : @"<nil>",
        @"fields": NDMExtractBusinessFields(value),
        @"call_stack": NDMCallStack()
    }];
    [event addEntriesFromDictionary:NDMTraceContext(self)];
    if (value) {
        NSUInteger budget = 300;
        event[@"snapshot"] = NDMDeepSnapshot(
            value, 0, [NSMutableSet set], &budget
        ) ?: [NSNull null];
        event[@"remaining_budget"] = @(budget);
    }
    NDMPostEvent(event);
    if (original) {
        ((void (*)(id, SEL, id))original)(self, selector, value);
    }
}

static void NDMWidgetModelSetter(id self, SEL selector, id value) {
    NDMObserveDetailSetter(self, selector, value, gWidgetModelSetterOriginal);
}

static void NDMPickDataSetter(id self, SEL selector, id value) {
    NDMObserveDetailSetter(self, selector, value, gPickDataSetterOriginal);
}

static id NDMDisplayImageGetter(id self, SEL selector) {
    return NDMObserveDetailGetter(self, selector, gDisplayImageOriginal);
}

static void NDMDisplayImageSetter(id self, SEL selector, id value) {
    NDMObserveDetailSetter(self, selector, value, gDisplayImageSetterOriginal);
}

static id NDMCurrentImageIDGetter(id self, SEL selector) {
    return NDMObserveDetailGetter(self, selector, gCurrentImageIDOriginal);
}

static void NDMCurrentImageIDSetter(id self, SEL selector, id value) {
    NDMObserveDetailSetter(
        self, selector, value, gCurrentImageIDSetterOriginal
    );
    id displayImage = NDMReadKnownValue(self, @"displayImage");
    if (displayImage) {
        NSUInteger budget = 160;
        NSMutableDictionary *event = [NSMutableDictionary
            dictionaryWithDictionary:@{
                @"event": @"image_display_resolved",
                @"property": @"setCurrentImageID:",
                @"image_id": value ?: [NSNull null],
                @"display_class": NSStringFromClass(
                    object_getClass(displayImage)
                ) ?: @"",
                @"display_fields": NDMExtractBusinessFields(displayImage),
                @"display_snapshot": NDMDeepSnapshot(
                    displayImage, 0, [NSMutableSet set], &budget
                ) ?: [NSNull null],
                @"remaining_budget": @(budget),
                @"call_stack": NDMCallStack()
            }];
        [event addEntriesFromDictionary:NDMTraceContext(self)];
        NDMPostEvent(event);
    }
}

static void NDMWidgetInject(id self, SEL selector, id value) {
    NDMObserveDetailSetter(self, selector, value, gWidgetInjectOriginal);
}

static void NDMWidgetInjectDict(id self, SEL selector, id value) {
    NDMObserveDetailSetter(
        self, selector, value, gWidgetInjectDictOriginal
    );
}

static void NDMImageCacheStoreSetter(id self, SEL selector, id value) {
    NDMObserveDetailSetter(
        self, selector, value, gImageCacheStoreSetterOriginal
    );
}

static void NDMImageRestore(id self, SEL selector) {
    NDMPostEvent(@{
        @"event": @"detail_viewmodel_observed",
        @"property": NSStringFromSelector(selector) ?: @"",
        @"model_class": @"<void>"
    });
    if (gImageRestoreOriginal) {
        ((void (*)(id, SEL))gImageRestoreOriginal)(self, selector);
    }
    id displayImage = NDMReadKnownValue(self, @"displayImage");
    if (displayImage) {
        NSUInteger budget = 400;
        NSMutableDictionary *event = [NSMutableDictionary
            dictionaryWithDictionary:@{
                @"event": @"image_display_resolved",
                @"property": NSStringFromSelector(selector) ?: @"",
                @"display_class": NSStringFromClass(
                    object_getClass(displayImage)
                ) ?: @"",
                @"display_fields": NDMExtractBusinessFields(displayImage),
                @"display_snapshot": NDMDeepSnapshot(
                    displayImage, 0, [NSMutableSet set], &budget
                ) ?: [NSNull null],
                @"remaining_budget": @(budget),
                @"call_stack": NDMCallStack()
            }];
        [event addEntriesFromDictionary:NDMTraceContext(self)];
        NDMPostEvent(event);
    }
}

static void NDMInstallDetailViewModelHooks(void) {
    Class cls = NSClassFromString(@"XYNoteModule.NoteDetailPageInterface");
    if (!cls) return;

    NSArray<NSArray<NSString *> *> *targets = @[
        @[@"pu_debugCurrentViewModel", @"debug"],
        @[@"wgt_getWidgetModel", @"widget"],
        @[@"xyps_pickData", @"pick"],
        @[@"wgt_setWidgetModel:", @"widget_set"],
        @[@"setXyps_pickData:", @"pick_set"],
        @[@"displayImage", @"display_image"],
        @[@"setDisplayImage:", @"display_image_set"],
        @[@"currentImageID", @"current_image_id"],
        @[@"setCurrentImageID:", @"current_image_id_set"],
        @[@"wgt_injectWidget:", @"widget_inject"],
        @[@"wgt_injectWidgetWithDict:", @"widget_inject_dict"],
        @[@"setXYImageCacheStore:", @"image_cache_store_set"],
        @[@"xy_imageRestore", @"image_restore"]
    ];
    for (NSArray<NSString *> *target in targets) {
        SEL selector = NSSelectorFromString(target[0]);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) {
            NDMPostEvent(@{
                @"event": @"detail_viewmodel_hook_candidate",
                @"property": target[0],
                @"status": @"method_not_found"
            });
            continue;
        }
        const char *encoding = method_getTypeEncoding(method);
        BOOL objectSetter =
            [target[1] hasSuffix:@"_set"] ||
            [target[1] isEqualToString:@"widget_inject"] ||
            [target[1] isEqualToString:@"widget_inject_dict"];
        if (objectSetter) {
            if (strcmp(encoding, "v24@0:8@16") != 0) {
                NDMPostEvent(@{
                    @"event": @"detail_viewmodel_hook_candidate",
                    @"property": target[0],
                    @"status": @"unsupported",
                    @"type_encoding": encoding
                        ? [NSString stringWithUTF8String:encoding]
                        : @""
                });
                continue;
            }
        } else if ([target[1] isEqualToString:@"image_restore"]) {
            if (strcmp(encoding, "v16@0:8") != 0) {
                NDMPostEvent(@{
                    @"event": @"detail_viewmodel_hook_candidate",
                    @"property": target[0],
                    @"status": @"unsupported",
                    @"type_encoding": encoding
                        ? [NSString stringWithUTF8String:encoding]
                        : @""
                });
                continue;
            }
        } else if (strcmp(encoding, "@16@0:8") != 0) {
            NDMPostEvent(@{
                @"event": @"detail_viewmodel_hook_candidate",
                @"property": target[0],
                @"status": @"unsupported",
                @"type_encoding": encoding
                    ? [NSString stringWithUTF8String:encoding]
                    : @""
            });
            continue;
        }
        if ([target[1] isEqualToString:@"debug"] && !gDebugViewModelOriginal) {
            gDebugViewModelOriginal = method_setImplementation(
                method, (IMP)NDMDebugViewModelGetter
            );
        } else if ([target[1] isEqualToString:@"widget"] && !gWidgetModelOriginal) {
            gWidgetModelOriginal = method_setImplementation(
                method, (IMP)NDMWidgetModelGetter
            );
        } else if ([target[1] isEqualToString:@"pick"] && !gPickDataOriginal) {
            gPickDataOriginal = method_setImplementation(
                method, (IMP)NDMPickDataGetter
            );
        } else if ([target[1] isEqualToString:@"widget_set"] &&
                   !gWidgetModelSetterOriginal) {
            gWidgetModelSetterOriginal = method_setImplementation(
                method, (IMP)NDMWidgetModelSetter
            );
        } else if ([target[1] isEqualToString:@"pick_set"] &&
                   !gPickDataSetterOriginal) {
            gPickDataSetterOriginal = method_setImplementation(
                method, (IMP)NDMPickDataSetter
            );
        } else if ([target[1] isEqualToString:@"display_image"] &&
                   !gDisplayImageOriginal) {
            gDisplayImageOriginal = method_setImplementation(
                method, (IMP)NDMDisplayImageGetter
            );
        } else if ([target[1] isEqualToString:@"display_image_set"] &&
                   !gDisplayImageSetterOriginal) {
            gDisplayImageSetterOriginal = method_setImplementation(
                method, (IMP)NDMDisplayImageSetter
            );
        } else if ([target[1] isEqualToString:@"current_image_id"] &&
                   !gCurrentImageIDOriginal) {
            gCurrentImageIDOriginal = method_setImplementation(
                method, (IMP)NDMCurrentImageIDGetter
            );
        } else if ([target[1] isEqualToString:@"current_image_id_set"] &&
                   !gCurrentImageIDSetterOriginal) {
            gCurrentImageIDSetterOriginal = method_setImplementation(
                method, (IMP)NDMCurrentImageIDSetter
            );
        } else if ([target[1] isEqualToString:@"widget_inject"] &&
                   !gWidgetInjectOriginal) {
            gWidgetInjectOriginal = method_setImplementation(
                method, (IMP)NDMWidgetInject
            );
        } else if ([target[1] isEqualToString:@"widget_inject_dict"] &&
                   !gWidgetInjectDictOriginal) {
            gWidgetInjectDictOriginal = method_setImplementation(
                method, (IMP)NDMWidgetInjectDict
            );
        } else if ([target[1] isEqualToString:@"image_cache_store_set"] &&
                   !gImageCacheStoreSetterOriginal) {
            gImageCacheStoreSetterOriginal = method_setImplementation(
                method, (IMP)NDMImageCacheStoreSetter
            );
        } else if ([target[1] isEqualToString:@"image_restore"] &&
                   !gImageRestoreOriginal) {
            gImageRestoreOriginal = method_setImplementation(
                method, (IMP)NDMImageRestore
            );
        }
        NDMPostEvent(@{
            @"event": @"detail_viewmodel_hook_installed",
            @"property": target[0],
            @"type_encoding": encoding
                ? [NSString stringWithUTF8String:encoding]
                : @""
        });
    }
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
static BOOL NDMRouteNoteModel(id model, NSString *requestID);

static id NDMFindModelInResponse(
    id response,
    NSUInteger depth,
    NSMutableSet<NSValue *> *seen,
    NSString **pathOut
) {
    if (!response || depth > 6) return nil;

    NSDictionary *direct = NDMExtractBusinessFields(response);
    id directID = direct[@"note_id"];
    if (directID && directID != [NSNull null]) {
        if (pathOut) *pathOut = @"$";
        return response;
    }

    if (![response isKindOfClass:NSString.class] &&
        ![response isKindOfClass:NSNumber.class] &&
        ![response isKindOfClass:NSNull.class]) {
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)response];
        if ([seen containsObject:identity]) return nil;
        [seen addObject:identity];
    }

    if ([response isKindOfClass:NSArray.class]) {
        NSUInteger index = 0;
        for (id child in (NSArray *)response) {
            NSString *childPath = nil;
            id found = NDMFindModelInResponse(
                child, depth + 1, seen, &childPath
            );
            if (found) {
                if (pathOut) {
                    *pathOut = [NSString stringWithFormat:@"$[%lu]%@",
                        (unsigned long)index,
                        childPath.length > 1 ? [@"" stringByAppendingString:
                            [childPath substringFromIndex:1]] : @""];
                }
                return found;
            }
            index++;
        }
        return nil;
    }

    NSArray<NSString *> *preferredKeys = @[
        @"data", @"note", @"noteData", @"note_info", @"noteInfo",
        @"model", @"object", @"result", @"payload", @"response", @"value"
    ];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    [keys addObjectsFromArray:preferredKeys];
    for (NSString *key in NDMDictionaryKeys(response)) {
        if (![keys containsObject:key]) [keys addObject:key];
    }

    for (NSString *key in keys) {
        id nested = NDMReadKnownValue(response, key);
        if (!nested) continue;
        NSString *childPath = nil;
        id found = NDMFindModelInResponse(
            nested, depth + 1, seen, &childPath
        );
        if (found) {
            if (pathOut) {
                *pathOut = [NSString stringWithFormat:@"$.%@%@",
                    key,
                    childPath.length > 1 ? [@"" stringByAppendingString:
                        [childPath substringFromIndex:1]] : @""];
            }
            return found;
        }
    }
    return nil;
}

static BOOL NDMStartActiveNoteFetch(
    NSString *noteID,
    NSString *requestID,
    BOOL openUI
) {
    Class api = NSClassFromString(@"XYNoteAPI");
    SEL fetchSelector = @selector(fetchNoteDetailWithNoteId:);
    if (!api || ![api respondsToSelector:fetchSelector]) {
        NDMPostEvent(@{
            @"event": @"open_note_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID ?: @"",
            @"reason": @"XYNoteAPI unavailable"
        });
        return NO;
    }

    id wsrURL = ((id (*)(id, SEL, id))objc_msgSend)(
        api, fetchSelector, noteID
    );
    if (!wsrURL) {
        NDMPostEvent(@{
            @"event": @"open_note_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID ?: @"",
            @"reason": @"WSRURL creation failed"
        });
        return NO;
    }

    Class network = NSClassFromString(
        @"XYCommercialAPISet.CommercialNetwork"
    );
    SEL requestSelector = NSSelectorFromString(
        @"requestWithWsrurl:keyPath:customContent:completion:"
    );
    if (!network || ![network respondsToSelector:requestSelector]) {
        NDMPostEvent(@{
            @"event": @"open_note_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID ?: @"",
            @"reason": @"WorldSnake executor unavailable"
        });
        return NO;
    }

    gPendingRequestID = requestID;
    void (^completion)(id) = ^(id response) {
        NSString *modelPath = nil;
        id model = NDMFindModelInResponse(
            response, 0, [NSMutableSet set], &modelPath
        );
        NSMutableDictionary *event = [NSMutableDictionary
            dictionaryWithDictionary:NDMExtractBusinessFields(model)];
        event[@"event"] = @"note_detail_network_result";
        event[@"request_id"] = requestID ?: @"";
        event[@"note_id_requested"] = noteID ?: @"";
        event[@"response_class"] = response
            ? NSStringFromClass(object_getClass(response))
            : @"<nil>";
        event[@"response_keys"] = NDMDictionaryKeys(response);
        NSUInteger responseBudget = 600;
        event[@"response_snapshot"] = NDMDeepSnapshot(
            response, 0, [NSMutableSet set], &responseBudget
        ) ?: [NSNull null];
        event[@"model_class"] = model
            ? NSStringFromClass(object_getClass(model))
            : @"<nil>";
        event[@"model_path"] = modelPath ?: [NSNull null];
        NDMPostEvent(event);

        if (!openUI) {
            NDMPostEvent(@{
                @"event": @"note_detail_fetch_completed",
                @"request_id": requestID ?: @"",
                @"note_id_requested": noteID ?: @"",
                @"model_found": @(model != nil),
                @"model_path": modelPath ?: [NSNull null]
            });
            return;
        }

        if (model && NDMRouteNoteModel(model, requestID)) {
            return;
        }
        NDMPostEvent(@{
            @"event": @"open_note_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID ?: @"",
            @"reason": @"detail model not found in WSR response"
        });
    };

    @try {
        ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(
            network,
            requestSelector,
            wsrURL,
            nil,
            nil,
            completion
        );
    } @catch (NSException *exception) {
        NDMPostEvent(@{
            @"event": @"open_note_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID ?: @"",
            @"reason": @"WorldSnake executor exception",
            @"exception": exception.name ?: @""
        });
        return NO;
    }

    NDMPostEvent(@{
        @"event": @"note_detail_request_started",
        @"request_id": requestID ?: @"",
        @"note_id": noteID,
        @"wsr_url_class": NSStringFromClass(object_getClass(wsrURL))
            ?: @""
    });
    return YES;
}

static BOOL NDMOpenNoteDeepLink(
    NSString *noteID,
    NSString *requestID,
    NSString *type
) {
    if (noteID.length == 0) return NO;

    // The app's documented internal route is xhsdiscover://item/<id>.
    // Keep the command narrow: only a note id and the normal/video type are
    // accepted, rather than forwarding arbitrary URLs from the collector.
    NSCharacterSet *allowed = [
        NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    ];
    if ([noteID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        NDMPostEvent(@{
            @"event": @"deep_link_rejected",
            @"request_id": requestID ?: @"",
            @"note_id": noteID,
            @"reason": @"note_id contains unsupported characters"
        });
        return NO;
    }

    NSString *routeType = [type isEqualToString:@"video"] ? @"video" : @"normal";
    NSString *route = [NSString stringWithFormat:
        @"xhsdiscover://item/%@?type=%@", noteID, routeType];
    NSURL *URL = [NSURL URLWithString:route];
    if (!URL) return NO;

    NDMPostEvent(@{
        @"event": @"deep_link_requested",
        @"request_id": requestID ?: @"",
        @"note_id": noteID,
        @"route": [NSString stringWithFormat:
            @"xhsdiscover://item/<note_id>?type=%@", routeType]
    });

    UIApplication *application = UIApplication.sharedApplication;
    if (!application) return NO;

    [application openURL:URL options:@{} completionHandler:^(BOOL success) {
        NDMPostEvent(@{
            @"event": success ? @"deep_link_accepted" : @"deep_link_failed",
            @"request_id": requestID ?: @"",
            @"note_id": noteID
        });
    }];
    return YES;
}

static BOOL NDMRouteNoteModel(id model, NSString *requestID) {
    if (!model) return NO;
    Class router = NSClassFromString(@"XYShopping.SRouter");
    SEL selector = NSSelectorFromString(
        @"routeToNoteDetailsWith:title:note:extraSkuInfos:"
    );
    if (!router || ![router respondsToSelector:selector]) return NO;

    NDMPostEvent(@{
        @"event": @"shopping_router_requested",
        @"request_id": requestID ?: @"",
        @"model_class": NSStringFromClass(object_getClass(model)) ?: @""
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(
            router,
            selector,
            nil,
            nil,
            model,
            nil
        );
    });
    return YES;
}

static void NDMExecuteCommand(NSDictionary *command) {
    NSString *name = command[@"command"];
    NSString *requestID = command[@"request_id"];
    NSString *noteID = command[@"note_id"];
    NSString *strategy = command[@"strategy"] ?: @"auto";
    if (![name isEqualToString:@"open_note"] &&
        ![name isEqualToString:@"fetch_note"]) {
        return;
    }
    if (noteID.length == 0) {
        return;
    }

    BOOL fetchOnly = [name isEqualToString:@"fetch_note"] ||
        [strategy isEqualToString:@"fetch_only"];
    if (requestID.length > 0) {
        gPendingRequestID = requestID;
        gPendingNoteID = noteID;
    }
    if (!fetchOnly &&
        ([strategy isEqualToString:@"deep_link"] ||
         [strategy isEqualToString:@"url_scheme"] ||
         [strategy isEqualToString:@"auto"])) {
        NSString *type = command[@"type"] ?: @"normal";
        if (NDMOpenNoteDeepLink(noteID, requestID, type)) return;
        if ([strategy isEqualToString:@"deep_link"] ||
            [strategy isEqualToString:@"url_scheme"]) {
            NDMPostEvent(@{
                @"event": @"open_note_failed",
                @"request_id": requestID ?: @"",
                @"note_id": noteID,
                @"reason": @"deep link unavailable"
            });
            return;
        }
    }

    if (!fetchOnly && ([strategy isEqualToString:@"auto"] ||
        [strategy isEqualToString:@"xy_note_api"])) {
        if (NDMStartActiveNoteFetch(noteID, requestID, YES)) return;
    } else if (fetchOnly &&
        ([strategy isEqualToString:@"auto"] ||
         [strategy isEqualToString:@"fetch_only"] ||
         [strategy isEqualToString:@"xy_note_api"])) {
        if (NDMStartActiveNoteFetch(noteID, requestID, NO)) return;
    }

    SEL selector = gRouteSelector ?: @selector(openNoteDetailWithNoteID:);
    id route = ([strategy isEqualToString:@"tracker"] ||
                [strategy isEqualToString:@"auto"])
        ? gLastRouteObject
        : nil;
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
        @"strategy": strategy,
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
    NDMInstallDetailViewModelHooks();
    NDMInstallImageBrowserHooks();
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

static void NDMImageBrowserRecordLoad(
    id self,
    SEL selector,
    long long index,
    id url
) {
    id browser = NDMReadKnownValue(self, @"imageBrowser");
    NDMReportImageBrowserMedia(browser, nil, index, url);
    if (gImageBrowserRecordLoadOriginal) {
        ((void (*)(id, SEL, long long, id))gImageBrowserRecordLoadOriginal)(
            self, selector, index, url
        );
    }
}

static void NDMImageBrowserWillDisplay(
    id self,
    SEL selector,
    id collectionView,
    id cell,
    id indexPath
) {
    long long index = 0;
    NSIndexPath *typedIndexPath = (NSIndexPath *)indexPath;
    if ([typedIndexPath respondsToSelector:@selector(item)]) {
        index = typedIndexPath.item;
    }
    NDMReportImageBrowserMedia(self, cell, index, nil);
    if (gImageBrowserWillDisplayOriginal) {
        ((void (*)(id, SEL, id, id, id))gImageBrowserWillDisplayOriginal)(
            self, selector, collectionView, cell, indexPath
        );
    }
}

static void NDMInstallImageBrowserHooks(void) {
    Class viewModel = NSClassFromString(
        @"_TtC11XYNoteBasic7IBViewModel"
    );
    SEL recordSelector = NSSelectorFromString(
        @"recordImageLoadFirstStartWithIndex:url:"
    );
    Method recordMethod = viewModel
        ? class_getInstanceMethod(viewModel, recordSelector) : NULL;
    if (recordMethod && !gImageBrowserRecordLoadOriginal &&
        strcmp(method_getTypeEncoding(recordMethod), "v32@0:8q16@24") == 0) {
        if (!NDMDirectMethod(viewModel, recordSelector)) {
            class_addMethod(
                viewModel,
                recordSelector,
                method_getImplementation(recordMethod),
                method_getTypeEncoding(recordMethod)
            );
            recordMethod = NDMDirectMethod(viewModel, recordSelector);
        }
        gImageBrowserRecordLoadOriginal = method_setImplementation(
            recordMethod, (IMP)NDMImageBrowserRecordLoad
        );
        NDMPostEvent(@{
            @"event": @"image_browser_hook_installed",
            @"class": NSStringFromClass(viewModel),
            @"selector": NSStringFromSelector(recordSelector)
        });
    }

    Class browser = NSClassFromString(
        @"_TtC11XYNoteBasic12ImageBrowser"
    );
    SEL displaySelector = @selector(
        collectionView:willDisplayCell:forItemAtIndexPath:
    );
    Method displayMethod = browser
        ? class_getInstanceMethod(browser, displaySelector) : NULL;
    if (displayMethod && !gImageBrowserWillDisplayOriginal &&
        strcmp(method_getTypeEncoding(displayMethod), "v40@0:8@16@24@32") == 0) {
        if (!NDMDirectMethod(browser, displaySelector)) {
            class_addMethod(
                browser,
                displaySelector,
                method_getImplementation(displayMethod),
                method_getTypeEncoding(displayMethod)
            );
            displayMethod = NDMDirectMethod(browser, displaySelector);
        }
        gImageBrowserWillDisplayOriginal = method_setImplementation(
            displayMethod, (IMP)NDMImageBrowserWillDisplay
        );
        NDMPostEvent(@{
            @"event": @"image_browser_hook_installed",
            @"class": NSStringFromClass(browser),
            @"selector": NSStringFromSelector(displaySelector)
        });
    }
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
    if (NDMLooksLikeAuthController(self) &&
        gPendingRequestID.length > 0) {
        NDMPostEvent(@{
            @"event": @"deep_link_blocked_auth",
            @"request_id": gPendingRequestID ?: @"",
            @"note_id": gPendingNoteID ?: @"",
            @"controller": NDMControllerName(self),
            @"call_stack": NDMCallStack()
        });
    }
    if (NDMLooksLikeDetailController(self)) {
        NDMReportController(self, @"appear", nil);
        NDMReportDetailHierarchy(self);
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
            NDMHookObservedRoutes();
            NDMStartCommandPoll();
        });
    }
}
