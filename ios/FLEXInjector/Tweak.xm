#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Manager/FLEXManager.h"

// This is intentionally a one-shot bootstrap. It does not hook the target
// application's classes or collect network credentials. After FLEX is
// dismissed, it stays hidden until the next application launch.
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Wait until the application's key window and scene are available.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class managerClass = NSClassFromString(@"FLEXManager");
            if (!managerClass ||
                ![managerClass respondsToSelector:@selector(sharedManager)]) {
                NSLog(@"[FLEXInjector] official FLEX manager unavailable");
                return;
            }

            id manager = [managerClass performSelector:@selector(sharedManager)];
            if ([manager respondsToSelector:@selector(showExplorer)]) {
                NSLog(@"[FLEXInjector] official FLEX loaded");
                [manager performSelector:@selector(showExplorer)];
            }
        });
    });
}
