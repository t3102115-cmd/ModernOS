#import "MODCoordinator.h"

@class SBLockScreenView;

// Decorates the stock iOS 9 lock screen. Nothing here touches authentication:
// the passcode page, slide-to-unlock, emergency call and unlock handling stay
// entirely native. ModernOS only restyles the clock and lays out its own views
// in the notification region.
@interface MODLockScreenController : NSObject <MODModuleController>

// SBFLockScreenDateView hooks.
- (UIFont *)timeFontForOriginal:(UIFont *)original;
- (UIFont *)dateFontForOriginal:(UIFont *)original;
- (void)dateViewDidLayout:(UIView *)dateView;

// Called after -[SBLockScreenView _layoutNotificationView]. Lays out the region
// below the clock (battery/widgets accessory row plus either the grouped
// notifications or the inset native list) and the optional custom wallpaper.
// A class method because it also serves the notifications module when the
// lock screen module is off, and must clean up when both are inactive.
+ (void)lockScreenViewDidLayout:(SBLockScreenView *)lockScreenView;

// Asks SpringBoard to lay the lock screen out again (after settings change).
+ (void)relayoutLockScreen;

@end
