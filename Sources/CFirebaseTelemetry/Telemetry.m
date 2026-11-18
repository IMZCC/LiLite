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
  [FIRAnalytics logEventWithName:@"screen_view"
                      parameters:@{@"screen_name": tab, @"screen_class": @"MainTab"}];
  [[FIRCrashlytics crashlytics] setCustomValue:tab forKey:@"main_tab"];
}
