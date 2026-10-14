#import <Foundation/Foundation.h>
#import "MODCrashGuardCore.h"

// Preference domain written by the Settings app (PreferenceLoader plist) and
// read by SpringBoard through cfprefsd.
extern NSString *const MODPreferencesDomain;            // com.modernos.prefs
extern NSString *const MODPreferencesChangedNotification; // Darwin + NSNotification name

typedef NS_ENUM(NSInteger, MODModule) {
    MODModuleControlCenter = 0,
    MODModuleLockScreen = 1,
    MODModuleWidgets = 2,
    MODModuleNotifications = 3,
    MODModuleSwitcher = 4,
};
#define MODModuleCount 5

// Snapshot of the user's settings. Immutable; MODSettings publishes a new
// instance on every change so readers never observe a half-updated state.
@interface MODSettings : NSObject

+ (instancetype)current;
// Re-reads preferences; posts MODPreferencesChangedNotification on the main thread.
+ (void)reload;
// Starts listening for the Darwin notification posted by the Settings app.
+ (void)startObservingChanges;
// Reads only what the crash guard needs; safe to call from the constructor.
+ (MODCGConfig)crashGuardConfig;
+ (BOOL)masterEnabled;
+ (BOOL)exitSafeModeRequested;
+ (void)clearExitSafeModeRequest;
// Mirrors crash-guard status into the preference domain so Settings can show it.
+ (void)publishStatus:(NSString *)status;

@property (nonatomic, readonly) BOOL enabled;
- (BOOL)isModuleEnabled:(MODModule)module;

@property (nonatomic, readonly) BOOL animationsEnabled;
@property (nonatomic, readonly) BOOL reducedMotion;
@property (nonatomic, readonly) BOOL darkAppearance;
@property (nonatomic, readonly) NSInteger accentIndex;

// Top-edge pull-down opens Control Center instead of Notification Center
// (Notification Center is suppressed, not removed: turn this off to restore it).
@property (nonatomic, readonly) BOOL ccPullDown;
@property (nonatomic, readonly) BOOL lockShowBattery;
@property (nonatomic, readonly) BOOL lockModernClock;
@property (nonatomic, readonly) BOOL lockCustomWallpaper;
@property (nonatomic, readonly) BOOL switcherRoundedCards;
@property (nonatomic, readonly) BOOL switcherReduceBlur;
@property (nonatomic, readonly) BOOL switcherHomeButton;
@property (nonatomic, readonly) BOOL switcherClearAll;
@property (nonatomic, readonly) BOOL switcherCardShadows;

@property (nonatomic, readonly) BOOL weatherEnabled;
@property (nonatomic, readonly) double weatherLatitude;
@property (nonatomic, readonly) double weatherLongitude;
@property (nonatomic, readonly) BOOL weatherFahrenheit;
@property (nonatomic, readonly, copy) NSArray<NSString *> *shortcutBundleIDs;

@end
