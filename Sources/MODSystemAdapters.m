#import "MODSystemAdapters.h"
#import "MODPrivate.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

NSString *const MODNowPlayingDidChangeNotification = @"MODNowPlayingDidChangeNotification";

#define MODShared(className, selectorName) MODSharedInstance(className, @selector(selectorName))

static id MODSharedInstance(const char *className, SEL selector) {
    Class cls = objc_getClass(className);
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static BOOL MODResponds(id object, SEL selector) {
    return object && [object respondsToSelector:selector];
}

// MediaRemote string constants, resolved once (symbols verified on device).
static NSString *MODMediaKey(const char *symbol, NSString *fallback) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_NOLOAD);
    CFStringRef *ptr = handle ? (CFStringRef *)dlsym(handle, symbol) : NULL;
    return ptr && *ptr ? (__bridge NSString *)*ptr : fallback;
}

@implementation MODNowPlayingInfo
- (BOOL)hasContent { return self.title.length > 0 || self.appBundleID.length > 0; }
@end

static NSCache *sIconCache;
static NSString *sPendingBundleID;
static NSURL *sPendingURL;
static NSDate *sPendingDate;

@implementation MODSystemAdapters

#pragma mark - Lock state

+ (BOOL)isDeviceLocked {
    SBLockScreenManager *manager = MODShared("SBLockScreenManager", sharedInstanceIfExists);
    return MODResponds(manager, @selector(isUILocked)) ? [manager isUILocked] : NO;
}

#pragma mark - Applications

+ (SBApplication *)applicationForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    SBApplicationController *controller = MODShared("SBApplicationController", sharedInstance);
    return MODResponds(controller, @selector(applicationWithBundleIdentifier:)) ? [controller applicationWithBundleIdentifier:bundleID] : nil;
}

+ (NSString *)displayNameForBundleID:(NSString *)bundleID {
    SBApplication *app = [self applicationForBundleID:bundleID];
    NSString *name = MODResponds(app, @selector(displayName)) ? [app displayName] : nil;
    return name.length ? name : bundleID;
}

+ (UIImage *)iconForBundleID:(NSString *)bundleID {
    if (!bundleID.length || ![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    if (!sIconCache) {
        sIconCache = [NSCache new];
        sIconCache.countLimit = 24;   // ~24 small icons (each ~ 58x58 px)
    }
    UIImage *icon = [sIconCache objectForKey:bundleID];
    if (!icon) {
        // Format 0 = small (29 pt) icon; plenty for headers and shortcut chips.
        icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
        if (icon) [sIconCache setObject:icon forKey:bundleID];
    }
    return icon;
}

+ (BOOL)openBundleID:(NSString *)bundleID URL:(NSURL *)url {
    UIApplication *app = [UIApplication sharedApplication];
    if (url && [app canOpenURL:url]) {
        [app openURL:url];
        return YES;
    }
    if (bundleID.length && [self applicationForBundleID:bundleID] && MODResponds(app, @selector(launchApplicationWithIdentifier:suspended:))) {
        return [(SpringBoard *)app launchApplicationWithIdentifier:bundleID suspended:NO];
    }
    return NO;
}

+ (void)openAfterUnlockBundleID:(NSString *)bundleID URL:(NSURL *)url {
    if (![self isDeviceLocked]) {
        [self openBundleID:bundleID URL:url];
        return;
    }
    sPendingBundleID = [bundleID copy];
    sPendingURL = url;
    sPendingDate = [NSDate date];
}

+ (BOOL)hasPendingOpen {
    return sPendingDate && -[sPendingDate timeIntervalSinceNow] < 60;
}

+ (void)cancelPendingOpen {
    sPendingBundleID = nil;
    sPendingURL = nil;
    sPendingDate = nil;
}

+ (void)deviceDidUnlock {
    if (![self hasPendingOpen]) {
        [self cancelPendingOpen];
        return;
    }
    NSString *bundleID = sPendingBundleID;
    NSURL *url = sPendingURL;
    [self cancelPendingOpen];
    // Let the native unlock transition finish before launching.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self isDeviceLocked]) [self openBundleID:bundleID URL:url];
    });
}

#pragma mark - Battery

+ (NSInteger)batteryPercent {
    SBUIController *ui = MODShared("SBUIController", sharedInstanceIfExists);
    if (MODResponds(ui, @selector(batteryCapacityAsPercentage))) return [ui batteryCapacityAsPercentage];
    UIDevice *device = [UIDevice currentDevice];
    if (!device.batteryMonitoringEnabled) device.batteryMonitoringEnabled = YES;
    return device.batteryLevel < 0 ? -1 : (NSInteger)lroundf(device.batteryLevel * 100);
}

+ (BOOL)isCharging {
    SBUIController *ui = MODShared("SBUIController", sharedInstanceIfExists);
    if (MODResponds(ui, @selector(isBatteryCharging))) return [ui isBatteryCharging] || ([ui isOnAC] && [self batteryPercent] >= 100);
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

#pragma mark - Brightness and volume

+ (float)brightness {
    return (float)[UIScreen mainScreen].brightness;
}

+ (void)setBrightness:(float)value {
    value = MIN(1.f, MAX(0.f, value));
    SBBrightnessController *controller = MODShared("SBBrightnessController", sharedBrightnessController);
    if (MODResponds(controller, @selector(_setBrightnessLevel:showHUD:))) {
        [controller _setBrightnessLevel:value showHUD:NO];
    } else {
        [UIScreen mainScreen].brightness = value;
    }
}

+ (float)volume {
    SBMediaController *media = MODShared("SBMediaController", sharedInstance);
    return MODResponds(media, @selector(volume)) ? [media volume] : 0;
}

+ (void)setVolume:(float)value {
    SBMediaController *media = MODShared("SBMediaController", sharedInstance);
    if (MODResponds(media, @selector(setVolume:))) [media setVolume:MIN(1.f, MAX(0.f, value))];
}

+ (void)setVolumeHUDSuppressed:(BOOL)suppressed {
    SBMediaController *media = MODShared("SBMediaController", sharedInstance);
    if (MODResponds(media, @selector(setSuppressHUD:))) [media setSuppressHUD:suppressed];
}

#pragma mark - Media

+ (MODNowPlayingInfo *)nowPlaying {
    static NSString *kTitle, *kArtist, *kAlbum, *kArtwork;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kTitle = MODMediaKey("kMRMediaRemoteNowPlayingInfoTitle", @"kMRMediaRemoteNowPlayingInfoTitle");
        kArtist = MODMediaKey("kMRMediaRemoteNowPlayingInfoArtist", @"kMRMediaRemoteNowPlayingInfoArtist");
        kAlbum = MODMediaKey("kMRMediaRemoteNowPlayingInfoAlbum", @"kMRMediaRemoteNowPlayingInfoAlbum");
        kArtwork = MODMediaKey("kMRMediaRemoteNowPlayingInfoArtworkData", @"kMRMediaRemoteNowPlayingInfoArtworkData");
    });
    MODNowPlayingInfo *info = [MODNowPlayingInfo new];
    SBMediaController *media = MODShared("SBMediaController", sharedInstance);
    if (!media) return info;
    SBApplication *app = MODResponds(media, @selector(nowPlayingApplication)) ? [media nowPlayingApplication] : nil;
    info.appBundleID = MODResponds(app, @selector(bundleIdentifier)) ? [app bundleIdentifier] : nil;
    info.appName = MODResponds(app, @selector(displayName)) ? [app displayName] : nil;
    info.playing = MODResponds(media, @selector(isPlaying)) && [media isPlaying];
    NSDictionary *dict = MODResponds(media, @selector(_nowPlayingInfo)) ? [media _nowPlayingInfo] : nil;
    if ([dict isKindOfClass:[NSDictionary class]]) {
        id title = dict[kTitle], artist = dict[kArtist], album = dict[kAlbum], artwork = dict[kArtwork];
        info.title = [title isKindOfClass:[NSString class]] ? title : nil;
        info.artist = [artist isKindOfClass:[NSString class]] ? artist : nil;
        info.album = [album isKindOfClass:[NSString class]] ? album : nil;
        info.artworkData = [artwork isKindOfClass:[NSData class]] ? artwork : nil;
    }
    return info;
}

+ (void)togglePlayPause {
    SBMediaController *media = MODShared("SBMediaController", sharedInstance);
    if (MODResponds(media, @selector(togglePlayPause))) [media togglePlayPause];
}

+ (void)skipTrack:(int)direction {
    SBMediaController *media = MODShared("SBMediaController", sharedInstance);
    if (MODResponds(media, @selector(changeTrack:))) [media changeTrack:direction > 0 ? 1 : -1];
}

#pragma mark - Orientation and switcher

+ (BOOL)isPortraitInterface {
    SpringBoard *app = (SpringBoard *)[UIApplication sharedApplication];
    if (!MODResponds(app, @selector(activeInterfaceOrientation))) return YES;
    int orientation = [app activeInterfaceOrientation];
    return orientation == UIInterfaceOrientationPortrait || orientation == 0;
}

+ (BOOL)dismissSwitcherToHome {
    SBMainSwitcherViewController *switcher = MODShared("SBMainSwitcherViewController", sharedInstance);
    Class displayItemClass = objc_getClass("SBDisplayItem");
    if (!MODResponds(switcher, @selector(setReturnToDisplayItem:)) || !MODResponds(switcher, @selector(dismissSwitcherNoninteractively)) ||
        ![displayItemClass respondsToSelector:@selector(homeScreenDisplayItem)]) {
        return NO;
    }
    if (MODResponds(switcher, @selector(isVisible)) && ![switcher isVisible]) return NO;
    [switcher setReturnToDisplayItem:[displayItemClass homeScreenDisplayItem]];
    return [switcher dismissSwitcherNoninteractively];
}

+ (void)purgeCaches {
    [sIconCache removeAllObjects];
}

@end
