#import <UIKit/UIKit.h>
#import "MODSettings.h"

@class MODControlCenterController, MODLockScreenController, MODWidgetController,
       MODNotificationController, MODAppSwitcherController;

// Implemented by every feature module.
@protocol MODModuleController <NSObject>
- (void)activate;                 // module becomes visible/usable
- (void)deactivate;               // undo all visible changes, stop observers, release resources
@optional
- (void)settingsDidChange:(MODSettings *)settings;
- (void)didReceiveMemoryWarning;
- (void)deviceDidLock;
- (void)deviceDidUnlock;
@end

// Owns ModernOS's lifecycle inside SpringBoard. Hooks never talk to modules
// directly; they ask the coordinator for an *active* module (nil otherwise),
// so an inactive or faulted module always means "behave natively".
@interface MODCoordinator : NSObject

+ (instancetype)shared;

// Called from the constructor after each hook group was verified and installed.
- (void)noteHooksInstalledForModule:(MODModule)module;
- (BOOL)hooksInstalledForModule:(MODModule)module;

// Called from the -[SpringBoard applicationDidFinishLaunching:] hook.
- (void)springBoardDidFinishLaunchingWithLaunchStart:(CFAbsoluteTime)launchStart;
@property (nonatomic, readonly) BOOL started;

- (BOOL)isModuleActive:(MODModule)module;

// Active module controllers, or nil when the module is inactive.
- (MODControlCenterController *)controlCenter;
- (MODLockScreenController *)lockScreen;
- (MODWidgetController *)widgets;
- (MODNotificationController *)notifications;
- (MODAppSwitcherController *)appSwitcher;

// Hook entry points.
- (BOOL)handleMenuButton;     // YES if a ModernOS panel consumed the Home press
- (void)deviceDidUnlock;

- (void)openWidgetDashboard;  // from Control Center or the lock screen

@end
