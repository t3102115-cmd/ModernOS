// Private iOS 9.3.6 interfaces used by ModernOS.
//
// Every selector here was verified against the device: SpringBoard classes from
// the ObjC metadata of /System/Library/CoreServices/SpringBoard.app/SpringBoard
// (iOS 9.3.6, 13G37, armv7), shared-cache classes with a runtime probe on the
// device. Hooked selectors are additionally re-verified at runtime (class,
// selector and exact type encoding) before any hook is installed; see
// MODHookSpec in Tweak.xm. Never call these unless the class exists.

#import <UIKit/UIKit.h>

@class BBBulletin, SBDisplayItem;

#pragma mark - SpringBoard

@interface SpringBoard : UIApplication
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (int)activeInterfaceOrientation;
@end

@interface SBUIController : NSObject
+ (instancetype)sharedInstanceIfExists;
- (int)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
- (BOOL)isBatteryCharging;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)displayName;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)identifier;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)nowPlayingApplication;
- (NSDictionary *)_nowPlayingInfo;
- (BOOL)isPlaying;
- (BOOL)hasTrack;
- (BOOL)togglePlayPause;
- (BOOL)changeTrack:(int)direction;
- (float)volume;
- (void)setVolume:(float)volume;
- (BOOL)suppressHUD;
- (void)setSuppressHUD:(BOOL)suppress;
@end

@interface SBBrightnessController : NSObject
+ (instancetype)sharedBrightnessController;
- (void)_setBrightnessLevel:(float)level showHUD:(BOOL)showHUD;
@end

@class SBLockScreenView;

@interface SBLockScreenViewController : UIViewController
- (SBLockScreenView *)lockScreenView;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstanceIfExists;
- (BOOL)isUILocked;
- (SBLockScreenViewController *)lockScreenViewController;
@end

@interface SBControlCenterController : UIViewController
+ (instancetype)sharedInstanceIfExists;
- (BOOL)isVisible;
- (BOOL)isPresented;
@end

// Control Center modules (base class SBCCButtonModule). Instances are plain
// model objects that perform the real system action in -toggleState.
@protocol SBCCButtonModuleDelegate <NSObject>
- (void)buttonModuleStateDidChange:(id)module;
- (void)buttonModulePropertiesDidChange:(id)module;
@end

@interface SBCCButtonModule : NSObject
+ (BOOL)isSupported:(int)deviceType;
@property (nonatomic, weak) id<SBCCButtonModuleDelegate> delegate;
- (void)activate;
- (void)deactivate;
- (void)warmup;
- (void)cooldown;
- (int)state;
- (BOOL)isEnabled;
- (BOOL)isRestricted;
- (BOOL)isInoperative;
- (void)toggleState;
- (BOOL)needsConfirmation;
- (NSString *)confirmationAlertTitle;
- (NSString *)confirmationAlertMessage;
- (void)confirmed:(BOOL)confirmed;
- (NSString *)displayName;
- (UIImage *)glyphImageForState:(int)state;
@end

@interface SBDisplayItem : NSObject
+ (instancetype)homeScreenDisplayItem;
- (BOOL)isHomeScreenDisplayItem;
@end

@interface SBMainSwitcherViewController : UIViewController
+ (instancetype)sharedInstance;
- (BOOL)isVisible;
- (void)setReturnToDisplayItem:(SBDisplayItem *)item;
- (BOOL)dismissSwitcherNoninteractively;
@end

@interface SBDeckSwitcherItemContainer : UIView
- (CGFloat)contentCornerRadiusProgress;
- (void)setContentCornerRadiusProgress:(CGFloat)progress;
@end

@interface SBDeckSwitcherViewController : UIViewController
- (NSArray *)_visibleItemContainers;
@end

@interface SBLockScreenView : UIView
- (UIView *)dateView;
- (UIView *)foregroundView;
- (UIView *)notificationView;
@end

@interface SBAwayListItem : NSObject
@end

@interface SBAwayBulletinListItem : SBAwayListItem
- (BBBulletin *)activeBulletin;
- (NSString *)message;
- (UIImage *)iconImage;
- (NSDate *)date;
@end

@interface SBLockScreenNotificationListController : UIViewController
- (unsigned)count;
- (id)listItemAtIndexPath:(NSIndexPath *)indexPath;
@end

#pragma mark - SpringBoardFoundation (shared cache, probe-verified)

@interface SBFLockScreenDateView : UIView
- (void)updateFormat;
@end

#pragma mark - BulletinBoard (shared cache, probe-verified)

@interface BBAction : NSObject
- (NSURL *)launchURL;
- (NSString *)bundleID;
@end

@interface BBBulletin : NSObject
- (NSString *)bulletinID;
- (NSString *)sectionID;
- (NSString *)title;
- (NSString *)subtitle;
- (NSString *)message;
- (NSDate *)date;
- (BBAction *)defaultAction;
@end

#pragma mark - UIKit private (probe-verified)

@interface UIImage (MODPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

@interface UIWindow (MODPrivate)
+ (BOOL)_isSecure;
@end
