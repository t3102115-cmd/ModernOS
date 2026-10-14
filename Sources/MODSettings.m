#import "MODSettings.h"
#include <notify.h>

NSString *const MODPreferencesDomain = @"com.modernos.prefs";
NSString *const MODPreferencesChangedNotification = @"com.modernos.prefs/changed";

static MODSettings *sCurrent;

static id MODPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)MODPreferencesDomain));
}

static BOOL MODBool(NSString *key, BOOL fallback) {
    id value = MODPref(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger MODInteger(NSString *key, NSInteger fallback) {
    id value = MODPref(key);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static double MODDouble(NSString *key, double fallback, double minimum, double maximum) {
    id value = MODPref(key);
    if (![value respondsToSelector:@selector(doubleValue)]) return fallback;
    double d = [value doubleValue];
    return (d >= minimum && d <= maximum) ? d : fallback;
}

@implementation MODSettings {
    BOOL _modules[MODModuleCount];
}

+ (instancetype)current {
    if (!sCurrent) sCurrent = [[self alloc] initFromPreferences];
    return sCurrent;
}

+ (void)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)MODPreferencesDomain);
    MODSettings *fresh = [[self alloc] initFromPreferences];
    dispatch_block_t publish = ^{
        sCurrent = fresh;
        [[NSNotificationCenter defaultCenter] postNotificationName:MODPreferencesChangedNotification object:fresh];
    };
    if ([NSThread isMainThread]) publish(); else dispatch_async(dispatch_get_main_queue(), publish);
}

static void MODPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    [MODSettings reload];
}

+ (void)startObservingChanges {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, MODPreferencesChanged,
                                        (__bridge CFStringRef)MODPreferencesChangedNotification, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    });
}

+ (MODCGConfig)crashGuardConfig {
    MODCGConfig config = MODCGDefaultConfig();
    config.threshold = (int)MODInteger(@"cgThreshold", config.threshold);
    config.windowSeconds = (int)MODInteger(@"cgWindowSeconds", config.windowSeconds);
    config.stableSeconds = (int)MODInteger(@"cgStableSeconds", config.stableSeconds);
    return MODCGSanitizedConfig(config);
}

+ (BOOL)masterEnabled {
    return MODBool(@"enabled", YES);
}

+ (BOOL)exitSafeModeRequested {
    return MODBool(@"exitSafeMode", NO);
}

+ (void)clearExitSafeModeRequest {
    CFPreferencesSetAppValue(CFSTR("exitSafeMode"), kCFBooleanFalse, (__bridge CFStringRef)MODPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)MODPreferencesDomain);
}

+ (void)publishStatus:(NSString *)status {
    NSString *previous = MODPref(@"crashGuardStatus");
    if ([previous isEqualToString:status]) return;   // avoid needless cfprefsd writes
    CFPreferencesSetAppValue(CFSTR("crashGuardStatus"), (__bridge CFStringRef)status, (__bridge CFStringRef)MODPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)MODPreferencesDomain);
}

- (instancetype)initFromPreferences {
    if ((self = [super init])) {
        _enabled = MODBool(@"enabled", YES);
        _modules[MODModuleControlCenter] = MODBool(@"ccEnabled", YES);
        _modules[MODModuleLockScreen] = MODBool(@"lockEnabled", YES);
        _modules[MODModuleWidgets] = MODBool(@"widgetsEnabled", YES);
        _modules[MODModuleNotifications] = MODBool(@"notificationsEnabled", YES);
        _modules[MODModuleSwitcher] = MODBool(@"switcherEnabled", YES);
        _animationsEnabled = MODBool(@"animationsEnabled", YES);
        _reducedMotion = MODBool(@"reducedMotion", NO) || UIAccessibilityIsReduceMotionEnabled();
        _darkAppearance = MODInteger(@"appearance", 0) == 0;
        _accentIndex = MODInteger(@"accent", 0);
        _ccPullDown = MODBool(@"ccPullDown", YES);
        _lockShowBattery = MODBool(@"lockBattery", YES);
        _lockModernClock = MODBool(@"lockModernClock", YES);
        _lockCustomWallpaper = MODBool(@"lockCustomWallpaper", NO);
        _switcherRoundedCards = MODBool(@"switcherRoundedCards", YES);
        _switcherReduceBlur = MODBool(@"switcherReduceBlur", YES);
        _switcherHomeButton = MODBool(@"switcherHomeButton", YES);
        _switcherClearAll = MODBool(@"switcherClearAll", YES);
        _switcherCardShadows = MODBool(@"switcherCardShadows", YES);
        _weatherEnabled = MODBool(@"weatherEnabled", NO);
        _weatherLatitude = MODDouble(@"weatherLatitude", 47.37, -90, 90);
        _weatherLongitude = MODDouble(@"weatherLongitude", 8.54, -180, 180);
        _weatherFahrenheit = MODBool(@"weatherFahrenheit", NO);

        NSString *shortcuts = MODPref(@"shortcutApps");
        if (![shortcuts isKindOfClass:[NSString class]] || shortcuts.length == 0) {
            shortcuts = @"com.apple.mobilesafari,com.apple.MobileSMS,com.apple.mobilemail,com.apple.Preferences";
        }
        NSMutableArray *ids = [NSMutableArray array];
        for (NSString *part in [shortcuts componentsSeparatedByString:@","]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length && ids.count < 4) [ids addObject:trimmed];
        }
        _shortcutBundleIDs = [ids copy];
    }
    return self;
}

- (BOOL)isModuleEnabled:(MODModule)module {
    return _enabled && module >= 0 && module < MODModuleCount && _modules[module];
}

@end
