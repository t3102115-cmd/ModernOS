// ModernOS — single entry point and the complete hook surface.
//
// Order of operations in the constructor (see %ctor at the bottom):
//   1. Emergency disable file  -> return (nothing hooked, nothing written)
//   2. Master switch off       -> return
//   3. Crash guard launch gate -> anything but ACTIVATE returns immediately:
//      no hooks, no gestures, no windows, no timers, no observers.
//   4. Per hook group: verify class + selector + exact type encoding against
//      iOS 9.3.6, then install. A group that fails verification is skipped and
//      its module stays native.
// Hooks are thin: they always run the original implementation unless an
// *active* ModernOS module explicitly takes over, and every call into ModernOS
// code is exception-contained per module.

#import <objc/runtime.h>
#import "Sources/MODPrivate.h"
#import "Sources/MODCrashGuard.h"
#import "Sources/MODCoordinator.h"
#import "Sources/MODControlCenterController.h"
#import "Sources/MODLockScreenController.h"
#import "Sources/MODNotificationController.h"
#import "Sources/MODAppSwitcherController.h"

static CFAbsoluteTime sLaunchStart;
static BOOL sCCGestureOwned;   // a system gesture that began in ModernOS stays with ModernOS
static BOOL sNCGestureOwned;

// Returns YES when ModernOS owns this gesture (handled now, or began in
// ModernOS): a gesture never leaks half-way into the native panel.
static BOOL MODTrackGestureOwnership(BOOL *owned, UIGestureRecognizerState state, BOOL handled) {
    if (state == UIGestureRecognizerStateBegan) *owned = handled;
    BOOL result = handled || *owned;
    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
        *owned = NO;
    }
    return result;
}

#pragma mark - Hook verification

typedef struct {
    const char *cls;
    const char *sel;
    const char *types;   // exact encoding from the iOS 9.3.6 binaries (armv7)
} MODHookSpec;

static const MODHookSpec kCoreSpecs[] = {
    { "SpringBoard", "applicationDidFinishLaunching:", "v12@0:4@8" },
    { "SBUIController", "clickedMenuButton", "c8@0:4" },
    { "SBLockScreenManager", "_finishUIUnlockFromSource:withOptions:", "v16@0:4i8@12" },
};
static const MODHookSpec kControlCenterSpecs[] = {
    { "SBControlCenterController", "_handleShowControlCenterGesture:", "v12@0:4@8" },
};
static const MODHookSpec kPullDownSpecs[] = {
    { "SBNotificationCenterController", "_handleShowNotificationCenterGesture:", "v12@0:4@8" },
};
static const MODHookSpec kLockClockSpecs[] = {
    { "SBFLockScreenDateView", "_timeFont", "@8@0:4" },
    { "SBFLockScreenDateView", "_dateFont", "@8@0:4" },
    { "SBFLockScreenDateView", "layoutSubviews", "v8@0:4" },
};
static const MODHookSpec kLockRegionSpecs[] = {
    { "SBLockScreenView", "_layoutNotificationView", "v8@0:4" },
};
static const MODHookSpec kNotificationSpecs[] = {
    { "SBLockScreenNotificationListController", "_updateModelAndViewForAdditionOfItem:", "v12@0:4@8" },
    { "SBLockScreenNotificationListController", "_updateModelAndViewForRemovalOfItem:", "v12@0:4@8" },
    { "SBLockScreenNotificationListController", "_updateModelAndViewForModificationOfItem:", "v12@0:4@8" },
    { "SBLockScreenNotificationListController", "_updateModelAndViewForReplacingItem:withNewItem:", "v16@0:4@8@12" },
    { "SBLockScreenNotificationListController", "_updateModelForRemovalOfItem:updateView:", "v16@0:4@8c12" },
    { "SBLockScreenNotificationListController", "removeItemsForUnlock", "c8@0:4" },
    { "SBLockScreenNotificationListController", "viewWillAppear:", "v12@0:4c8" },
    // Read-only accessors used by the module.
    { "SBLockScreenNotificationListController", "count", "I8@0:4" },
    { "SBLockScreenNotificationListController", "listItemAtIndexPath:", "@12@0:4@8" },
};
static const MODHookSpec kSwitcherSpecs[] = {
    { "SBDeckSwitcherViewController", "_blurForIndex:scrollProgress:", "f20@0:4I8d12" },
    { "SBDeckSwitcherViewController", "viewDidAppear:", "v12@0:4c8" },
    { "SBDeckSwitcherViewController", "viewWillDisappear:", "v12@0:4c8" },
    { "SBDeckSwitcherViewController", "_didAddVisibleItemContainer:forDisplayItem:", "v16@0:4@8@12" },
    { "SBDeckSwitcherViewController", "animateDismissalToDisplayItem:forTransitionRequest:withCompletion:", "v20@0:4@8@12@?16" },
    { "SBDeckSwitcherViewController", "_visibleItemContainers", "@8@0:4" },
};

#define MODSpecCount(specs) (sizeof(specs) / sizeof((specs)[0]))

static BOOL MODVerifySpecs(const char *group, const MODHookSpec *specs, size_t count) {
    for (size_t i = 0; i < count; i++) {
        Class cls = objc_getClass(specs[i].cls);
        Method method = cls ? class_getInstanceMethod(cls, sel_registerName(specs[i].sel)) : NULL;
        const char *types = method ? method_getTypeEncoding(method) : NULL;
        if (!cls || !method || !types || strcmp(types, specs[i].types) != 0) {
            NSLog(@"[ModernOS] hook group %s NOT installed: -[%s %s] %s (expected %s)", group, specs[i].cls, specs[i].sel,
                  !cls ? "class missing" : !method ? "selector missing" : types ?: "no types", specs[i].types);
            return NO;
        }
    }
    return YES;
}

#define MODVerify(specs) MODVerifySpecs(#specs, specs, MODSpecCount(specs))

#pragma mark - Core

%group MODCoreHooks

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    @try {
        [[MODCoordinator shared] springBoardDidFinishLaunchingWithLaunchStart:sLaunchStart];
    } @catch (NSException *exception) {
        NSLog(@"[ModernOS] startup failed, staying native: %@", exception);
    }
}
%end

%hook SBUIController
- (BOOL)clickedMenuButton {
    BOOL consumed = NO;
    @try {
        consumed = [[MODCoordinator shared] handleMenuButton];
    } @catch (NSException *exception) {
        NSLog(@"[ModernOS] menu button handling failed: %@", exception);
    }
    return consumed ? YES : %orig;
}
%end

%hook SBLockScreenManager
- (void)_finishUIUnlockFromSource:(int)source withOptions:(id)options {
    %orig;
    @try {
        if (![self isUILocked]) [[MODCoordinator shared] deviceDidUnlock];
    } @catch (NSException *exception) {
        NSLog(@"[ModernOS] unlock handling failed: %@", exception);
    }
}
%end

%end

#pragma mark - Control Center

%group MODControlCenterHooks

%hook SBControlCenterController
- (void)_handleShowControlCenterGesture:(UIGestureRecognizer *)recognizer {
    MODControlCenterController *controller = [[MODCoordinator shared] controlCenter];
    __block BOOL handled = NO;
    if (controller) {
        MODGuarded(MODModuleControlCenter, @"showGesture", ^{ handled = [controller handleShowGesture:recognizer fromTop:NO]; });
    }
    if (!MODTrackGestureOwnership(&sCCGestureOwned, recognizer.state, handled)) %orig;
}
%end

%end

// Top edge: modern pull-down Control Center. Notification Center's gesture
// handler is skipped only while the setting is on and Control Center is active.
%group MODPullDownHooks

%hook SBNotificationCenterController
- (void)_handleShowNotificationCenterGesture:(UIGestureRecognizer *)recognizer {
    MODControlCenterController *controller = [MODSettings current].ccPullDown ? [[MODCoordinator shared] controlCenter] : nil;
    __block BOOL handled = NO;
    if (controller) {
        MODGuarded(MODModuleControlCenter, @"pullDownGesture", ^{ handled = [controller handleShowGesture:recognizer fromTop:YES]; });
    }
    if (!MODTrackGestureOwnership(&sNCGestureOwned, recognizer.state, handled)) %orig;
}
%end

%end

#pragma mark - Lock screen

%group MODLockClockHooks

%hook SBFLockScreenDateView
- (UIFont *)_timeFont {
    UIFont *font = %orig;
    MODLockScreenController *lock = [[MODCoordinator shared] lockScreen];
    __block UIFont *result = font;
    if (lock) MODGuarded(MODModuleLockScreen, @"timeFont", ^{ result = [lock timeFontForOriginal:font]; });
    return result ?: font;
}

- (UIFont *)_dateFont {
    UIFont *font = %orig;
    MODLockScreenController *lock = [[MODCoordinator shared] lockScreen];
    __block UIFont *result = font;
    if (lock) MODGuarded(MODModuleLockScreen, @"dateFont", ^{ result = [lock dateFontForOriginal:font]; });
    return result ?: font;
}

- (void)layoutSubviews {
    %orig;
    MODLockScreenController *lock = [[MODCoordinator shared] lockScreen];
    if (lock) MODFirstUse(MODModuleLockScreen, @"dateLayout", ^{ [lock dateViewDidLayout:self]; });
}
%end

%end

%group MODLockRegionHooks

%hook SBLockScreenView
- (void)_layoutNotificationView {
    %orig;
    if (![MODCoordinator shared].started) return;
    @try {
        [MODLockScreenController lockScreenViewDidLayout:(SBLockScreenView *)self];
    } @catch (NSException *exception) {
        NSLog(@"[ModernOS] lock screen layout failed: %@", exception);
        [MODCrashGuard recordFaultInModule:MODModuleLockScreen reason:exception.reason ?: @"layout"];
        [MODCrashGuard recordFaultInModule:MODModuleNotifications reason:exception.reason ?: @"layout"];
        if (MODModuleFaultHandler) {
            MODModuleFaultHandler(MODModuleLockScreen);
            MODModuleFaultHandler(MODModuleNotifications);
        }
    }
}
%end

%end

#pragma mark - Notifications

static void MODNotifyListChanged(SBLockScreenNotificationListController *list) {
    MODNotificationController *notifications = [[MODCoordinator shared] notifications];
    if (notifications) MODGuarded(MODModuleNotifications, @"listChanged", ^{ [notifications nativeListDidChange:list]; });
}

%group MODNotificationHooks

%hook SBLockScreenNotificationListController
- (void)_updateModelAndViewForAdditionOfItem:(id)item {
    %orig;
    MODNotifyListChanged(self);
}

- (void)_updateModelAndViewForRemovalOfItem:(id)item {
    %orig;
    MODNotifyListChanged(self);
}

- (void)_updateModelAndViewForModificationOfItem:(id)item {
    %orig;
    MODNotifyListChanged(self);
}

- (void)_updateModelAndViewForReplacingItem:(id)item withNewItem:(id)newItem {
    %orig;
    MODNotifyListChanged(self);
}

- (void)_updateModelForRemovalOfItem:(id)item updateView:(BOOL)updateView {
    %orig;
    MODNotifyListChanged(self);
}

- (BOOL)removeItemsForUnlock {
    BOOL result = %orig;
    MODNotifyListChanged(self);
    return result;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MODNotifyListChanged(self);
}
%end

%end

#pragma mark - App switcher

%group MODSwitcherHooks

%hook SBDeckSwitcherViewController
- (float)_blurForIndex:(unsigned int)index scrollProgress:(double)progress {
    MODAppSwitcherController *switcher = [[MODCoordinator shared] appSwitcher];
    __block BOOL override = NO;
    if (switcher) MODGuarded(MODModuleSwitcher, @"blur", ^{ override = [switcher overridesBlur]; });
    return override ? 0.0f : %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MODAppSwitcherController *switcher = [[MODCoordinator shared] appSwitcher];
    if (switcher) MODFirstUse(MODModuleSwitcher, @"deckDidAppear", ^{ [switcher deckDidAppear:self]; });
}

- (void)viewWillDisappear:(BOOL)animated {
    MODAppSwitcherController *switcher = [[MODCoordinator shared] appSwitcher];
    if (switcher) MODGuarded(MODModuleSwitcher, @"deckWillDisappear", ^{ [switcher deckWillDismiss:self]; });
    %orig;
}

- (void)_didAddVisibleItemContainer:(id)container forDisplayItem:(id)displayItem {
    %orig;
    MODAppSwitcherController *switcher = [[MODCoordinator shared] appSwitcher];
    if (switcher && [container isKindOfClass:[UIView class]]) {
        MODGuarded(MODModuleSwitcher, @"addContainer", ^{ [switcher deckDidAddContainer:container inDeck:self]; });
    }
}

- (void)animateDismissalToDisplayItem:(id)displayItem forTransitionRequest:(id)request withCompletion:(id)completion {
    MODAppSwitcherController *switcher = [[MODCoordinator shared] appSwitcher];
    if (switcher) MODGuarded(MODModuleSwitcher, @"deckDismiss", ^{ [switcher deckWillDismiss:self]; });
    %orig;
}
%end

%end

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        sLaunchStart = CFAbsoluteTimeGetCurrent();
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        // 1. Emergency disable: a plain file check, before preferences or state.
        if (access(MOD_STATE_DIRECTORY "/" MOD_CG_DISABLE_FILE, F_OK) == 0) {
            NSLog(@"[ModernOS] emergency disable file present; not loading.");
            return;
        }
        // 2. Master switch.
        if (![MODSettings masterEnabled]) {
            NSLog(@"[ModernOS] disabled in Settings; not loading.");
            [MODSettings publishStatus:@"Disabled in Settings"];
            return;
        }
        // 3. Crash guard. Records this attempt durably before anything is hooked.
        if ([MODCrashGuard evaluateLaunch] != MOD_CG_GATE_ACTIVATE) return;

        // 4. Hook groups, each verified first. Without the core group nothing
        //    can start, so nothing else is installed either.
        if (!MODVerify(kCoreSpecs)) {
            [MODCrashGuard withdrawLaunchAttempt:@"core hooks unavailable; ModernOS inactive"];
            return;
        }
        %init(MODCoreHooks);

        MODSettings *settings = [MODSettings current];
        MODCoordinator *coordinator = [MODCoordinator shared];
        BOOL (^wants)(MODModule) = ^BOOL(MODModule module) {
            return [settings isModuleEnabled:module] && ![MODCrashGuard isModuleDisabledByGuard:module];
        };

        if (wants(MODModuleControlCenter) && MODVerify(kControlCenterSpecs)) {
            %init(MODControlCenterHooks);
            [coordinator noteHooksInstalledForModule:MODModuleControlCenter];
            if (MODVerify(kPullDownSpecs)) %init(MODPullDownHooks);
        }

        BOOL wantLock = wants(MODModuleLockScreen), wantNotifications = wants(MODModuleNotifications);
        BOOL regionOK = (wantLock || wantNotifications) && MODVerify(kLockRegionSpecs);
        if (regionOK) %init(MODLockRegionHooks);
        if (wantLock && regionOK && MODVerify(kLockClockSpecs)) {
            %init(MODLockClockHooks);
            [coordinator noteHooksInstalledForModule:MODModuleLockScreen];
        }
        if (wantNotifications && regionOK && objc_getClass("SBAwayBulletinListItem") && MODVerify(kNotificationSpecs)) {
            %init(MODNotificationHooks);
            [coordinator noteHooksInstalledForModule:MODModuleNotifications];
        }

        if (wants(MODModuleSwitcher) && MODVerify(kSwitcherSpecs)) {
            %init(MODSwitcherHooks);
            [coordinator noteHooksInstalledForModule:MODModuleSwitcher];
        }
        NSLog(@"[ModernOS] constructor finished in %.1f ms", (CFAbsoluteTimeGetCurrent() - sLaunchStart) * 1000.0);
    }
}
