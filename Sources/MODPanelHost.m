#import "MODPanelHost.h"
#import "MODTheme.h"
#import "MODAnimationCoordinator.h"
#import "MODCrashGuard.h"
#import "MODComponents.h"
#import <Accelerate/Accelerate.h>
#include <dlfcn.h>

// Above SpringBoard UI and the status bar (1000), below system alerts that
// raise themselves higher.
static const UIWindowLevel MODPanelWindowLevel = 1050;
static const CGFloat MODTopInset = 26;      // content starts below the status bar
static const CGFloat MODBottomInset = 10;
static const size_t MODFrostDownscale = 8;  // 640x960 px -> 80x120 px

@interface MODPanelWindow : UIWindow
@end

@implementation MODPanelWindow
// Same mechanism SpringBoard's SBSecureWindow uses to stay visible while locked
// (+[UIWindow _isSecure] verified on the device).
+ (BOOL)_isSecure { return YES; }
@end

@interface MODPanelRootController : UIViewController
@property (nonatomic, copy) void (^escape)(void);
@end

@implementation MODPanelRootController
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)accessibilityPerformEscape {
    if (self.escape) self.escape();
    return YES;
}
@end

#pragma mark - Frost

// Captures the screen (UIKit's _UICreateScreenUIImage, verified present on
// iOS 9.3.6). Must run on the main thread before the panel window is shown.
static CGImageRef MODCopyScreenImage(void) {
    static CFTypeRef (*capture)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY | RTLD_NOLOAD);
        capture = uikit ? (CFTypeRef (*)(void))dlsym(uikit, "_UICreateScreenUIImage") : NULL;
    });
    if (!capture) return NULL;
    UIImage *image = CFBridgingRelease(capture());
    CGImageRef cgImage = image.CGImage;
    return cgImage ? CGImageRetain(cgImage) : NULL;
}

// Downscale, triple box blur (≈ gaussian), then tint. ~80x120 px: a few ms.
static UIImage *MODMakeFrost(CGImageRef screen, BOOL dark) {
    size_t width = MAX((size_t)1, CGImageGetWidth(screen) / MODFrostDownscale);
    size_t height = MAX((size_t)1, CGImageGetHeight(screen) / MODFrostDownscale);
    size_t rowBytes = width * 4;
    void *a = calloc(height, rowBytes), *b = calloc(height, rowBytes);
    UIImage *result = nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = (a && b) ? CGBitmapContextCreate(a, width, height, 8, rowBytes, space,
                                                       kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : NULL;
    if (ctx) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), screen);
        vImage_Buffer src = { a, height, width, rowBytes }, dst = { b, height, width, rowBytes };
        for (int pass = 0; pass < 3; pass++) {
            vImageBoxConvolve_ARGB8888(&src, &dst, NULL, 0, 0, 9, 9, NULL, kvImageEdgeExtend);
            vImageBoxConvolve_ARGB8888(&dst, &src, NULL, 0, 0, 9, 9, NULL, kvImageEdgeExtend);
        }
        // iOS 9 frosted tint: darker in dark mode, milky in light mode.
        CGContextSetFillColorWithColor(ctx, (dark ? [UIColor colorWithWhite:0.05 alpha:0.52] : [UIColor colorWithWhite:0.97 alpha:0.55]).CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
        CGImageRef blurred = CGBitmapContextCreateImage(ctx);
        if (blurred) {
            result = [UIImage imageWithCGImage:blurred];
            CGImageRelease(blurred);
        }
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(space);
    free(a);
    free(b);
    return result;
}

#pragma mark - Host

@interface MODPanelHost () <UIGestureRecognizerDelegate>
@end

@implementation MODPanelHost {
    MODPanelWindow *_window;
    UIImageView *_backdrop;
    UIView *_content;
    MODPanelEdge _edge;
    CGFloat _progress;
    CGFloat _revealDistance;
    CGFloat _dragStartProgress;
    MODSpringAnimation *_spring;
    NSArray<UIView *> *_cascadeViews;
    NSArray<NSNumber *> *_cascadeDelays;   // fraction of progress before each view starts
    BOOL _interactive;
    BOOL _dismissing;
    NSUInteger _frostGeneration;
}

+ (instancetype)shared {
    static MODPanelHost *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (UIViewController *)presentingViewController {
    return _window.rootViewController;
}

#pragma mark Construction

- (void)ensureWindow {
    if (_window) return;
    _window = [[MODPanelWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.windowLevel = MODPanelWindowLevel;
    _window.backgroundColor = [UIColor clearColor];
    _window.opaque = NO;
    MODPanelRootController *root = [MODPanelRootController new];
    __weak MODPanelHost *weakSelf = self;
    root.escape = ^{ [weakSelf dismissAnimated:YES completion:nil]; };
    _window.rootViewController = root;
    UIView *container = root.view;
    container.backgroundColor = [UIColor clearColor];

    _backdrop = [[UIImageView alloc] initWithFrame:container.bounds];
    _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _backdrop.contentMode = UIViewContentModeScaleToFill;
    _backdrop.userInteractionEnabled = YES;
    [container addSubview:_backdrop];

    _content = [[UIView alloc] initWithFrame:CGRectZero];
    _content.backgroundColor = [UIColor clearColor];
    _content.accessibilityViewIsModal = YES;
    [container addSubview:_content];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped)];
    tap.delegate = self;
    [container addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.delegate = self;
    [container addGestureRecognizer:pan];
}

- (void)captureFrost {
    NSUInteger generation = ++_frostGeneration;
    BOOL dark = [MODTheme current].dark;
    // Until the frost is ready (one or two frames), a plain dim stands in.
    _backdrop.image = nil;
    _backdrop.backgroundColor = dark ? [UIColor colorWithWhite:0 alpha:0.6] : [UIColor colorWithWhite:1 alpha:0.7];
    CGImageRef screen = MODCopyScreenImage();
    if (!screen) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        UIImage *frost = MODMakeFrost(screen, dark);
        CGImageRelease(screen);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_frostGeneration || !frost || !self->_isPresenting) return;
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = [MODAnimationCoordinator shared].animationsEnabled ? 0.18 : 0;
            [self->_backdrop.layer addAnimation:fade forKey:@"mod.frost"];
            self->_backdrop.image = frost;
            self->_backdrop.backgroundColor = [UIColor blackColor];   // image is opaque; no blending
        });
    });
}

- (void)installPanel:(UIView<MODPanel> *)panel edge:(MODPanelEdge)edge {
    // Capture before our window becomes visible so the frost shows what is beneath.
    if (!_isPresenting) {
        [self ensureWindow];
        [self captureFrost];
    }
    if (_currentPanel && _currentPanel != panel) [self tearDownCurrentPanel];
    _currentPanel = panel;
    _edge = edge;
    if (panel.superview != _content) [_content addSubview:panel];

    CGRect bounds = _window.rootViewController.view.bounds;
    CGFloat height = MIN([panel panelHeightForBounds:bounds], bounds.size.height - MODTopInset - MODBottomInset);
    CGFloat y = edge == MODPanelEdgeTop ? MODTopInset : bounds.size.height - height - MODBottomInset;
    _content.transform = CGAffineTransformIdentity;
    _content.frame = CGRectMake(0, y, bounds.size.width, height);
    panel.frame = _content.bounds;
    _revealDistance = edge == MODPanelEdgeTop ? CGRectGetMaxY(_content.frame) : bounds.size.height - y;

    _dismissing = NO;
    _window.hidden = NO;
    _isPresenting = YES;
    MODGuarded(panel.panelModule, @"panelWillAppear", ^{
        if ([panel respondsToSelector:@selector(panelWillAppear)]) [panel panelWillAppear];
    });
    [self prepareCascadeForPanel:panel];
}

// Delay per view proportional to its distance from the entry edge: the row
// nearest your finger arrives first, the far rows follow.
- (void)prepareCascadeForPanel:(UIView<MODPanel> *)panel {
    [panel layoutIfNeeded];
    NSArray<UIView *> *views = [panel respondsToSelector:@selector(panelAnimatedViews)] ? [panel panelAnimatedViews] : nil;
    NSMutableArray *delays = [NSMutableArray arrayWithCapacity:views.count];
    CGFloat height = MAX(panel.bounds.size.height, 1);
    for (UIView *view in views) {
        CGPoint center = [view.superview convertPoint:view.center toView:panel];
        CGFloat fromEdge = _edge == MODPanelEdgeTop ? center.y : height - center.y;
        [delays addObject:@(0.32 * MAX(0, MIN(1, fromEdge / height)))];
    }
    _cascadeViews = views;
    _cascadeDelays = delays;
}

- (void)resetCascade {
    for (UIView *view in _cascadeViews) {
        view.transform = CGAffineTransformIdentity;
        view.alpha = 1;
    }
    _cascadeViews = nil;
    _cascadeDelays = nil;
}

- (void)tearDownCurrentPanel {
    UIView<MODPanel> *panel = _currentPanel;
    _currentPanel = nil;
    if (!panel) return;
    [[MODAnimationCoordinator shared] stopAnimationsInView:panel];
    [panel removeFromSuperview];
    MODGuarded(panel.panelModule, @"panelDidDisappear", ^{
        if ([panel respondsToSelector:@selector(panelDidDisappear)]) [panel panelDidDisappear];
    });
}

#pragma mark Progress

// 0 = hidden at its edge, 1 = fully presented; values above 1 are rubber-band
// stretch or spring overshoot. Transform and opacity only.
- (void)applyProgress:(CGFloat)progress {
    _progress = progress;
    CGFloat p = MAX(0, progress);
    BOOL reduced = [MODAnimationCoordinator shared].reducedMotion;
    CGFloat direction = _edge == MODPanelEdgeTop ? -1 : 1;
    _backdrop.alpha = MIN(1, p);
    if (reduced) {
        _content.transform = CGAffineTransformIdentity;
        _content.alpha = MIN(1, p);
        return;
    }
    // The sheet travels with the finger; past 1 it keeps moving a little (overshoot/stretch).
    _content.transform = CGAffineTransformMakeTranslation(0, (1 - p) * _revealDistance * direction);
    if (!_cascadeViews.count) {
        _content.alpha = MIN(1, p * 1.6);
        return;
    }
    _content.alpha = 1;
    // Cascade: each element grows from 86% and slides in from the edge on its own schedule.
    for (NSUInteger i = 0; i < _cascadeViews.count; i++) {
        CGFloat delay = _cascadeDelays[i].floatValue;
        CGFloat t = (p - delay) / (1 - delay);
        CGFloat clamped = MAX(0, t);
        CGFloat scale = 0.86 + 0.14 * clamped;   // >1 during overshoot: a subtle swell
        CGFloat lag = (1 - MIN(1, clamped)) * 22 * direction;
        UIView *view = _cascadeViews[i];
        view.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, lag), scale, scale);
        view.alpha = MAX(0, MIN(1, clamped * 1.5));
    }
}

- (void)springToProgress:(CGFloat)target velocity:(CGFloat)velocity response:(CGFloat)response
                 damping:(CGFloat)damping completion:(void (^)(void))completion {
    [_spring cancel];
    __weak MODPanelHost *weakSelf = self;
    _spring = [[MODAnimationCoordinator shared] springFrom:_progress to:target velocity:velocity
                                                  response:response damping:damping
                                                    update:^(CGFloat value) { [weakSelf applyProgress:value]; }
                                                completion:^(BOOL finished) {
        if (finished && completion) completion();
    }];
}

// Presenting: lively, one soft overshoot. Dismissing: quick, no bounce.
- (void)springOpenWithVelocity:(CGFloat)velocity {
    [self springToProgress:1 velocity:velocity response:0.44 damping:0.78 completion:^{
        [self resetCascade];   // settle exactly at identity
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self->_currentPanel);
    }];
}

#pragma mark Presentation

- (void)presentPanel:(UIView<MODPanel> *)panel fromEdge:(MODPanelEdge)edge animated:(BOOL)animated {
    if (!panel) return;
    _interactive = NO;
    [_spring cancel];
    [self installPanel:panel edge:edge];
    [self applyProgress:0];
    if (!animated) {
        [self applyProgress:1];
        [self resetCascade];
        return;
    }
    [self springOpenWithVelocity:0];
}

- (void)beginInteractivePresentationOfPanel:(UIView<MODPanel> *)panel fromEdge:(MODPanelEdge)edge {
    if (!panel) return;
    _interactive = YES;
    [_spring cancel];
    [self installPanel:panel edge:edge];
    [self applyProgress:0];
}

- (void)updateInteractivePresentationWithDistance:(CGFloat)distance {
    if (!_interactive) return;
    CGFloat d = MAX(_revealDistance, 1);
    // 1:1 with the finger, then rubber-band past fully open.
    CGFloat progress = distance <= d ? distance / d : 1 + MODRubberBand(distance - d, d) / d;
    [self applyProgress:progress];
}

- (void)endInteractivePresentationWithVelocity:(CGFloat)velocity cancelled:(BOOL)cancelled {
    if (!_interactive) return;
    _interactive = NO;
    BOOL open = !cancelled && (velocity > 250 || (_progress > 0.35 && velocity > -250));
    // Hand the finger's speed to the spring (points/s -> progress/s): no jolt at release.
    CGFloat progressVelocity = velocity / MAX(_revealDistance, 1);
    if (open) {
        [self springOpenWithVelocity:progressVelocity];
    } else {
        [self dismissWithVelocity:progressVelocity completion:nil];
    }
}

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (!animated) {
        if (!_isPresenting || _dismissing) {
            if (completion) completion();
            return;
        }
        [_spring cancel];
        _dismissing = YES;
        [self applyProgress:0];
        [self finishDismissal:completion];
        return;
    }
    [self dismissWithVelocity:0 completion:completion];
}

- (void)dismissWithVelocity:(CGFloat)velocity completion:(void (^)(void))completion {
    if (!_isPresenting || _dismissing) {
        if (completion) completion();
        return;
    }
    _dismissing = YES;
    _interactive = NO;
    if (!_cascadeViews.count && _currentPanel) [self prepareCascadeForPanel:_currentPanel];
    [self springToProgress:0 velocity:velocity response:0.30 damping:1 completion:^{
        [self finishDismissal:completion];
    }];
}

- (void)finishDismissal:(void (^)(void))completion {
    if (!_dismissing) return;   // a new presentation started meanwhile
    _dismissing = NO;
    _isPresenting = NO;
    _window.hidden = YES;
    _backdrop.image = nil;      // ~38 KB, but no reason to keep it
    _frostGeneration++;
    [self resetCascade];
    [self tearDownCurrentPanel];
    if (completion) completion();
}

- (void)releaseResources {
    if (_isPresenting) return;
    [_spring cancel];
    _spring = nil;
    [self tearDownCurrentPanel];
    _window.hidden = YES;
    _window.rootViewController = nil;
    _window = nil;
    _backdrop = nil;
    _content = nil;
}

#pragma mark Gestures

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *view = touch.view;
    if ([recognizer isKindOfClass:[UITapGestureRecognizer class]]) {
        // Taps on the frost or in gaps between tiles dismiss; taps on content don't.
        return view == _backdrop || view == _content || view == _currentPanel || view == _window.rootViewController.view;
    }
    // Drags: sliders and scroll views keep their own.
    for (UIView *v = view; v && v != _content; v = v.superview) {
        if ([v isKindOfClass:[MODVerticalSlider class]] || [v isKindOfClass:[UISlider class]] ||
            [v isKindOfClass:[UIScrollView class]]) return NO;
    }
    return YES;
}

- (void)backgroundTapped {
    if (!_interactive) [self dismissAnimated:YES completion:nil];
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    if (_dismissing || _interactive) return;
    // Positive = toward the edge the panel came from (hiding it).
    CGFloat sign = _edge == MODPanelEdgeTop ? -1 : 1;
    CGFloat travel = [pan translationInView:pan.view].y * sign;
    CGFloat d = MAX(_revealDistance, 1);
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [_spring cancel];   // catch the panel mid-flight
            _dragStartProgress = _progress;
            if (!_cascadeViews.count && _currentPanel) [self prepareCascadeForPanel:_currentPanel];
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat progress = _dragStartProgress - travel / d;
            if (progress > 1) progress = 1 + MODRubberBand((progress - 1) * d, d) / d;   // pulling further open stretches
            [self applyProgress:progress];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocity = [pan velocityInView:pan.view].y * sign;   // positive = closing
            if (pan.state == UIGestureRecognizerStateEnded && (velocity > 400 || _progress < 0.7)) {
                [self dismissWithVelocity:-velocity / d completion:nil];
            } else {
                [self springOpenWithVelocity:-velocity / d];
            }
            break;
        }
        default:
            break;
    }
}

@end
