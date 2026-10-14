#import <UIKit/UIKit.h>

extern NSString *const MODNowPlayingDidChangeNotification;   // relayed SBMediaNowPlayingChangedNotification

@interface MODNowPlayingInfo : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *appBundleID;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, strong) NSData *artworkData;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, readonly) BOOL hasContent;
@end

// Thin, defensive wrappers around verified iOS 9.3.6 SpringBoard APIs. Every
// call checks that the class/selector exists and degrades to a safe no-op.
@interface MODSystemAdapters : NSObject

// Lock state
+ (BOOL)isDeviceLocked;

// Applications
+ (NSString *)displayNameForBundleID:(NSString *)bundleID;
+ (UIImage *)iconForBundleID:(NSString *)bundleID;   // small icon, cached (bounded)
// Opens an app or URL now; returns NO if nothing could be launched.
+ (BOOL)openBundleID:(NSString *)bundleID URL:(NSURL *)url;
// Opens after the user unlocks with the native lock screen (never bypasses
// authentication). Replaces any previous pending request; expires after 60 s.
+ (void)openAfterUnlockBundleID:(NSString *)bundleID URL:(NSURL *)url;
+ (BOOL)hasPendingOpen;
+ (void)deviceDidUnlock;   // called by the coordinator from the unlock hook
+ (void)cancelPendingOpen;

// Battery
+ (NSInteger)batteryPercent;   // -1 if unknown
+ (BOOL)isCharging;

// Brightness and volume
+ (float)brightness;
+ (void)setBrightness:(float)value;
+ (float)volume;
+ (void)setVolume:(float)value;
+ (void)setVolumeHUDSuppressed:(BOOL)suppressed;

// Media
+ (MODNowPlayingInfo *)nowPlaying;
+ (void)togglePlayPause;
+ (void)skipTrack:(int)direction;

// Orientation of the SpringBoard UI (YES when the user interface is portrait).
+ (BOOL)isPortraitInterface;

// Switcher
+ (BOOL)dismissSwitcherToHome;

+ (void)purgeCaches;

@end
