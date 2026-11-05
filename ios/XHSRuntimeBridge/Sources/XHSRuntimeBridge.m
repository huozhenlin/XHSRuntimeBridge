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

static id XRBReadField(id object, NSString *key) {
    if (!object || !key.length) return nil;
    if ([object isKindOfClass:NSDictionary.class]) {
        return [(NSDictionary *)object objectForKey:key];
    }
    Class cls = object_getClass(object);
    SEL selector = NSSelectorFromString(key);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return nil;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] != '@') return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id XRBFirstField(id object, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = XRBReadField(object, key);
        if (value) return value;
    }
    return nil;
}

static NSString *XRBTruncateString(NSString *value, NSUInteger limit) {
    if (value.length <= limit) return value;
    return [value substringToIndex:limit];
}

static NSString *XRBURLValue(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        return [(NSURL *)value absoluteString];
    }
    if ([value isKindOfClass:NSString.class] &&
        [(NSString *)value hasPrefix:@"http"]) {
        return value;
    }
    return nil;
}

static void XRBAddURLIfNew(
    NSMutableArray<NSString *> *urls,
    id value
) {
    NSString *url = XRBURLValue(value);
    if (url.length > 0 && ![urls containsObject:url] && urls.count < 32) {
        [urls addObject:url];
    }
}

static void XRBCollectMediaURLs(
    id object,
    NSMutableArray<NSString *> *urls,
    NSUInteger depth
) {
    if (!object || depth > 2 || urls.count >= 32) return;
    XRBAddURLIfNew(urls, object);

    if ([object isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)object) {
            XRBCollectMediaURLs(item, urls, depth + 1);
            if (urls.count >= 32) break;
        }
        return;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[
            @"url", @"urlDefault", @"url_default", @"originUrl",
            @"origin_url", @"master_url", @"masterUrl", @"default_url"
        ]) {
            XRBAddURLIfNew(urls, [(NSDictionary *)object objectForKey:key]);
        }
        for (NSString *key in @[@"h264", @"stream", @"streams", @"media"]) {
            XRBCollectMediaURLs(
                [(NSDictionary *)object objectForKey:key],
                urls,
                depth + 1
            );
        }
        return;
    }

    for (NSString *key in @[
        @"url", @"urlDefault", @"url_default", @"originUrl",
        @"origin_url", @"master_url", @"masterUrl", @"default_url",
        @"h264", @"stream", @"streams", @"media"
    ]) {
        XRBCollectMediaURLs(XRBReadField(object, key), urls, depth + 1);
    }
}

static id XRBDeepSnapshot(
    id object,
    NSUInteger depth,
    NSMutableSet<NSValue *> *seen,
    NSUInteger *budget
) {
    if (!object || *budget == 0) return [NSNull null];
    if (depth > 4) return @"<max-depth>";
    (*budget)--;

    if ([object isKindOfClass:NSNull.class] ||
        [object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class]) {
        if ([object isKindOfClass:NSString.class]) {
            return XRBTruncateString(object, 4096);
        }
        return object;
    }
    if ([object isKindOfClass:NSURL.class]) {
        return [object absoluteString] ?: @"";
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray array];
        NSUInteger count = MIN((NSUInteger)[(NSArray *)object count], (NSUInteger)64);
        for (NSUInteger index = 0; index < count && *budget > 0; index++) {
            [array addObject:XRBDeepSnapshot(
                [(NSArray *)object objectAtIndex:index],
                depth + 1,
                seen,
                budget
            ) ?: [NSNull null]];
        }
        return array;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        NSUInteger count = 0;
        for (id key in [(NSDictionary *)object allKeys]) {
            if (count++ >= 128 || *budget == 0) break;
            NSString *name = [key description] ?: @"";
            id value = [(NSDictionary *)object objectForKey:key];
            dictionary[name] = XRBDeepSnapshot(
                value, depth + 1, seen, budget
            ) ?: [NSNull null];
        }
        return dictionary;
    }

    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([seen containsObject:identity]) return @"<cycle>";
    [seen addObject:identity];

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"__class"] = NSStringFromClass(object_getClass(object)) ?: @"";
    NSMutableSet<NSString *> *propertyNames = [NSMutableSet set];
    for (Class cls = object_getClass(object);
         cls && cls != NSObject.class;
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *name = property_getName(properties[index]);
            if (name) [propertyNames addObject:[NSString stringWithUTF8String:name]];
        }
        free(properties);
    }

    for (NSString *name in propertyNames) {
        if (*budget == 0) break;
        @try {
            id value = [object valueForKey:name];
            if (value) {
                result[name] = XRBDeepSnapshot(
                    value, depth + 1, seen, budget
                ) ?: [NSNull null];
            }
        } @catch (__unused NSException *exception) {
            result[name] = @"<unreadable>";
        }
    }
    return result;
}

static NSDictionary *XRBModelSummary(id model) {
    if (!model) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray<NSArray<NSString *> *> *fields = @[
        @[@"noteId", @"note_id"],
        @[@"noteID", @"note_id"],
        @[@"userId", @"user_id"],
        @[@"userID", @"user_id"],
        @[@"title", @"title"],
        @[@"desc", @"desc"],
        @[@"type", @"type"],
        @[@"source", @"source"]
    ];
    for (NSArray<NSString *> *field in fields) {
        id value = XRBReadField(model, field[0]);
        if (!value || result[field[1]]) continue;
        if ([value isKindOfClass:NSString.class] ||
            [value isKindOfClass:NSNumber.class]) {
            result[field[1]] = [value isKindOfClass:NSString.class]
                ? XRBTruncateString(value, 4096)
                : value;
        }
    }

    NSMutableArray<NSString *> *imageURLs = [NSMutableArray array];
    id images = XRBFirstField(model, @[
        @"images", @"imageList", @"image_list", @"imageInfoList",
        @"image_info_list"
    ]);
    XRBCollectMediaURLs(images, imageURLs, 0);
    if (imageURLs.count > 0) result[@"image_urls"] = imageURLs;
    for (NSString *key in @[@"images", @"imageList", @"image_list"]) {
        id value = XRBReadField(model, key);
        if ([value isKindOfClass:NSArray.class]) {
            result[@"image_count"] = @([(NSArray *)value count]);
            break;
        }
    }
    NSMutableArray<NSString *> *videoURLs = [NSMutableArray array];
    for (NSString *key in @[@"video", @"videoInfo", @"video_info_v2"]) {
        id value = XRBReadField(model, key);
        if (value) {
            result[@"video_present"] = @YES;
            result[@"video_class"] = NSStringFromClass(object_getClass(value));
            XRBCollectMediaURLs(value, videoURLs, 0);
            break;
        }
    }
    if (videoURLs.count > 0) result[@"video_urls"] = videoURLs;

    NSMutableDictionary *interactSummary = [NSMutableDictionary dictionary];
    NSArray<NSArray<NSString *> *> *counterFields = @[
        @[@"likedCount", @"liked_count"],
        @[@"likeCount", @"like_count"],
        @[@"collectedCount", @"collected_count"],
        @[@"collectCount", @"collect_count"],
        @[@"commentCount", @"comment_count"],
        @[@"commentsCount", @"comments_count"],
        @[@"shareCount", @"share_count"],
        @[@"viewCount", @"view_count"]
    ];
    NSArray *interactionObjects = @[
        model ?: [NSNull null],
        XRBFirstField(model, @[
            @"interactInfo", @"interact_info", @"interactionInfo",
            @"interaction_info", @"interact", @"interactions",
            @"engageInfo", @"engage_info"
        ]) ?: [NSNull null]
    ];
    for (id interaction in interactionObjects) {
        if (interaction == [NSNull null]) continue;
        for (NSArray<NSString *> *field in counterFields) {
            if (interactSummary[field[1]]) continue;
            id value = XRBFirstField(interaction, @[field[0], field[1]]);
            if ([value isKindOfClass:NSNumber.class] ||
                [value isKindOfClass:NSString.class]) {
                interactSummary[field[1]] = value;
            }
        }
    }
    if (interactSummary.count > 0) {
        result[@"interact_info"] = interactSummary;
    }

    id author = XRBFirstField(model, @[@"user", @"userInfo", @"author"]);
    if (author) {
        NSMutableDictionary *authorSummary = [NSMutableDictionary dictionary];
        id authorID = XRBFirstField(author, @[
            @"userId", @"userID", @"user_id", @"authorId", @"author_id"
        ]);
        id nickname = XRBFirstField(author, @[@"nickname", @"name", @"nickName"]);
        if (authorID) authorSummary[@"user_id"] = authorID;
        if ([nickname isKindOfClass:NSString.class]) {
            authorSummary[@"nickname"] = XRBTruncateString(nickname, 256);
        }
        if (authorSummary.count > 0) result[@"author"] = authorSummary;
    }
    result[@"model_class"] = NSStringFromClass(object_getClass(model)) ?: @"";
    return result;
}

static NSArray<NSString *> *XRBCallStack(void) {
    NSArray<NSString *> *symbols = NSThread.callStackSymbols;
    NSUInteger count = MIN((NSUInteger)16, symbols.count);
    return count > 0 ? [symbols subarrayWithRange:NSMakeRange(0, count)] : @[];
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
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"call_stack": XRBCallStack()
    }];
    if (extra) [fields addEntriesFromDictionary:extra];
    XRBLogEvent(@"business_method_enter", fields);
}

static void XRBHookVoidObject(id self, SEL selector, id argument) {
    XRBLogBusinessEnter(self, selector, @{
        @"argument_class": argument ? NSStringFromClass(object_getClass(argument)) : @"<nil>",
        @"argument_description": XRBShortDescription(argument)
    });
    NSString *selectorName = NSStringFromSelector(selector);
    if ([selectorName isEqualToString:@"setContentNoteModel:"] ||
        [selectorName isEqualToString:@"setNote:"] ||
        [selectorName isEqualToString:@"setNoteModel:"] ||
        [selectorName isEqualToString:@"setNoteDetail:"] ||
        [selectorName isEqualToString:@"setNoteDetailModel:"] ||
        [selectorName isEqualToString:@"setContentModel:"] ||
        [selectorName isEqualToString:@"setData:"]) {
        NSMutableDictionary *summary = [NSMutableDictionary
            dictionaryWithDictionary:XRBModelSummary(argument)];
        summary[@"setter"] = selectorName;
        summary[@"setter_class"] = NSStringFromClass(object_getClass(self))
            ?: @"";
        XRBLogEvent(@"note_model_received", summary);
        NSMutableSet<NSValue *> *seen = [NSMutableSet set];
        NSUInteger budget = 600;
        XRBLogEvent(@"note_model_dump", @{
            @"model_class": NSStringFromClass(object_getClass(argument))
                ?: @"",
            @"snapshot": XRBDeepSnapshot(
                argument, 0, seen, &budget
            ) ?: [NSNull null],
            @"remaining_budget": @(budget)
        });
    }
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
    NSString *selectorName = NSStringFromSelector(selector);
    if ([selectorName isEqualToString:@"contentNoteModel"] ||
        [selectorName isEqualToString:@"noteDetailModel"] ||
        [selectorName isEqualToString:@"noteDetail"] ||
        [selectorName isEqualToString:@"noteModel"] ||
        [selectorName isEqualToString:@"data"]) {
        NSMutableDictionary *summary = [NSMutableDictionary
            dictionaryWithDictionary:XRBModelSummary(result)];
        summary[@"getter"] = selectorName;
        summary[@"getter_class"] = NSStringFromClass(object_getClass(self))
            ?: @"";
        XRBLogEvent(@"note_model_received", summary);
    }
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
        @[@"XYVTPlayerConfigModel", @"setContentNoteModel:"],
        @[@"XYNoteModule.NoteDetailDataSource", @"setNote:"],
        @[@"XYNoteModule.NoteDetailDataSource", @"setNoteModel:"],
        @[@"XYNoteModule.NoteDetailDataSource", @"setNoteDetail:"],
        @[@"XYNoteModule.NoteDetailDataSource", @"setNoteDetailModel:"],
        @[@"XYNoteModule.NoteDetailDataSource", @"noteDetailModel"],
        @[@"XYNoteModule.NoteDetailDataSource", @"noteModel"],
        @[@"XYNoteModule.NoteDetailViewController", @"setNote:"],
        @[@"XYNoteModule.NoteDetailViewController", @"setNoteModel:"],
        @[@"XYNoteModule.NoteDetailViewController", @"setNoteDetail:"],
        @[@"XYNoteModule.NoteDetailViewController", @"setNoteDetailModel:"],
        @[@"XYNoteModule.NoteDetailViewController", @"noteDetailModel"],
        @[@"XYNoteModule.NoteDetailViewController", @"noteModel"],
        @[@"XYNoteModule.NoteDetailViewControllerV1", @"setNote:"],
        @[@"XYNoteModule.NoteDetailViewControllerV1", @"setNoteModel:"],
        @[@"XYNoteModule.NoteDetailViewControllerV1", @"setNoteDetail:"],
        @[@"XYNoteModule.NoteDetailViewControllerV1", @"setNoteDetailModel:"],
        @[@"XYNoteModule.NoteDetailViewControllerV1", @"noteDetailModel"],
        @[@"XYNoteModule.NoteDetailViewControllerV1", @"noteModel"],
        @[@"_TtC12XYNoteModule20NoteDetailDataSource", @"setNote:"],
        @[@"_TtC12XYNoteModule20NoteDetailDataSource", @"setNoteModel:"],
        @[@"_TtC12XYNoteModule20NoteDetailDataSource", @"setNoteDetail:"],
        @[@"_TtC12XYNoteModule20NoteDetailDataSource", @"setNoteDetailModel:"],
        @[@"_TtC12XYNoteModule24NoteDetailViewController", @"setNote:"],
        @[@"_TtC12XYNoteModule24NoteDetailViewController", @"setNoteModel:"],
        @[@"_TtC12XYNoteModule24NoteDetailViewController", @"setNoteDetail:"],
        @[@"_TtC12XYNoteModule24NoteDetailViewController", @"setNoteDetailModel:"],
        @[@"XHSVideoDownloadSources", @"downloadVideo:"],
        @[@"XHSVideoDownloadSources", @"Xdownload:"],
        @[@"XHSVideoDownloadSources", @"Xdownload:preferredName:"],
        @[@"XHSVideoDownloadSources", @"XdownloadAllPhotos:"],
        @[@"XHSPhotoAlbumManager", @"saveImageWithUrl:authorId:"],
        @[@"XHSPhotoAlbumManager", @"saveVideoWithURL:context:preferredName:"],
        @[@"XHSPhotoAlbumManager", @"saveImageAtFileURL:preferredName:completion:"],
        @[@"XHSPhotoAlbumManager", @"saveVideoAtFileURL:preferredName:completion:"]
    ];
    for (NSArray<NSString *> *target in targets) {
        XRBInstallBusinessHook(target[0], target[1]);
    }
}

static void XRBRescanBusinessHooks(void) {
    XRBInstallBusinessHooks();
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            XRBRescanBusinessHooks();
        }
    );
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
                    XRBRescanBusinessHooks();
                    XRBLogEvent(@"runtime_scan_completed", nil);
                }
            );
        });
    }
}
