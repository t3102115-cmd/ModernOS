#import "MODControlCenterController.h"
#import "MODPrivate.h"
#import "MODTheme.h"
#import "MODComponents.h"
#import "MODPanelHost.h"
#import "MODSystemAdapters.h"
#import "MODCrashGuard.h"
#import <objc/runtime.h>

// Volume notification posted by Celestial (symbol verified as imported by SpringBoard).
static NSString *const MODVolumeChangedNotification = @"AVSystemController_SystemVolumeDidChangeNotification";

typedef NS_ENUM(NSInteger, MODCCSlot) {
    MODCCAirplane, MODCCWiFi, MODCCBluetooth, MODCCDoNotDisturb,
    MODCCRotationLock,
    MODCCFlashlight, MODCCTimer, MODCCCalculator, MODCCCamera,
    MODCCSlotCount,
};

static const char *MODCCClassNames[MODCCSlotCount] = {
    "SBCCAirplaneModeSetting", "SBCCWiFiSetting", "SBCCBluetoothSetting", "SBCCDoNotDisturbSetting",
    "SBCCOrientationLockSetting",
    "SBCCFlashlightSetting", "SBCCTimerShortcut", "SBCCCalculatorShortcut", "SBCCCameraShortcut",
};

static NSString *MODCCTitles[MODCCSlotCount] = {
    @"Airplane Mode", @"Wi-Fi", @"Bluetooth", @"Do Not Disturb", @"Rotation Lock",
    @"Flashlight", @"Timer", @"Calculator", @"Camera",
};

static BOOL MODCCIsLaunchShortcut(MODCCSlot slot) {
    return slot == MODCCTimer || slot == MODCCCalculator || slot == MODCCCamera;
}

#pragma mark - Panel

@interface MODControlCenterPanel : UIView <MODPanel, SBCCButtonModuleDelegate>
@end

@implementation MODControlCenterPanel {
    SBCCButtonModule *_modules[MODCCSlotCount];
    MODTileButton *_tiles[MODCCSlotCount];
    UIView *_connectivity;
    MODNowPlayingView *_nowPlaying;
    MODVerticalSlider *_brightness, *_volume;
    MODTileButton *_widgetsTile, *_batteryTile;
    BOOL _visible;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        MODTheme *theme = [MODTheme current];
        self.backgroundColor = theme.panelBackground;

        _connectivity = [[UIView alloc] initWithFrame:CGRectZero];
        _connectivity.layer.cornerRadius = theme.tileRadius;
        [self addSubview:_connectivity];

        for (NSInteger i = 0; i < MODCCSlotCount; i++) {
            MODTileButton *tile = [[MODTileButton alloc] initWithFrame:CGRectZero];
            tile.tag = i;
            tile.whiteWhenActive = i > MODCCDoNotDisturb;   // iOS 9 look outside the connectivity block
            tile.title = MODCCTitles[i];
            [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
            _tiles[i] = tile;
            [(i <= MODCCDoNotDisturb ? _connectivity : self) addSubview:tile];
        }

        _nowPlaying = [[MODNowPlayingView alloc] initWithFrame:CGRectZero];
        _nowPlaying.compact = YES;
        _nowPlaying.layer.cornerRadius = theme.tileRadius;
        __weak MODControlCenterPanel *weakSelf = self;
        _nowPlaying.openNowPlayingApp = ^(NSString *bundleID) { [weakSelf openApp:bundleID]; };
        [self addSubview:_nowPlaying];

        _brightness = [[MODVerticalSlider alloc] initWithFrame:CGRectZero];
        _brightness.glyphImage = [MODIcons glyph:MODGlyphSun size:22];
        _brightness.accessibilityLabel = @"Brightness";
        [_brightness addTarget:self action:@selector(brightnessChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_brightness];

        _volume = [[MODVerticalSlider alloc] initWithFrame:CGRectZero];
        _volume.glyphImage = [MODIcons glyph:MODGlyphSpeaker size:22];
        _volume.accessibilityLabel = @"Volume";
        [_volume addTarget:self action:@selector(volumeChanged) forControlEvents:UIControlEventValueChanged];
        _volume.adjustingChanged = ^(BOOL tracking) { [MODSystemAdapters setVolumeHUDSuppressed:tracking]; };
        [self addSubview:_volume];

        _widgetsTile = [[MODTileButton alloc] initWithFrame:CGRectZero];
        _widgetsTile.glyphImage = [MODIcons glyph:MODGlyphWidgets size:26];
        _widgetsTile.title = @"Widgets";
        [_widgetsTile addTarget:self action:@selector(widgetsTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_widgetsTile];

        _batteryTile = [[MODTileButton alloc] initWithFrame:CGRectZero];
        _batteryTile.glyphImage = [MODIcons glyph:MODGlyphBolt size:26];
        _batteryTile.userInteractionEnabled = NO;
        _batteryTile.accessibilityTraits = UIAccessibilityTraitStaticText;
        [self addSubview:_batteryTile];

        [self applyTheme];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (NSInteger i = 0; i < MODCCSlotCount; i++) {
        SBCCButtonModule *module = _modules[i];
        if (!module) continue;
        if ([module respondsToSelector:@selector(setDelegate:)]) module.delegate = nil;
        if ([module respondsToSelector:@selector(deactivate)]) [module deactivate];
    }
}

- (MODModule)panelModule { return MODModuleControlCenter; }

- (NSArray<UIView *> *)panelAnimatedViews {
    NSMutableArray *views = [NSMutableArray arrayWithObjects:_connectivity, _nowPlaying, _tiles[MODCCRotationLock], _widgetsTile,
                             _batteryTile, _brightness, _volume, nil];
    for (NSInteger i = MODCCFlashlight; i <= MODCCCamera; i++) [views addObject:_tiles[i]];
    return views;
}

- (CGFloat)panelHeightForBounds:(CGRect)bounds {
    MODTheme *theme = [MODTheme current];
    CGFloat unit = [self unitForWidth:bounds.size.width];
    return theme.margin * 2 + unit * 5 + theme.gap * 4;
}

- (CGFloat)unitForWidth:(CGFloat)width {
    MODTheme *theme = [MODTheme current];
    return floor((width - 2 * theme.margin - 3 * theme.gap) / 4);
}

- (void)applyTheme {
    MODTheme *theme = [MODTheme current];
    self.backgroundColor = theme.panelBackground;
    _connectivity.backgroundColor = theme.tileBackground;
    for (NSInteger i = 0; i < MODCCSlotCount; i++) [_tiles[i] applyTheme];
    [_nowPlaying applyTheme];
    [_brightness applyTheme];
    [_volume applyTheme];
    [_widgetsTile applyTheme];
    [_batteryTile applyTheme];
}

#pragma mark Layout (frame-based, computed once per bounds change)

- (void)layoutSubviews {
    [super layoutSubviews];
    MODTheme *theme = [MODTheme current];
    CGFloat m = theme.margin, g = theme.gap, u = [self unitForWidth:self.bounds.size.width];
    CGFloat block = 2 * u + g;
    CGFloat (^col)(NSInteger) = ^CGFloat(NSInteger c) { return m + c * (u + g); };
    CGFloat (^row)(NSInteger) = ^CGFloat(NSInteger r) { return m + r * (u + g); };

    // Rows 0-1: connectivity block (2x2 round toggles) + Now Playing.
    _connectivity.frame = CGRectMake(col(0), row(0), block, block);
    CGFloat inner = floor((block - 3 * 8) / 2);
    for (NSInteger i = MODCCAirplane; i <= MODCCDoNotDisturb; i++) {
        CGFloat x = 8 + (i % 2) * (inner + 8), y = 8 + (i / 2) * (inner + 8);
        _tiles[i].frame = CGRectMake(x, y, inner, inner);
        _tiles[i].layer.cornerRadius = inner / 2;   // circular toggles inside the block
    }
    _nowPlaying.frame = CGRectMake(col(2), row(0), block, block);

    // Rows 2-3: rotation lock + widgets, battery (wide); sliders on the right.
    _tiles[MODCCRotationLock].frame = CGRectMake(col(0), row(2), u, u);
    _widgetsTile.frame = CGRectMake(col(1), row(2), u, u);
    _batteryTile.frame = CGRectMake(col(0), row(3), block, u);
    _brightness.frame = CGRectMake(col(2), row(2), u, block);
    _volume.frame = CGRectMake(col(3), row(2), u, block);

    // Row 4: flashlight, timer, calculator, camera.
    for (NSInteger i = MODCCFlashlight; i <= MODCCCamera; i++) {
        _tiles[i].frame = CGRectMake(col(i - MODCCFlashlight), row(4), u, u);
    }
}

#pragma mark Lifecycle

- (void)panelWillAppear {
    _visible = YES;
    [self ensureModules];
    for (NSInteger i = 0; i < MODCCSlotCount; i++) [self updateTile:(MODCCSlot)i];
    if ([_modules[MODCCFlashlight] respondsToSelector:@selector(warmup)]) [_modules[MODCCFlashlight] warmup];

    _widgetsTile.enabled = [[MODCoordinator shared] widgets] != nil;
    [_brightness setValue:[MODSystemAdapters brightness] animated:NO];
    [_volume setValue:[MODSystemAdapters volume] animated:NO];
    [self updateBattery];
    [_nowPlaying refresh];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(externalVolumeChanged) name:MODVolumeChangedNotification object:nil];
    [center addObserver:self selector:@selector(externalBrightnessChanged) name:UIScreenBrightnessDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateBattery) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateBattery) name:UIDeviceBatteryStateDidChangeNotification object:nil];
}

- (void)panelDidDisappear {
    _visible = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if ([_modules[MODCCFlashlight] respondsToSelector:@selector(cooldown)]) [_modules[MODCCFlashlight] cooldown];
    [MODSystemAdapters setVolumeHUDSuppressed:NO];
}

// Module objects are created on first presentation and kept while the panel
// object lives (they are small observers, like the native Control Center's).
- (void)ensureModules {
    for (NSInteger i = 0; i < MODCCSlotCount; i++) {
        if (_modules[i]) continue;
        Class cls = objc_getClass(MODCCClassNames[i]);
        if (!cls || ![cls instancesRespondToSelector:@selector(toggleState)]) continue;
        SBCCButtonModule *module = [[cls alloc] init];
        if (!module) continue;
        if ([module respondsToSelector:@selector(setDelegate:)]) module.delegate = self;
        if ([module respondsToSelector:@selector(activate)]) [module activate];
        _modules[i] = module;
        UIImage *glyph = [module respondsToSelector:@selector(glyphImageForState:)] ? [module glyphImageForState:0] : nil;
        if (glyph) _tiles[i].glyphImage = glyph;
    }
}

- (void)updateTile:(MODCCSlot)slot {
    SBCCButtonModule *module = _modules[slot];
    MODTileButton *tile = _tiles[slot];
    if (!module) {
        tile.enabled = NO;
        tile.active = NO;
        return;
    }
    BOOL restricted = ([module respondsToSelector:@selector(isRestricted)] && [module isRestricted]) ||
                      ([module respondsToSelector:@selector(isInoperative)] && [module isInoperative]);
    int state = [module respondsToSelector:@selector(state)] ? [module state] : 0;
    tile.enabled = !restricted;
    tile.active = !MODCCIsLaunchShortcut(slot) && state != 0;
    UIImage *glyph = [module respondsToSelector:@selector(glyphImageForState:)] ? [module glyphImageForState:state] : nil;
    if (glyph) tile.glyphImage = glyph;
    tile.subtitle = MODCCIsLaunchShortcut(slot) ? nil : (state ? @"On" : @"Off");
}

#pragma mark SBCCButtonModuleDelegate

- (void)buttonModuleStateDidChange:(id)module {
    [self refreshModule:module];
}

- (void)buttonModulePropertiesDidChange:(id)module {
    [self refreshModule:module];
}

- (void)refreshModule:(id)module {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshModule:module]; });
        return;
    }
    for (NSInteger i = 0; i < MODCCSlotCount; i++) {
        if (_modules[i] == module) {
            MODGuarded(MODModuleControlCenter, @"updateTile", ^{ [self updateTile:(MODCCSlot)i]; });
            return;
        }
    }
}

#pragma mark Actions

- (void)tileTapped:(MODTileButton *)tile {
    MODCCSlot slot = (MODCCSlot)tile.tag;
    SBCCButtonModule *module = (slot >= 0 && slot < MODCCSlotCount) ? _modules[slot] : nil;
    if (!module) return;
    MODGuarded(MODModuleControlCenter, @"toggle", ^{
        if ([module respondsToSelector:@selector(needsConfirmation)] && [module needsConfirmation]) {
            [self confirmToggleOfModule:module];
            return;
        }
        if (MODCCIsLaunchShortcut(slot)) {
            // The stock shortcut handles the lock screen (e.g. Camera) itself.
            [[MODPanelHost shared] dismissAnimated:YES completion:^{ [module toggleState]; }];
        } else {
            [module toggleState];
            [self updateTile:slot];
        }
    });
}

- (void)confirmToggleOfModule:(SBCCButtonModule *)module {
    UIViewController *presenter = [MODPanelHost shared].presentingViewController;
    if (!presenter) return;
    NSString *title = [module respondsToSelector:@selector(confirmationAlertTitle)] ? [module confirmationAlertTitle] : nil;
    NSString *message = [module respondsToSelector:@selector(confirmationAlertMessage)] ? [module confirmationAlertMessage] : nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if ([module respondsToSelector:@selector(confirmed:)]) [module confirmed:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if ([module respondsToSelector:@selector(confirmed:)]) [module confirmed:YES];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)brightnessChanged {
    [MODSystemAdapters setBrightness:_brightness.value];
}

- (void)volumeChanged {
    [MODSystemAdapters setVolume:_volume.value];
}

- (void)externalVolumeChanged {
    if (_visible && !_volume.adjusting) [_volume setValue:[MODSystemAdapters volume] animated:NO];
}

- (void)externalBrightnessChanged {
    if (_visible && !_brightness.adjusting) [_brightness setValue:[MODSystemAdapters brightness] animated:NO];
}

- (void)updateBattery {
    NSInteger percent = [MODSystemAdapters batteryPercent];
    BOOL charging = [MODSystemAdapters isCharging];
    _batteryTile.title = percent >= 0 ? [NSString stringWithFormat:@"%ld%%", (long)percent] : @"Battery";
    _batteryTile.subtitle = charging ? @"Charging" : @"Battery";
    _batteryTile.active = NO;
}

- (void)widgetsTapped {
    [[MODCoordinator shared] openWidgetDashboard];
}

- (void)openApp:(NSString *)bundleID {
    [[MODPanelHost shared] dismissAnimated:YES completion:^{
        [MODSystemAdapters openAfterUnlockBundleID:bundleID URL:nil];
    }];
}

@end

#pragma mark - Controller

@implementation MODControlCenterController {
    MODControlCenterPanel *_panel;
    BOOL _trackingGesture;
    BOOL _fromTop;
    CGPoint _gestureStart;
}

- (void)activate {}

- (void)deactivate {
    MODPanelHost *host = [MODPanelHost shared];
    if (host.currentPanel == _panel) [host dismissAnimated:NO completion:nil];
    _panel = nil;
    _trackingGesture = NO;
}

- (void)settingsDidChange:(MODSettings *)settings {
    // Theme changes: rebuild lazily on next presentation.
    if ([MODPanelHost shared].currentPanel != _panel) _panel = nil;
    else [_panel applyTheme];
}

- (void)didReceiveMemoryWarning {
    if ([MODPanelHost shared].currentPanel != _panel) _panel = nil;
}

- (MODControlCenterPanel *)panel {
    if (!_panel) _panel = [[MODControlCenterPanel alloc] initWithFrame:CGRectZero];
    return _panel;
}

- (BOOL)handleShowGesture:(UIGestureRecognizer *)recognizer fromTop:(BOOL)fromTop {
    if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)recognizer;
    UIGestureRecognizerState state = pan.state;
    MODPanelHost *host = [MODPanelHost shared];

    if (state == UIGestureRecognizerStateBegan) {
        // Landscape apps keep the native panels (ModernOS is portrait-only).
        if (![MODSystemAdapters isPortraitInterface]) return NO;
        if (host.isPresenting) {
            _trackingGesture = NO;
            return YES;   // swallow: a ModernOS panel is already up
        }
        _trackingGesture = YES;
        _fromTop = fromTop;
        _gestureStart = [pan locationInView:nil];
        MODFirstUse(MODModuleControlCenter, @"present", ^{
            [host beginInteractivePresentationOfPanel:[self panel] fromEdge:fromTop ? MODPanelEdgeTop : MODPanelEdgeBottom];
        });
        return YES;
    }
    if (!_trackingGesture) return NO;

    CGFloat sign = _fromTop ? 1 : -1;   // positive = revealing
    CGFloat distance = ([pan locationInView:nil].y - _gestureStart.y) * sign;
    switch (state) {
        case UIGestureRecognizerStateChanged:
            [host updateInteractivePresentationWithDistance:distance];
            break;
        case UIGestureRecognizerStateEnded:
            _trackingGesture = NO;
            [host endInteractivePresentationWithVelocity:[pan velocityInView:nil].y * sign cancelled:NO];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            _trackingGesture = NO;
            [host endInteractivePresentationWithVelocity:0 cancelled:YES];
            break;
        default:
            break;
    }
    return YES;
}

@end
