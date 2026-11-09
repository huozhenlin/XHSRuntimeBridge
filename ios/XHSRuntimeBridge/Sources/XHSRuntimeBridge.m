#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <pthread.h>

#import "XHSRuntimeLogger.h"

void XRBInstallSettingsUI(void);

typedef struct XRBMethodHookEntry {
    Class cls;
    SEL selector;
    IMP original;
    struct XRBMethodHookEntry *next;
} XRBMethodHookEntry;

static XRBMethodHookEntry *gBusinessHooks;
static pthread_mutex_t gBusinessHooksLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSMutableData *> *gNetworkBuffers;
static pthread_mutex_t gNetworkBuffersLock = PTHREAD_MUTEX_INITIALIZER;

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
        @"contentNoteModel",
        @"imagesList",
        @"videoURLs",
        @"videoURL",
        @"videoInfo",
        @"sourcesWithPrimaryURL:context:",
        @"setVideoInfo:",
        @"setVideoURL:",
        @"setVideoURLs:",
        @"setNote:",
        @"setViewModel:",
        @"setModel:",
        @"setData:",
        @"setContentModel:",
        @"model",
        @"viewModel",
        @"contentModel",
        @"setCellViewModelList:",
        @"modelCustomTransformFromDictionary:",
        @"modelCustomTransformFromDictionary:",
        @"noteId",
        @"noteID",
        @"userId",
        @"userID",
        @"title",
        @"desc",
        @"likedCount",
        @"commentsCount",
        @"collectedCount",
        @"shareCount",
        @"likeCount",
        @"commentCount",
        @"collectCount",
        @"sharedCount",
        @"interactInfo",
        @"interactionInfo",
        @"isLiked",
        @"isCollected",
        @"note_data",
        @"media_data",
        @"cur_position",
        @"context",
        @"scene",
        @"original_url",
        @"url",
        @"media_type",
        @"uniqueId",
        @"browserItemUrl",
        @"browserItemOriginUrl",
        @"browserItemFileId",
        @"livePhotoVideoPath",
        @"originalURL",
        @"mediaType",
        @"uniqueID",
        @"browserItemURL",
        @"browserItemOriginURL",
        @"browserItemFileID",
        @"imageURL",
        @"photoURL",
        @"largeImageURL",
        @"image",
        @"video",
        @"imageData",
        @"videoData",
        @"videoDataInfo",
        @"videoUrl",
        @"identifier",
        @"cellViewModelList",
        @"downloadButtonTapped:",
        @"mediaBrowserViewModelDidClickDownloadButtonAtIndex:index:"
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

static id XRBTrimJSON(
    id value,
    NSUInteger depth,
    NSUInteger *budget
) {
    if (!value || *budget == 0) return [NSNull null];
    if (depth > 4) return @"<max-depth>";
    (*budget)--;

    if ([value isKindOfClass:NSString.class]) {
        NSString *text = value;
        return text.length > 1024 ? [text substringToIndex:1024] : text;
    }
    if ([value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSNull.class]) {
        return value;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        NSUInteger count = MIN((NSUInteger)[(NSArray *)value count],
                               (NSUInteger)64);
        for (NSUInteger index = 0;
             index < count && *budget > 0;
             index++) {
            [result addObject:XRBTrimJSON(
                [(NSArray *)value objectAtIndex:index],
                depth + 1,
                budget
            ) ?: [NSNull null]];
        }
        return result;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        NSUInteger count = 0;
        for (id key in [(NSDictionary *)value allKeys]) {
            if (count++ >= 96 || *budget == 0) break;
            NSString *name = [key description] ?: @"";
            result[name] = XRBTrimJSON(
                [(NSDictionary *)value objectForKey:key],
                depth + 1,
                budget
            ) ?: [NSNull null];
        }
        return result;
    }
    return [value description] ?: @"";
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
            NSUInteger budget = 400;
            summary[@"json_snapshot"] = XRBTrimJSON(JSON, 0, &budget);
            summary[@"json_remaining_budget"] = @(budget);
        } else if ([JSON isKindOfClass:NSArray.class]) {
            summary[@"json_type"] = @"array";
            summary[@"array_count"] = @([(NSArray *)JSON count]);
            NSUInteger budget = 400;
            summary[@"json_snapshot"] = XRBTrimJSON(JSON, 0, &budget);
            summary[@"json_remaining_budget"] = @(budget);
        } else {
            summary[@"json_type"] = @"non_json";
        }
    }
    return summary;
}

static BOOL XRBIsLikelyNoteRequest(NSURL *URL) {
    if (!URL) return NO;
    NSString *path = URL.path.lowercaseString ?: @"";
    if ([path containsString:@"/api/sns/v10/note"]) return YES;
    if (![path containsString:@"/api/"]) return NO;
    for (NSString *term in @[
        @"note", @"feed", @"explore", @"image", @"video", @"detail"
    ]) {
        if ([path containsString:term]) return YES;
    }
    return NO;
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
    NSString *objectClassName = NSStringFromClass(object_getClass(object)) ?: @"";
    for (NSString *prefix in @[
        @"NS", @"UI", @"CF", @"CG", @"CA", @"AV", @"PH", @"NSURL"
    ]) {
        if ([objectClassName hasPrefix:prefix]) {
            return @{@"__class": objectClassName};
        }
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
            if (!name) continue;
            NSString *propertyName = [NSString stringWithUTF8String:name];
            NSString *lower = propertyName.lowercaseString;
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
            if (safe) [propertyNames addObject:propertyName];
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

static NSDictionary *XRBMediaFieldSummary(id value) {
    if (!value) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSArray<NSString *> *field in @[
        @[@"id", @"id"],
        @[@"noteId", @"note_id"],
        @[@"original_url", @"original_url"],
        @[@"originalUrl", @"original_url"],
        @[@"url", @"url"],
        @[@"browserItemUrl", @"browser_item_url"],
        @[@"browserItemOriginUrl", @"browser_item_origin_url"],
        @[@"browserItemFileId", @"browser_item_file_id"],
        @[@"media_type", @"media_type"],
        @[@"mediaType", @"media_type"],
        @[@"uniqueId", @"unique_id"],
        @[@"image", @"image"],
        @[@"video", @"video"],
        @[@"videoUrl", @"video_url"],
        @[@"identifier", @"identifier"],
        @[@"imageData", @"image_data"],
        @[@"videoData", @"video_data"],
        @[@"videoDataInfo", @"video_data_info"],
        @[@"isVideo", @"is_video"],
        @[@"isLivePhoto", @"is_live_photo"],
        @[@"width", @"width"],
        @[@"height", @"height"]
    ]) {
        id fieldValue = XRBReadField(value, field[0]);
        if (!fieldValue) continue;
        if ([fieldValue isKindOfClass:NSString.class] ||
            [fieldValue isKindOfClass:NSNumber.class] ||
            [fieldValue isKindOfClass:NSURL.class]) {
            result[field[1]] = [fieldValue isKindOfClass:NSURL.class]
                ? [(NSURL *)fieldValue absoluteString]
                : fieldValue;
        }
    }
    result[@"class"] = NSStringFromClass(object_getClass(value)) ?: @"";
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
    if ([selectorName isEqualToString:@"downloadButtonTapped:"]) {
        XRBLogEvent(@"media_download_action", @{
            @"class": NSStringFromClass(object_getClass(self)) ?: @"",
            @"selector": selectorName,
            @"argument_class": argument
                ? NSStringFromClass(object_getClass(argument)) : @"<nil>",
            @"call_stack": XRBCallStack()
        });
    }
    if ([selectorName isEqualToString:@"setContentNoteModel:"] ||
        [selectorName isEqualToString:@"setVideoInfo:"] ||
        [selectorName isEqualToString:@"setVideoURL:"] ||
        [selectorName isEqualToString:@"setVideoURLs:"] ||
        [selectorName isEqualToString:@"setNote:"] ||
        [selectorName isEqualToString:@"setViewModel:"] ||
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
        NSUInteger budget = 240;
        XRBLogEvent(@"note_model_dump", @{
            @"model_class": NSStringFromClass(object_getClass(argument))
                ?: @"",
            @"snapshot": XRBDeepSnapshot(
                argument, 0, seen, &budget
            ) ?: [NSNull null],
            @"remaining_budget": @(budget)
        });
        if ([selectorName isEqualToString:@"setVideoInfo:"] ||
            [selectorName isEqualToString:@"setVideoURL:"] ||
            [selectorName isEqualToString:@"setVideoURLs:"] ||
            [selectorName isEqualToString:@"setNote:"] ||
            [selectorName isEqualToString:@"setViewModel:"] ||
            [selectorName isEqualToString:@"setModel:"] ||
            [selectorName isEqualToString:@"setData:"] ||
            [selectorName isEqualToString:@"setContentModel:"]) {
            XRBLogEvent(@"media_field_received", summary);
        }
    }
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id))original)(self, selector, argument);
    }
}

static BOOL XRBHookBoolObject(id self, SEL selector, id argument) {
    XRBLogBusinessEnter(self, selector, @{
        @"argument_class": argument
            ? NSStringFromClass(object_getClass(argument)) : @"<nil>"
    });
    IMP original = XRBOriginalImplementation(self, selector);
    BOOL result = original
        ? ((BOOL (*)(id, SEL, id))original)(self, selector, argument)
        : NO;

    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": @"note_model_transform",
        @"class": NSStringFromClass(object_getClass(self)) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"success": @(result),
        @"model_fields": XRBModelSummary(self),
        @"call_stack": XRBCallStack()
    }];
    if (argument) {
        NSMutableSet<NSValue *> *seen = [NSMutableSet set];
        NSUInteger budget = 500;
        event[@"input_snapshot"] = XRBDeepSnapshot(
            argument, 0, seen, &budget
        ) ?: [NSNull null];
        event[@"remaining_budget"] = @(budget);
    }
    XRBLogEvent(@"note_model_transform", event);
    return result;
}

static void XRBHookVoidObjectLong(
    id self,
    SEL selector,
    id object,
    long index
) {
    XRBLogEvent(@"media_download_action", @{
        @"class": NSStringFromClass(object_getClass(self)) ?: @"",
        @"selector": NSStringFromSelector(selector) ?: @"",
        @"object_class": object
            ? NSStringFromClass(object_getClass(object)) : @"<nil>",
        @"index": @(index),
        @"call_stack": XRBCallStack()
    });
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, long))original)(
            self, selector, object, index
        );
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

static id XRBHookObjectTwoObjects(
    id self,
    SEL selector,
    id first,
    id second
) {
    XRBLogBusinessEnter(self, selector, @{
        @"first_argument_class": first
            ? NSStringFromClass(object_getClass(first)) : @"<nil>",
        @"second_argument_class": second
            ? NSStringFromClass(object_getClass(second)) : @"<nil>"
    });
    IMP original = XRBOriginalImplementation(self, selector);
    if (!original) return nil;
    id result = ((id (*)(id, SEL, id, id))original)(
        self, selector, first, second
    );
    NSMutableDictionary *summary = [NSMutableDictionary
        dictionaryWithDictionary:XRBModelSummary(result)];
    summary[@"class"] = NSStringFromClass(object_getClass(self)) ?: @"";
    summary[@"selector"] = NSStringFromSelector(selector) ?: @"";
    summary[@"result_class"] = result
        ? NSStringFromClass(object_getClass(result)) : @"<nil>";
    if (result) {
        NSMutableSet<NSValue *> *seen = [NSMutableSet set];
        NSUInteger budget = 500;
        summary[@"snapshot"] = XRBDeepSnapshot(
            result, 0, seen, &budget
        ) ?: [NSNull null];
        summary[@"remaining_budget"] = @(budget);
    }
    XRBLogEvent(@"note_media_field_received", summary);
    return result;
}

static id XRBHookObjectNoArgument(id self, SEL selector) {
    XRBLogBusinessEnter(self, selector, nil);
    IMP original = XRBOriginalImplementation(self, selector);
    if (!original) return nil;
    id result = ((id (*)(id, SEL))original)(self, selector);
    NSString *selectorName = NSStringFromSelector(selector);
    NSSet<NSString *> *mediaSelectors = [NSSet setWithArray:@[
        @"note_data", @"media_data", @"cur_position", @"context", @"scene",
        @"original_url", @"url", @"media_type", @"uniqueId",
        @"browserItemUrl", @"browserItemOriginUrl", @"browserItemFileId",
        @"livePhotoVideoPath", @"id", @"image", @"video", @"imageData",
        @"originalURL", @"mediaType", @"uniqueID",
        @"browserItemURL", @"browserItemOriginURL", @"browserItemFileID",
        @"imageURL", @"photoURL", @"largeImageURL",
        @"fileId", @"livePhotoVideoFileId", @"livePhotoVideoUrl",
        @"livePhotoVideoURL", @"livePhotoImageURL", @"livePhotoVideoInfo",
        @"videoData", @"videoDataInfo", @"videoUrl", @"identifier",
        @"noteId", @"noteID", @"userId", @"userID", @"title", @"desc",
        @"likedCount", @"commentsCount", @"collectedCount", @"shareCount",
        @"likeCount", @"commentCount", @"collectCount", @"sharedCount",
        @"interactInfo", @"interactionInfo", @"isLiked", @"isCollected",
        @"model", @"viewModel", @"contentModel",
        @"cellViewModelList",
        @"downloadButtonTapped:",
        @"mediaBrowserViewModelDidClickDownloadButtonAtIndex:index:"
    ]];
    if ([mediaSelectors containsObject:selectorName]) {
        NSMutableDictionary *media = [NSMutableDictionary
            dictionaryWithDictionary:XRBMediaFieldSummary(result)];
        media[@"event"] = @"media_field_received";
        media[@"selector"] = selectorName ?: @"";
        media[@"owner_class"] = NSStringFromClass(object_getClass(self))
            ?: @"";
        if (result) {
            NSMutableSet<NSValue *> *seen = [NSMutableSet set];
            NSUInteger budget = 240;
            media[@"snapshot"] = XRBDeepSnapshot(
                result, 0, seen, &budget
            ) ?: [NSNull null];
            media[@"remaining_budget"] = @(budget);
        }
        XRBLogEvent(@"media_field_received", media);
    }
    NSSet<NSString *> *noteFieldSelectors = [NSSet setWithArray:@[
        @"noteId", @"noteID", @"userId", @"userID", @"title", @"desc",
        @"likedCount", @"commentsCount", @"collectedCount", @"shareCount",
        @"likeCount", @"commentCount", @"collectCount", @"sharedCount",
        @"interactInfo", @"interactionInfo", @"isLiked", @"isCollected"
    ]];
    if ([noteFieldSelectors containsObject:selectorName]) {
        NSMutableDictionary *field = [NSMutableDictionary dictionaryWithDictionary:
            XRBMediaFieldSummary(result)];
        field[@"event"] = @"note_field_received";
        field[@"selector"] = selectorName ?: @"";
        field[@"owner_class"] = NSStringFromClass(object_getClass(self))
            ?: @"";
        if ([result isKindOfClass:NSString.class] ||
            [result isKindOfClass:NSNumber.class]) {
            field[@"value"] = result;
        }
        XRBLogEvent(@"note_field_received", field);
    }
    if ([selectorName isEqualToString:@"contentNoteModel"] ||
        [selectorName isEqualToString:@"imagesList"] ||
        [selectorName isEqualToString:@"videoURLs"] ||
        [selectorName isEqualToString:@"videoURL"] ||
        [selectorName isEqualToString:@"videoInfo"] ||
        [selectorName isEqualToString:@"model"] ||
        [selectorName isEqualToString:@"viewModel"] ||
        [selectorName isEqualToString:@"contentModel"] ||
        [selectorName isEqualToString:@"noteDetailModel"] ||
        [selectorName isEqualToString:@"noteDetail"] ||
        [selectorName isEqualToString:@"noteModel"] ||
        [selectorName isEqualToString:@"data"]) {
        NSMutableDictionary *summary = [NSMutableDictionary
            dictionaryWithDictionary:XRBModelSummary(result)];
        summary[@"getter"] = selectorName;
        summary[@"getter_class"] = NSStringFromClass(object_getClass(self))
            ?: @"";
        if (result) {
            NSMutableSet<NSValue *> *seen = [NSMutableSet set];
            NSUInteger budget = 400;
            summary[@"snapshot"] = XRBDeepSnapshot(
                result, 0, seen, &budget
            ) ?: [NSNull null];
            summary[@"remaining_budget"] = @(budget);
        }
        XRBLogEvent(@"note_model_received", summary);
        if ([selectorName isEqualToString:@"imagesList"] ||
            [selectorName isEqualToString:@"videoURLs"] ||
            [selectorName isEqualToString:@"videoURL"] ||
            [selectorName isEqualToString:@"videoInfo"]) {
            NSMutableSet<NSValue *> *seen = [NSMutableSet set];
            NSUInteger budget = 500;
            summary[@"snapshot"] = XRBDeepSnapshot(
                result, 0, seen, &budget
            ) ?: [NSNull null];
            summary[@"remaining_budget"] = @(budget);
            XRBLogEvent(@"note_media_field_received", summary);
        }
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
        void (^wrappedCompletion)(id, id) = ^(id result, id error) {
            NSMutableDictionary *summary = [NSMutableDictionary
                dictionaryWithDictionary:XRBModelSummary(result)];
            summary[@"class"] = NSStringFromClass(object_getClass(self))
                ?: @"";
            summary[@"selector"] = NSStringFromSelector(selector) ?: @"";
            summary[@"result_class"] = result
                ? NSStringFromClass(object_getClass(result))
                : @"<nil>";
            summary[@"error_class"] = error
                ? NSStringFromClass(object_getClass(error))
                : @"<nil>";
            XRBLogEvent(@"business_completion", summary);

            if (result) {
                NSMutableSet<NSValue *> *seen = [NSMutableSet set];
                NSUInteger budget = 240;
                XRBLogEvent(@"note_model_completion_dump", @{
                    @"class": NSStringFromClass(object_getClass(self))
                        ?: @"",
                    @"selector": NSStringFromSelector(selector) ?: @"",
                    @"model_class": NSStringFromClass(object_getClass(result))
                        ?: @"",
                    @"snapshot": XRBDeepSnapshot(
                        result, 0, seen, &budget
                    ) ?: [NSNull null],
                    @"remaining_budget": @(budget)
                });
            }

            if (completion) {
                ((void (^)(id, id))completion)(result, error);
            }
        };
        ((void (*)(id, SEL, id, id))original)(
            self,
            selector,
            argument,
            wrappedCompletion
        );
    }
}

static void XRBHookCompletionOnly(
    id self,
    SEL selector,
    id completion
) {
    XRBLogBusinessEnter(self, selector, @{
        @"completion_class": completion
            ? NSStringFromClass(object_getClass(completion))
            : @"<nil>"
    });
    IMP original = XRBOriginalImplementation(self, selector);
    if (!original) return;

    void (^wrappedCompletion)(id, id) = ^(id result, id error) {
        NSMutableDictionary *summary = [NSMutableDictionary
            dictionaryWithDictionary:XRBModelSummary(result)];
        summary[@"class"] = NSStringFromClass(object_getClass(self)) ?: @"";
        summary[@"selector"] = NSStringFromSelector(selector) ?: @"";
        summary[@"result_class"] = result
            ? NSStringFromClass(object_getClass(result))
            : @"<nil>";
        summary[@"error_class"] = error
            ? NSStringFromClass(object_getClass(error))
            : @"<nil>";
        XRBLogEvent(@"business_completion", summary);

        if (result) {
            NSMutableSet<NSValue *> *seen = [NSMutableSet set];
            NSUInteger budget = 240;
            XRBLogEvent(@"note_model_completion_dump", @{
                @"class": NSStringFromClass(object_getClass(self)) ?: @"",
                @"selector": NSStringFromSelector(selector) ?: @"",
                @"model_class": NSStringFromClass(object_getClass(result))
                    ?: @"",
                @"snapshot": XRBDeepSnapshot(
                    result, 0, seen, &budget
                ) ?: [NSNull null],
                @"remaining_budget": @(budget)
            });
        }

        if (completion) {
            ((void (^)(id, id))completion)(result, error);
        }
    };
    ((void (*)(id, SEL, id))original)(
        self, selector, wrappedCompletion
    );
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

static NSString *XRBTaskKey(id task) {
    return [NSString stringWithFormat:@"%p", task];
}

static BOOL XRBIsAppDelegateClass(Class cls) {
    NSString *name = NSStringFromClass(cls) ?: @"";
    if (name.length == 0) return NO;
    for (NSString *prefix in @[
        @"NS", @"UI", @"CF", @"NSURL", @"_NS", @"__NS", @"OS"
    ]) {
        if ([name hasPrefix:prefix]) return NO;
    }
    return YES;
}

static NSURL *XRBTaskURL(id task) {
    if (!task) return nil;
    @try {
        if ([task respondsToSelector:@selector(originalRequest)]) {
            NSURLRequest *request = [task originalRequest];
            if (request.URL) return request.URL;
        }
        if ([task respondsToSelector:@selector(currentRequest)]) {
            NSURLRequest *request = [task currentRequest];
            return request.URL;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static void XRBHookURLSessionDidReceiveData(
    id self,
    SEL selector,
    id session,
    id task,
    NSData *data
) {
    NSURL *URL = XRBTaskURL(task);
    if (URL && XRBIsLikelyNoteRequest(URL) && data.length > 0) {
        NSString *key = XRBTaskKey(task);
        pthread_mutex_lock(&gNetworkBuffersLock);
        if (!gNetworkBuffers) {
            gNetworkBuffers = [NSMutableDictionary dictionary];
        }
        NSMutableData *buffer = gNetworkBuffers[key];
        if (!buffer) {
            buffer = [NSMutableData data];
            gNetworkBuffers[key] = buffer;
        }
        if (buffer.length < (4 * 1024 * 1024)) {
            NSUInteger remaining = (4 * 1024 * 1024) - buffer.length;
            [buffer appendBytes:data.bytes
                         length:MIN(remaining, data.length)];
        }
        pthread_mutex_unlock(&gNetworkBuffersLock);
    }

    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(
            self, selector, session, task, data
        );
    }
}

static void XRBHookURLSessionDidComplete(
    id self,
    SEL selector,
    id session,
    id task,
    NSError *error
) {
    NSURL *URL = XRBTaskURL(task);
    NSData *body = nil;
    if (URL && XRBIsLikelyNoteRequest(URL)) {
        NSString *key = XRBTaskKey(task);
        pthread_mutex_lock(&gNetworkBuffersLock);
        body = [gNetworkBuffers[key] copy];
        [gNetworkBuffers removeObjectForKey:key];
        pthread_mutex_unlock(&gNetworkBuffersLock);

        NSMutableDictionary *summary = [NSMutableDictionary
            dictionaryWithDictionary:XRBResponseSummary(
                body,
                [task response],
                error
            )];
        summary[@"url_scheme"] = URL.scheme ?: @"";
        summary[@"url_host"] = URL.host ?: @"";
        summary[@"url_path"] = URL.path ?: @"";
        summary[@"transport"] = @"urlsession_delegate";
        XRBLogEvent(@"note_detail_response", summary);
    }

    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(
            self, selector, session, task, error
        );
    }
}

static void XRBHookURLSessionDidReceiveResponse(
    id self,
    SEL selector,
    id session,
    id task,
    NSURLResponse *response,
    void (^completion)(NSInteger)
) {
    NSURL *URL = XRBTaskURL(task);
    if (URL && XRBIsLikelyNoteRequest(URL)) {
        XRBLogEvent(@"note_detail_response_headers", @{
            @"url_scheme": URL.scheme ?: @"",
            @"url_host": URL.host ?: @"",
            @"url_path": URL.path ?: @"",
            @"status_code": [response isKindOfClass:NSHTTPURLResponse.class]
                ? @([(NSHTTPURLResponse *)response statusCode])
                : @0,
            @"transport": @"urlsession_delegate"
        });
    }
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id, id, void (^)(NSInteger)))original)(
            self, selector, session, task, response, completion
        );
    }
}

static void XRBHookURLSessionRedirect(
    id self,
    SEL selector,
    id session,
    id task,
    NSURLResponse *response,
    NSURLRequest *request,
    void (^completion)(NSURLRequest *)
) {
    NSURL *URL = XRBTaskURL(task);
    if (URL && XRBIsLikelyNoteRequest(URL)) {
        XRBLogEvent(@"note_detail_redirect", @{
            @"from_path": URL.path ?: @"",
            @"to_scheme": request.URL.scheme ?: @"",
            @"to_host": request.URL.host ?: @"",
            @"to_path": request.URL.path ?: @"",
            @"transport": @"urlsession_delegate"
        });
    }
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id, id, id,
                   void (^)(NSURLRequest *)))original)(
            self, selector, session, task, response, request, completion
        );
    }
}

static void XRBHookURLSessionDownloadFinished(
    id self,
    SEL selector,
    id session,
    id task,
    NSURL *location
) {
    NSURL *URL = XRBTaskURL(task);
    if (URL && XRBIsLikelyNoteRequest(URL)) {
        NSNumber *size = nil;
        NSDictionary *attributes =
            [NSFileManager.defaultManager attributesOfItemAtPath:
                location.path error:nil];
        size = attributes[NSFileSize];
        XRBLogEvent(@"note_detail_download_finished", @{
            @"url_path": URL.path ?: @"",
            @"temporary_file_size": size ?: @0,
            @"transport": @"urlsession_download_delegate"
        });
    }
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(
            self, selector, session, task, location
        );
    }
}

static void XRBHookURLSessionDownloadComplete(
    id self,
    SEL selector,
    id session,
    id task,
    NSError *error
) {
    NSURL *URL = XRBTaskURL(task);
    if (URL && XRBIsLikelyNoteRequest(URL)) {
        XRBLogEvent(@"note_detail_download_complete", @{
            @"url_path": URL.path ?: @"",
            @"success": @(!error),
            @"error_domain": error.domain ?: @"",
            @"error_code": error ? @(error.code) : @0,
            @"transport": @"urlsession_download_delegate"
        });
    }
    IMP original = XRBOriginalImplementation(self, selector);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(
            self, selector, session, task, error
        );
    }
}

static void XRBInstallURLSessionDelegateObservation(void) {
    SEL receiveSelector =
        @selector(URLSession:dataTask:didReceiveData:);
    SEL completeSelector =
        @selector(URLSession:task:didCompleteWithError:);
    SEL responseSelector =
        @selector(URLSession:dataTask:didReceiveResponse:completionHandler:);
    SEL redirectSelector =
        @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:);
    SEL downloadFinishedSelector =
        @selector(URLSession:downloadTask:didFinishDownloadingToURL:);
    SEL downloadCompleteSelector =
        @selector(URLSession:downloadTask:didCompleteWithError:);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSArray<NSString *> *delegateSelectorNames = @[
        @"URLSession:dataTask:didReceiveData:",
        @"URLSession:task:didCompleteWithError:",
        @"URLSession:dataTask:didReceiveResponse:completionHandler:",
        @"URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:",
        @"URLSession:downloadTask:didFinishDownloadingToURL:",
        @"URLSession:downloadTask:didCompleteWithError:"
    ];
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (!XRBIsAppDelegateClass(cls)) continue;
        for (NSString *selectorName in delegateSelectorNames) {
            SEL selector = NSSelectorFromString(selectorName);
            Method method = XRBDirectMethod(cls, selector);
            if (!method) continue;

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
            if (alreadyInstalled) continue;

            const char *encoding = method_getTypeEncoding(method);
            IMP replacement = NULL;
            if (selector == receiveSelector &&
                strcmp(encoding, "v32@0:8@16@24@32") == 0) {
                replacement = (IMP)XRBHookURLSessionDidReceiveData;
            } else if (selector == completeSelector &&
                       strcmp(encoding, "v32@0:8@16@24@32") == 0) {
                replacement = (IMP)XRBHookURLSessionDidComplete;
            } else if (selector == responseSelector &&
                       strcmp(encoding, "v40@0:8@16@24@32") == 0) {
                replacement = (IMP)XRBHookURLSessionDidReceiveResponse;
            } else if (selector == redirectSelector &&
                       strcmp(encoding, "v48@0:8@16@24@32@?40") == 0) {
                replacement = (IMP)XRBHookURLSessionRedirect;
            } else if (selector == downloadFinishedSelector &&
                       strcmp(encoding, "v32@0:8@16@24") == 0) {
                replacement = (IMP)XRBHookURLSessionDownloadFinished;
            } else if (selector == downloadCompleteSelector &&
                       strcmp(encoding, "v32@0:8@16@24") == 0) {
                replacement = (IMP)XRBHookURLSessionDownloadComplete;
            } else {
                continue;
            }

            IMP original = method_setImplementation(method, replacement);
            XRBRememberBusinessHook(cls, selector, original);
            XRBLogEvent(@"network_delegate_hook_installed", @{
                @"class": NSStringFromClass(cls) ?: @"",
                @"selector": NSStringFromSelector(selector) ?: @"",
                @"type_encoding": [NSString stringWithUTF8String:encoding]
            });
        }
    }
    free(classes);
}

static void XRBInstallBusinessHook(
    NSString *className,
    NSString *selectorName
) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !selector) return;

    Method method = XRBDirectMethod(cls, selector);
    if (!method) {
        Method inherited = class_getInstanceMethod(cls, selector);
        if (inherited &&
            class_addMethod(
                cls,
                selector,
                method_getImplementation(inherited),
                method_getTypeEncoding(inherited)
            )) {
            method = XRBDirectMethod(cls, selector);
        }
    }
    if (!method) return;

    const char *encoding = method_getTypeEncoding(method);
    IMP replacement = NULL;
    NSString *kind = nil;
    if (strcmp(encoding, "v24@0:8@16") == 0) {
        replacement = (IMP)XRBHookVoidObject;
        kind = @"void_object";
    } else if (strcmp(encoding, "B24@0:8@16") == 0) {
        replacement = (IMP)XRBHookBoolObject;
        kind = @"bool_object";
    } else if (strcmp(encoding, "B24@0:8@16") == 0) {
        replacement = (IMP)XRBHookBoolObject;
        kind = @"bool_object";
    } else if (strcmp(encoding, "@24@0:8@16") == 0) {
        replacement = (IMP)XRBHookObjectObject;
        kind = @"object_object";
    } else if (strcmp(encoding, "@32@0:8@16@24") == 0) {
        replacement = (IMP)XRBHookObjectTwoObjects;
        kind = @"object_two_objects";
    } else if (strcmp(encoding, "v32@0:8@16q24") == 0) {
        replacement = (IMP)XRBHookVoidObjectLong;
        kind = @"void_object_long";
    } else if (strcmp(encoding, "@16@0:8") == 0) {
        replacement = (IMP)XRBHookObjectNoArgument;
        kind = @"object_no_argument";
    } else if (strcmp(encoding, "v32@0:8@16@?24") == 0) {
        replacement = (IMP)XRBHookObjectCompletion;
        kind = @"void_object_completion";
    } else if (strcmp(encoding, "v24@0:8@?16") == 0) {
        replacement = (IMP)XRBHookCompletionOnly;
        kind = @"void_completion";
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
        @[@"XYPHBaseNote", @"modelCustomTransformFromDictionary:"],
        @[@"XYPHBaseNote", @"modelCustomTransformFromDictionary:"],
        @[@"XYPKPostModel", @"noteId"],
        @[@"XYPKPostModel", @"userId"],
        @[@"XYPKPostModel", @"title"],
        @[@"XYPKPostModel", @"desc"],
        @[@"XYPKPostModel", @"likedCount"],
        @[@"XYPKPostModel", @"commentsCount"],
        @[@"XYPKPostModel", @"imagesList"],
        @[@"XYPKPostModel", @"video"],
        @[@"XYPKVideoSegmentModel", @"videoInfo"],
        @[@"XYPKVideoSegmentModel", @"videoURL"],
        @[@"XYPKVideoSegmentModel", @"videoURLs"],
        @[@"XYPKRouteBusinessImageInfo", @"url"],
        @[@"XYPKPreDownloadResourceModel", @"url"],
        @[@"XYPHNoteImageInfo", @"fileId"],
        @[@"XYPHNoteImageInfo", @"url"],
        @[@"XYPHNoteImageInfo", @"livePhotoVideoFileId"],
        @[@"XYPHNoteImageInfo", @"livePhotoVideoUrl"],
        @[@"XYPHNoteImageInfo", @"livePhotoVideoInfo"],
        @[@"_TtC11XYNoteBasic7IBAsset", @"livePhotoVideoFileId"],
        @[@"_TtC11XYNoteBasic7IBAsset", @"livePhotoVideoURL"],
        @[@"_TtC11XYNoteBasic7IBAsset", @"livePhotoImageURL"],
        @[@"MediaBrowserBridgeInputParams", @"note_data"],
        @[@"MediaBrowserBridgeInputParams", @"media_data"],
        @[@"MediaBrowserNoteInfo", @"id"],
        @[@"MediaBrowserItemInfo", @"url"],
        @[@"MediaBrowserItemInfo", @"original_url"],
        @[@"MediaBrowserItemInfo", @"browserItemUrl"],
        @[@"MediaBrowserItemInfo", @"browserItemOriginUrl"],
        @[@"MediaBrowserItemInfo", @"browserItemFileId"],
        @[@"XYMediaModel", @"video"],
        @[@"XYMediaModel", @"videoUrl"],
        @[@"XYMediaModel", @"videoData"],
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
    ];
    for (NSArray<NSString *> *target in targets) {
        XRBInstallBusinessHook(target[0], target[1]);
    }
}

static BOOL XRBShouldScanMediaClass(Class cls) {
    NSString *name = NSStringFromClass(cls) ?: @"";
    if (name.length == 0 || [name hasPrefix:@"XHS"]) return NO;
    NSArray<NSString *> *exactOrScopedNames = @[
        @"MediaBrowserBridgeInputParams",
        @"MediaBrowserNoteInfo",
        @"MediaBrowserItemInfo",
        @"XYMediaModel",
        @"XYMediaBrowser",
        @"XYMediaBrowserViewModel",
        @"XYPBPhotoBrowser",
        @"XYPKPostModel",
        @"XYPKVideoSegmentModel",
        @"XYPKRouteBusinessImageInfo",
        @"XYPKPreDownloadResourceModel"
    ];
    for (NSString *candidate in exactOrScopedNames) {
        if ([name isEqualToString:candidate] ||
            [name containsString:candidate]) {
            return YES;
        }
    }
    return NO;
}

static void XRBInstallMediaFieldHooks(void) {
    NSArray<NSString *> *selectors = @[
        @"contentNoteModel",
        @"imagesList",
        @"videoURLs",
        @"videoURL",
        @"videoInfo",
        @"sourcesWithPrimaryURL:context:",
        @"setVideoInfo:",
        @"setVideoURL:",
        @"setVideoURLs:",
        @"setNote:",
        @"setViewModel:",
        @"setModel:",
        @"setData:",
        @"setContentModel:",
        @"model",
        @"viewModel",
        @"contentModel",
        @"setCellViewModelList:",
        @"note_data", @"media_data", @"cur_position", @"context", @"scene",
        @"original_url", @"url", @"media_type", @"uniqueId",
        @"browserItemUrl", @"browserItemOriginUrl", @"browserItemFileId",
        @"livePhotoVideoPath", @"image", @"video", @"imageData",
        @"originalURL", @"mediaType", @"uniqueID",
        @"browserItemURL", @"browserItemOriginURL", @"browserItemFileID",
        @"imageURL", @"photoURL", @"largeImageURL",
        @"videoData", @"videoDataInfo", @"videoUrl", @"identifier",
        @"noteId", @"noteID", @"userId", @"userID", @"title", @"desc",
        @"likedCount", @"commentsCount", @"collectedCount", @"shareCount",
        @"likeCount", @"commentCount", @"collectCount", @"sharedCount",
        @"interactInfo", @"interactionInfo", @"isLiked", @"isCollected",
        @"cellViewModelList",
        @"downloadButtonTapped:",
        @"mediaBrowserViewModelDidClickDownloadButtonAtIndex:index:"
    ];
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (!XRBShouldScanMediaClass(cls)) continue;
        NSString *className = NSStringFromClass(cls);
        for (NSString *selectorName in selectors) {
            XRBInstallBusinessHook(className, selectorName);
        }
        if ([className containsString:@"MediaBrowserNoteInfo"] ||
            [className containsString:@"MediaBrowserItemInfo"]) {
            XRBInstallBusinessHook(className, @"id");
        }
    }
    free(classes);
}

static void XRBRescanBusinessHooks(void) {
    XRBInstallBusinessHooks();
    XRBInstallMediaFieldHooks();
    XRBInstallURLSessionDelegateObservation();
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
    BOOL isNoteDetail = XRBIsLikelyNoteRequest(URL);
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
