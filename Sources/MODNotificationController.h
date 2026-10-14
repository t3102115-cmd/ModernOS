#import "MODCoordinator.h"

@class SBLockScreenNotificationListController;

// Grouped lock-screen notifications.
//
// Source of truth stays the native SBLockScreenNotificationListController:
// ModernOS never intercepts, delays, duplicates or removes bulletin delivery.
// After the native controller updates its model, ModernOS reads the native
// list items (already filtered for "Show on Lock Screen" and message privacy)
// and renders them grouped by app. Sounds, vibration, screen wake, realerts and
// Notification Center are untouched.
@interface MODNotificationController : NSObject <MODModuleController>

// From hooks on the native list controller (after %orig).
- (void)nativeListDidChange:(SBLockScreenNotificationListController *)listController;

// The grouped view to show in place of the native list, or nil when the native
// list must stay visible (no items, or an item type ModernOS cannot render).
- (UIView *)groupedViewForDisplay;

@end
