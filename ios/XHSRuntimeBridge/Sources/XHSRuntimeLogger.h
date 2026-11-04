#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the logger, loads configuration and creates the local fallback file.
void XRBStartLogger(void);

/// Enqueues one structured event. This function is safe to call from any thread.
void XRBLogEvent(NSString *event, NSDictionary<NSString *, id> * _Nullable fields);

/// Returns YES for the collector's own requests so network hooks can ignore them.
BOOL XRBIsCollectorRequest(NSURLRequest *request);

/// The in-app settings UI reads and writes these values through NSUserDefaults.
NSDictionary<NSString *, id> *XRBCurrentSettings(void);
BOOL XRBSaveSettings(
    NSString * _Nullable endpoint,
    NSString * _Nullable token,
    BOOL enabled
);

NS_ASSUME_NONNULL_END
