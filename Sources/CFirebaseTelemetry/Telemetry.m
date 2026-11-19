#import "CFirebaseTelemetry.h"
#import <FirebaseAnalytics/FIRAnalytics.h>
#import <FirebaseCore/FIRApp.h>
#import <FirebaseCrashlytics/FIRCrashlytics.h>

// Called by the app delegate and SwiftUI navigation on the main thread.
static BOOL configured = NO;

void LiLiteConfigureFirebase(void) {
  if (configured || ![NSBundle.mainBundle URLForResource:@"GoogleService-Info" withExtension:@"plist"]) {
    return;
  }
  [FIRApp configure];
  configured = YES;
}

void LiLiteRecordTab(const char *name) {
  if (!configured) return;
  NSString *tab = [NSString stringWithUTF8String:name];
  // Off the main thread: Crashlytics writes the key and the analytics breadcrumb to its files
  // synchronously, which cost a dropped frame on every tab switch.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    [FIRAnalytics logEventWithName:@"screen_view"
                        parameters:@{@"screen_name": tab, @"screen_class": @"MainTab"}];
    [[FIRCrashlytics crashlytics] setCustomValue:tab forKey:@"main_tab"];
  });
}
