#import "MODCoordinator.h"
#import "MODCrashGuard.h"
#import "MODTheme.h"
#import "MODAnimationCoordinator.h"
#import "MODPanelHost.h"
#import "MODComponents.h"
#import "MODSystemAdapters.h"
#import "MODControlCenterController.h"
#import "MODLockScreenController.h"
#import "MODWidgetController.h"
#import "MODNotificationController.h"
#import "MODAppSwitcherController.h"

// Verified string constants from the iOS 9.3.6 SpringBoard binary.
static NSString *const MODSBLockNotification = @"SBLockScreenUIDidLockNotification";
static NSString *const MODSBNowPlayingNotification = @"SBMediaNowPlayingChangedNotification";

static void MODHandleModuleFault(MODModule module);

@implementation MODCoordinator {
    BOOL _hooksInstalled[MODModuleCount];
    BOOL _active[MODModuleCount];
    id<MODModuleController> _controllers[MODModuleCount];
}

+ (instancetype)shared {
    static MODCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (void)noteHooksInstalledForModule:(MODModule)module {
    if (module >= 0 && module < MODModuleCount) _hooksInstalled[module] = YES;
}

- (BOOL)hooksInstalledForModule:(MODModule)module {
    return module >= 0 && module < MODModuleCount && _hooksInstalled[module];
}

#pragma mark - Lifecycle

- (void)springBoardDidFinishLaunchingWithLaunchStart:(CFAbsoluteTime)launchStart {
    if (_started) return;
    _started = YES;
    MODModuleFaultHandler = MODHandleModuleFault;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(settingsChanged:) name:MODPreferencesChangedNotification object:nil];
    [center addObserver:self selector:@selector(memoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [center addObserver:self selector:@selector(deviceDidLock) name:MODSBLockNotification object:nil];
    [center addObserver:self selector:@selector(nowPlayingChanged) name:MODSBNowPlayingNotification object:nil];
    [MODSettings startObservingChanges];

    [self applySettings:[MODSettings current]];
    [MODCrashGuard beginStabilityTimerWithLaunchStart:launchStart];
}

- (id<MODModuleController>)makeControllerForModule:(MODModule)module {
    switch (module) {
        case MODModuleControlCenter: return [MODControlCenterController new];
        case MODModuleLockScreen: return [MODLockScreenController new];
        case MODModuleWidgets: return [MODWidgetController new];
        case MODModuleNotifications: return [MODNotificationController new];
        case MODModuleSwitcher: return [MODAppSwitcherController new];
    }
    return nil;
}

- (BOOL)shouldBeActive:(MODModule)module settings:(MODSettings *)settings {
    // The widget dashboard needs no hooks of its own; it is reached from the
    // Control Center and lock screen surfaces.
    BOOL hooksOK = module == MODModuleWidgets || _hooksInstalled[module];
    return _started && hooksOK && [settings isModuleEnabled:module] && ![MODCrashGuard isModuleDisabledByGuard:module];
}

- (void)applySettings:(MODSettings *)settings {
    [MODTheme reloadFromSettings];
    [[MODAnimationCoordinator shared] reloadSettings];
    for (NSInteger i = 0; i < MODModuleCount; i++) {
        MODModule module = (MODModule)i;
        BOOL want = [self shouldBeActive:module settings:settings];
        if (want && !_active[i]) {
            MODGuarded(module, @"activate", ^{
                if (!self->_controllers[i]) self->_controllers[i] = [self makeControllerForModule:module];
                [self->_controllers[i] activate];
                self->_active[i] = YES;
            });
        } else if (!want && _active[i]) {
            [self deactivateModule:module];
        } else if (want) {
            id<MODModuleController> controller = _controllers[i];
            MODGuarded(module, @"settingsDidChange", ^{
                if ([controller respondsToSelector:@selector(settingsDidChange:)]) [controller settingsDidChange:settings];
            });
        }
    }
}

- (void)deactivateModule:(MODModule)module {
    if (module < 0 || module >= MODModuleCount) return;
    _active[module] = NO;
    MODPanelHost *host = [MODPanelHost shared];
    if (host.isPresenting && host.currentPanel.panelModule == module) [host dismissAnimated:NO completion:nil];
    id<MODModuleController> controller = _controllers[module];
    _controllers[module] = nil;
    // Deactivation itself must not take SpringBoard down.
    @try {
        [controller deactivate];
    } @catch (NSException *exception) {
        NSLog(@"[ModernOS] exception while deactivating module %ld: %@", (long)module, exception);
    }
}

- (void)settingsChanged:(NSNotification *)note {
    MODSettings *settings = [note.object isKindOfClass:[MODSettings class]] ? note.object : [MODSettings current];
    [self applySettings:settings];
}

- (void)memoryWarning {
    [[MODPanelHost shared] releaseResources];
    [MODIcons purge];
    [MODSystemAdapters purgeCaches];
    for (NSInteger i = 0; i < MODModuleCount; i++) {
        id<MODModuleController> controller = _active[i] ? _controllers[i] : nil;
        if ([controller respondsToSelector:@selector(didReceiveMemoryWarning)]) {
            MODGuarded((MODModule)i, @"memoryWarning", ^{ [controller didReceiveMemoryWarning]; });
        }
    }
}

- (void)deviceDidLock {
    [[MODPanelHost shared] dismissAnimated:NO completion:^{ [[MODPanelHost shared] releaseResources]; }];
    for (NSInteger i = 0; i < MODModuleCount; i++) {
        id<MODModuleController> controller = _active[i] ? _controllers[i] : nil;
        if ([controller respondsToSelector:@selector(deviceDidLock)]) {
            MODGuarded((MODModule)i, @"deviceDidLock", ^{ [controller deviceDidLock]; });
        }
    }
}

- (void)deviceDidUnlock {
    for (NSInteger i = 0; i < MODModuleCount; i++) {
        id<MODModuleController> controller = _active[i] ? _controllers[i] : nil;
        if ([controller respondsToSelector:@selector(deviceDidUnlock)]) {
            MODGuarded((MODModule)i, @"deviceDidUnlock", ^{ [controller deviceDidUnlock]; });
        }
    }
    [MODSystemAdapters deviceDidUnlock];
}

- (void)nowPlayingChanged {
    // One relay observer; views subscribe only while on screen.
    [[NSNotificationCenter defaultCenter] postNotificationName:MODNowPlayingDidChangeNotification object:nil];
}

#pragma mark - Queries

- (BOOL)isModuleActive:(MODModule)module {
    return module >= 0 && module < MODModuleCount && _active[module] && ![MODCrashGuard isModuleDisabledByGuard:module];
}

- (id)activeController:(MODModule)module {
    return [self isModuleActive:module] ? _controllers[module] : nil;
}

- (MODControlCenterController *)controlCenter { return [self activeController:MODModuleControlCenter]; }
- (MODLockScreenController *)lockScreen { return [self activeController:MODModuleLockScreen]; }
- (MODWidgetController *)widgets { return [self activeController:MODModuleWidgets]; }
- (MODNotificationController *)notifications { return [self activeController:MODModuleNotifications]; }
- (MODAppSwitcherController *)appSwitcher { return [self activeController:MODModuleSwitcher]; }

#pragma mark - Actions

- (BOOL)handleMenuButton {
    MODPanelHost *host = [MODPanelHost shared];
    if (!host.isPresenting) return NO;
    [host dismissAnimated:YES completion:nil];
    return YES;
}

- (void)openWidgetDashboard {
    MODWidgetController *widgets = [self widgets];
    if (!widgets) return;
    MODPanelHost *host = [MODPanelHost shared];
    void (^present)(void) = ^{
        MODFirstUse(MODModuleWidgets, @"presentDashboard", ^{ [widgets presentDashboard]; });
    };
    if (host.isPresenting) [host dismissAnimated:YES completion:present];
    else present();
}

@end

static void MODHandleModuleFault(MODModule module) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[MODCoordinator shared] deactivateModule:module];
    });
}
