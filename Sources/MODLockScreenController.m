#import "MODLockScreenController.h"
#import "MODNotificationController.h"
#import "MODPrivate.h"
#import "MODTheme.h"
#import "MODComponents.h"
#import "MODSystemAdapters.h"
#import "MODCrashGuard.h"
#import "MODAnimationCoordinator.h"
#import <objc/runtime.h>

static const NSInteger MODAccessoryTag = 0x4D4F4401;
static const NSInteger MODGroupedTag = 0x4D4F4402;
static const NSInteger MODWallpaperTag = 0x4D4F4403;
static const CGFloat MODAccessoryHeight = 34;
static NSString *const MODWallpaperPath = @"/var/mobile/Library/ModernOS/LockWallpaper.jpg";

static char kMODRegionKey, kMODInsetKey, kMODHidNativeKey;

#pragma mark - Accessory row (battery + widgets)

@interface MODLockAccessoryView : UIView
- (void)refresh;
@end

@implementation MODLockAccessoryView {
    UIButton *_battery;
    UIButton *_widgets;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = MODAccessoryTag;
        _battery = [self pill];
        _battery.userInteractionEnabled = NO;
        _widgets = [self pill];
        [_widgets setImage:[MODIcons glyph:MODGlyphWidgets size:14] forState:UIControlStateNormal];
        [_widgets setTitle:@" Widgets" forState:UIControlStateNormal];
        _widgets.accessibilityLabel = @"Open widgets";
        [_widgets addTarget:self action:@selector(widgetsTapped) forControlEvents:UIControlEventTouchUpInside];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)pill {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    // Small translucent pills: the only blended ModernOS layers on the lock
    // screen, a few hundred points in area.
    button.backgroundColor = [MODTheme current].glassBackground;
    button.layer.cornerRadius = 13;
    button.titleLabel.font = [[MODTheme current] fontOfSize:13 weight:UIFontWeightSemibold];
    button.tintColor = [UIColor whiteColor];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    [self addSubview:button];
    return button;
}

- (void)refresh {
    MODSettings *settings = [MODSettings current];
    NSInteger percent = [MODSystemAdapters batteryPercent];
    BOOL charging = [MODSystemAdapters isCharging];
    _battery.hidden = !settings.lockShowBattery || percent < 0;
    [_battery setImage:charging ? [MODIcons glyph:MODGlyphBolt size:14] : nil forState:UIControlStateNormal];
    [_battery setTitle:[NSString stringWithFormat:@"%@%ld%%", charging ? @" " : @"", (long)percent] forState:UIControlStateNormal];
    _battery.accessibilityLabel = [NSString stringWithFormat:@"Battery %ld percent%@", (long)percent, charging ? @", charging" : @""];
    _widgets.hidden = [[MODCoordinator shared] widgets] == nil;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = 26, y = floor((self.bounds.size.height - h) / 2), gap = 8;
    NSMutableArray<UIButton *> *visible = [NSMutableArray array];
    for (UIButton *b in @[ _battery, _widgets ]) if (!b.hidden) [visible addObject:b];
    CGFloat total = -gap;
    for (UIButton *b in visible) total += [b sizeThatFits:CGSizeMake(200, h)].width + gap;
    CGFloat x = floor((self.bounds.size.width - total) / 2);
    for (UIButton *b in visible) {
        CGFloat w = [b sizeThatFits:CGSizeMake(200, h)].width;
        b.frame = CGRectMake(x, y, w, h);
        x += w + gap;
    }
}

- (void)widgetsTapped {
    [[MODCoordinator shared] openWidgetDashboard];
}

@end

#pragma mark - Controller

@implementation MODLockScreenController {
    UIImage *_wallpaper;
    BOOL _loadingWallpaper;
}

- (void)activate {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [MODLockScreenController relayoutLockScreen];
}

- (void)deactivate {
    _wallpaper = nil;
    // The coordinator already marked us inactive, so the next layout pass
    // restores the native date view and removes every ModernOS view.
    [MODLockScreenController relayoutLockScreen];
}

- (void)settingsDidChange:(MODSettings *)settings {
    if (!settings.lockCustomWallpaper) _wallpaper = nil;
    [MODLockScreenController relayoutLockScreen];
}

- (void)didReceiveMemoryWarning {
    _wallpaper = nil;
}

- (void)deviceDidUnlock {
    _wallpaper = nil;   // ~2.4 MB decoded; only needed while locked
}

+ (void)relayoutLockScreen {
    SBLockScreenManager *manager = [objc_getClass("SBLockScreenManager") respondsToSelector:@selector(sharedInstanceIfExists)]
        ? [objc_getClass("SBLockScreenManager") sharedInstanceIfExists] : nil;
    SBLockScreenViewController *controller = [manager respondsToSelector:@selector(lockScreenViewController)] ? [manager lockScreenViewController] : nil;
    // -isViewLoaded avoids creating the lock screen view just to relayout it.
    if (![controller isViewLoaded] || ![controller respondsToSelector:@selector(lockScreenView)]) return;
    UIView *view = (UIView *)[controller lockScreenView];
    [view setNeedsLayout];
    MODLockAccessoryView *accessory = (MODLockAccessoryView *)[view viewWithTag:MODAccessoryTag];
    if ([accessory isKindOfClass:[MODLockAccessoryView class]]) [accessory refresh];
    UIView *dateView = [view respondsToSelector:@selector(dateView)] ? [(SBLockScreenView *)view dateView] : nil;
    [dateView setNeedsLayout];
    if ([dateView respondsToSelector:@selector(updateFormat)]) [(SBFLockScreenDateView *)dateView updateFormat];
}

#pragma mark Clock

- (UIFont *)timeFontForOriginal:(UIFont *)original {
    if (![MODSettings current].lockModernClock) return original;
    return [[MODTheme current] monoDigitsFontOfSize:80 weight:UIFontWeightMedium] ?: original;
}

- (UIFont *)dateFontForOriginal:(UIFont *)original {
    if (![MODSettings current].lockModernClock) return original;
    return [[MODTheme current] fontOfSize:17 weight:UIFontWeightSemibold] ?: original;
}

// Modern order: date above a large time. The two labels are identified
// structurally (the time label is the clearly taller one); if the structure is
// not what we expect, nothing is changed.
- (void)dateViewDidLayout:(UIView *)dateView {
    if (![MODSettings current].lockModernClock) return;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    for (UIView *v in dateView.subviews) {
        if (!v.hidden && v.alpha > 0.01 && v.frame.size.height > 4 && v.frame.size.width > 20) [candidates addObject:v];
    }
    if (candidates.count < 2) return;
    [candidates sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.size.height > b.frame.size.height ? NSOrderedAscending : NSOrderedDescending;
    }];
    UIView *time = candidates[0], *date = candidates[1];
    if (time.frame.size.height < date.frame.size.height * 1.8) return;
    if (CGRectGetMinY(date.frame) < CGRectGetMinY(time.frame)) return;   // already date-first
    CGFloat top = CGRectGetMinY(time.frame);
    CGRect dateFrame = date.frame, timeFrame = time.frame;
    dateFrame.origin.y = top;
    timeFrame.origin.y = CGRectGetMaxY(dateFrame) - 6;   // big fonts carry generous leading
    date.frame = dateFrame;
    time.frame = timeFrame;
}

#pragma mark Wallpaper

- (void)applyWallpaperToLockScreenView:(UIView *)lockView {
    UIImageView *imageView = (UIImageView *)[lockView viewWithTag:MODWallpaperTag];
    if (!imageView) {
        imageView = [[UIImageView alloc] initWithFrame:lockView.bounds];
        imageView.tag = MODWallpaperTag;
        imageView.opaque = YES;
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.userInteractionEnabled = NO;
        [lockView insertSubview:imageView atIndex:0];
    }
    imageView.frame = lockView.bounds;
    if (_wallpaper) {
        imageView.image = _wallpaper;
        imageView.hidden = NO;
        return;
    }
    imageView.hidden = YES;   // native wallpaper shows until the image is decoded
    if (_loadingWallpaper) return;
    _loadingWallpaper = YES;
    CGSize target = lockView.bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    __weak MODLockScreenController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        UIImage *source = [UIImage imageWithContentsOfFile:MODWallpaperPath];
        UIImage *decoded = nil;
        if (source && target.width > 0) {
            // Decode once at screen size (opaque, no alpha) so scrolling never decodes.
            UIGraphicsBeginImageContextWithOptions(target, YES, scale);
            CGSize s = source.size;
            CGFloat f = MAX(target.width / MAX(s.width, 1), target.height / MAX(s.height, 1));
            [source drawInRect:CGRectMake((target.width - s.width * f) / 2, (target.height - s.height * f) / 2, s.width * f, s.height * f)];
            decoded = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MODLockScreenController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_loadingWallpaper = NO;
            if (!decoded) {
                NSLog(@"[ModernOS] custom lock wallpaper not found or unreadable at %@", MODWallpaperPath);
                return;
            }
            if (![MODSettings current].lockCustomWallpaper) return;
            strongSelf->_wallpaper = decoded;
            [MODLockScreenController relayoutLockScreen];
        });
    });
}

#pragma mark Notification region

static CGRect MODNativeRegion(UIView *native) {
    NSValue *inset = objc_getAssociatedObject(native, &kMODInsetKey);
    NSValue *region = objc_getAssociatedObject(native, &kMODRegionKey);
    if (inset && region && CGRectEqualToRect(inset.CGRectValue, native.frame)) {
        return region.CGRectValue;   // native did not re-lay out; our inset is still applied
    }
    objc_setAssociatedObject(native, &kMODRegionKey, [NSValue valueWithCGRect:native.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(native, &kMODInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return native.frame;
}

static void MODSetNativeHidden(UIView *native, BOOL hide) {
    BOOL weHid = [objc_getAssociatedObject(native, &kMODHidNativeKey) boolValue];
    if (hide && !native.hidden) {
        native.hidden = YES;
        objc_setAssociatedObject(native, &kMODHidNativeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!hide && weHid) {
        native.hidden = NO;   // only undo what ModernOS did
        objc_setAssociatedObject(native, &kMODHidNativeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

+ (void)lockScreenViewDidLayout:(SBLockScreenView *)lockScreenView {
    MODCoordinator *coordinator = [MODCoordinator shared];
    MODLockScreenController *lock = [coordinator lockScreen];
    MODNotificationController *notifications = [coordinator notifications];
    UIView *lockView = (UIView *)lockScreenView;

    // Wallpaper (lock module only).
    if (lock && [MODSettings current].lockCustomWallpaper) {
        MODGuarded(MODModuleLockScreen, @"wallpaper", ^{ [lock applyWallpaperToLockScreenView:lockView]; });
    } else {
        [[lockView viewWithTag:MODWallpaperTag] removeFromSuperview];
    }

    UIView *native = [lockScreenView respondsToSelector:@selector(notificationView)] ? [lockScreenView notificationView] : nil;
    UIView *container = native.superview;
    if (!container) return;
    CGRect region = MODNativeRegion(native);

    // Accessory row.
    MODLockAccessoryView *accessory = (MODLockAccessoryView *)[container viewWithTag:MODAccessoryTag];
    BOOL wantAccessory = lock && ([MODSettings current].lockShowBattery || [coordinator widgets]);
    CGRect remaining = region;
    if (wantAccessory) {
        MODFirstUse(MODModuleLockScreen, @"accessory", ^{
            // Layout runs during lock screen scrolling: only frames here. Content
            // refreshes on creation, battery notifications and relayout requests.
            MODLockAccessoryView *view = accessory;
            BOOL created = !view;
            if (!view) {
                view = [[MODLockAccessoryView alloc] initWithFrame:CGRectZero];
                [container addSubview:view];
                [view refresh];
            }
            view.frame = CGRectMake(region.origin.x, region.origin.y, region.size.width, MODAccessoryHeight);
            if (created) {
                // Pills settle in under the clock instead of popping into existence.
                view.alpha = 0;
                view.transform = CGAffineTransformMakeTranslation(0, -8);
                [[MODAnimationCoordinator shared] springAnimations:^{
                    view.alpha = 1;
                    view.transform = CGAffineTransformIdentity;
                } duration:0.5 damping:0.8 velocity:0 completion:nil];
            }
        });
        if ([container viewWithTag:MODAccessoryTag]) {
            remaining.origin.y += MODAccessoryHeight;
            remaining.size.height = MAX(0, remaining.size.height - MODAccessoryHeight);
        }
    } else {
        [accessory removeFromSuperview];
    }

    // Grouped notifications replace the native list only when every native item
    // can be rendered faithfully; otherwise the native list stays visible.
    __block UIView *grouped = nil;
    if (notifications) {
        MODFirstUse(MODModuleNotifications, @"groupedView", ^{ grouped = [notifications groupedViewForDisplay]; });
    }
    UIView *existingGrouped = [container viewWithTag:MODGroupedTag];
    if (existingGrouped && existingGrouped != grouped) [existingGrouped removeFromSuperview];
    if (grouped) {
        grouped.tag = MODGroupedTag;
        if (grouped.superview != container) [container addSubview:grouped];
        grouped.frame = remaining;
        MODSetNativeHidden(native, YES);
    } else {
        MODSetNativeHidden(native, NO);
    }

    if (!CGRectEqualToRect(remaining, region)) {
        native.frame = remaining;
        objc_setAssociatedObject(native, &kMODInsetKey, [NSValue valueWithCGRect:remaining], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(native, &kMODInsetKey)) {
        native.frame = region;
        objc_setAssociatedObject(native, &kMODInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@end
