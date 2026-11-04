#import <UIKit/UIKit.h>

#import "XHSRuntimeLogger.h"

@interface XRBSettingsController : NSObject

@property(nonatomic, strong) UIWindow *window;

+ (instancetype)shared;
- (void)installButton;
- (void)presentSettings;

@end

static UIWindow *XRBActiveWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) return window;
            }
            UIWindow *first = ((UIWindowScene *)scene).windows.firstObject;
            if (first) return first;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UIViewController *XRBTopController(UIViewController *controller) {
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return XRBTopController(
            ((UINavigationController *)controller).topViewController
        );
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return XRBTopController(
            ((UITabBarController *)controller).selectedViewController
        );
    }
    return controller;
}

@implementation XRBSettingsController

+ (instancetype)shared {
    static XRBSettingsController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)installButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.window) return;

        UIWindow *hostWindow = XRBActiveWindow();
        if (!hostWindow) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{ [self installButton]; }
            );
            return;
        }

        CGRect frame = CGRectMake(
            CGRectGetWidth(hostWindow.bounds) - 62,
            CGRectGetHeight(hostWindow.bounds) - 140,
            48,
            48
        );
        UIWindow *overlay = [[UIWindow alloc] initWithFrame:frame];
        if (@available(iOS 13.0, *)) {
            overlay.windowScene = hostWindow.windowScene;
        }
        overlay.backgroundColor = UIColor.clearColor;
        overlay.windowLevel = UIWindowLevelAlert + 1;
        overlay.rootViewController = [UIViewController new];
        overlay.rootViewController.view.backgroundColor = UIColor.clearColor;

        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = overlay.bounds;
        button.layer.cornerRadius = 24;
        button.backgroundColor =
            [UIColor colorWithWhite:0.1 alpha:0.72];
        [button setTitle:@"⚙" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor
                     forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBold];
        [button addTarget:self
                   action:@selector(showSettings:)
         forControlEvents:UIControlEventTouchUpInside];
        [overlay.rootViewController.view addSubview:button];
        overlay.hidden = NO;
        self.window = overlay;
    });
}

- (void)showSettings:(id)sender {
    (void)sender;
    [self presentSettings];
}

- (void)presentSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hostWindow = XRBActiveWindow();
        UIViewController *root = hostWindow.rootViewController;
        if (!root) return;

        NSDictionary *settings = XRBCurrentSettings();
        UIAlertController *alert = [
            UIAlertController alertControllerWithTitle:@"XHS Runtime Bridge"
            message:@"配置 Windows 日志接收器"
            preferredStyle:UIAlertControllerStyleAlert
        ];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"http://电脑IP:17321/events";
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.text = settings[@"endpoint"];
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"Collector Token";
            field.secureTextEntry = YES;
            field.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.text = settings[@"token"];
        }];
        [alert addAction:[
            UIAlertAction actionWithTitle:@"取消"
            style:UIAlertActionStyleCancel
            handler:nil
        ]];
        [alert addAction:[
            UIAlertAction actionWithTitle:@"停止推送"
            style:UIAlertActionStyleDestructive
            handler:^(__unused UIAlertAction *action) {
                XRBSaveSettings(
                    settings[@"endpoint"],
                    settings[@"token"],
                    NO
                );
            }
        ]];
        [alert addAction:[
            UIAlertAction actionWithTitle:@"保存"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                NSString *endpoint = alert.textFields[0].text ?: @"";
                NSString *token = alert.textFields[1].text ?: @"";
                XRBSaveSettings(endpoint, token, YES);
                XRBLogEvent(@"settings_updated", @{
                    @"endpoint_configured": @(endpoint.length > 0),
                    @"token_configured": @(token.length > 0)
                });
            }
        ]];
        [XRBTopController(root) presentViewController:alert
                                             animated:YES
                                           completion:nil];
    });
}

@end

void XRBInstallSettingsUI(void) {
    [[XRBSettingsController shared] installButton];
}
