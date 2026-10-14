#import "MODAnimationCoordinator.h"
#import "MODSettings.h"
#import <QuartzCore/QuartzCore.h>

static const NSTimeInterval MODPanelDuration = 0.20;
static const NSTimeInterval MODMinDuration = 0.12;
static const NSTimeInterval MODMaxDuration = 0.26;
static const NSTimeInterval MODFadeDuration = 0.15;
static const CFTimeInterval MODSpringMaxDuration = 2.0;   // hard stop, whatever happens

CGFloat MODRubberBand(CGFloat x, CGFloat dimension) {
    if (x <= 0 || dimension <= 0) return 0;
    return (1.0 - 1.0 / (x * 0.55 / dimension + 1.0)) * dimension;
}

#pragma mark - Spring

@interface MODSpringAnimation ()
- (instancetype)initFrom:(CGFloat)from to:(CGFloat)to velocity:(CGFloat)velocity
                response:(CGFloat)response damping:(CGFloat)damping
                  update:(void (^)(CGFloat))update completion:(void (^)(BOOL))completion;
- (void)start;
@end

@implementation MODSpringAnimation {
    CGFloat _to, _x0, _v0, _omega, _zeta;
    CFTimeInterval _startTime;
    CADisplayLink *_link;
    void (^_update)(CGFloat);
    void (^_completion)(BOOL);
}

- (instancetype)initFrom:(CGFloat)from to:(CGFloat)to velocity:(CGFloat)velocity
                response:(CGFloat)response damping:(CGFloat)damping
                  update:(void (^)(CGFloat))update completion:(void (^)(BOOL))completion {
    if ((self = [super init])) {
        _to = to;
        _x0 = from - to;   // displacement from rest
        _v0 = velocity;
        _omega = 2.0 * M_PI / MAX(response, 0.05);
        _zeta = MIN(1.0, MAX(0.1, damping));
        _value = from;
        _velocity = velocity;
        _update = [update copy];
        _completion = [completion copy];
    }
    return self;
}

// Displacement and velocity at time t (closed form).
- (void)evaluateAt:(CFTimeInterval)t displacement:(CGFloat *)x velocity:(CGFloat *)v {
    CGFloat w = _omega, z = _zeta;
    if (z >= 0.999) {
        // Critically damped: x = e^{-wt} (x0 + (v0 + w x0) t)
        CGFloat e = exp(-w * t), b = _v0 + w * _x0;
        *x = e * (_x0 + b * t);
        *v = e * (b - w * (_x0 + b * t));
    } else {
        // Underdamped: x = e^{-zwt} (x0 cos(wd t) + (v0 + zw x0)/wd sin(wd t))
        CGFloat wd = w * sqrt(1 - z * z), e = exp(-z * w * t);
        CGFloat a = _x0, b = (_v0 + z * w * _x0) / wd;
        CGFloat c = cos(wd * t), s = sin(wd * t);
        *x = e * (a * c + b * s);
        *v = e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s);
    }
}

- (void)start {
    _running = YES;
    _startTime = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval t = CACurrentMediaTime() - _startTime;
    CGFloat x, v;
    [self evaluateAt:t displacement:&x velocity:&v];
    BOOL settled = (fabs(x) < 0.0008 && fabs(v) < 0.01) || t > MODSpringMaxDuration;
    _value = settled ? _to : _to + x;
    _velocity = settled ? 0 : v;
    if (_update) _update(_value);
    if (settled) [self finish:YES];
}

- (void)finish:(BOOL)finished {
    if (!_running) return;
    _running = NO;
    [_link invalidate];   // the display link only lives while something moves
    _link = nil;
    void (^completion)(BOOL) = _completion;
    _completion = nil;
    _update = nil;
    if (completion) completion(finished);
}

- (void)cancel {
    [self finish:NO];
}

- (void)dealloc {
    [_link invalidate];
}

@end

#pragma mark - Coordinator

@implementation MODAnimationCoordinator

+ (instancetype)shared {
    static MODAnimationCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
        [shared reloadSettings];
    });
    return shared;
}

- (void)reloadSettings {
    MODSettings *settings = [MODSettings current];
    _animationsEnabled = settings.animationsEnabled;
    _reducedMotion = settings.reducedMotion;
}

- (NSTimeInterval)panelDuration {
    if (!_animationsEnabled) return 0;
    return _reducedMotion ? MODFadeDuration : MODPanelDuration;
}

- (NSTimeInterval)durationForDistance:(CGFloat)distance velocity:(CGFloat)velocity {
    if (!_animationsEnabled) return 0;
    if (_reducedMotion) return MODFadeDuration;
    distance = fabs(distance);
    velocity = fabs(velocity);
    if (velocity < 1) return MODPanelDuration;
    NSTimeInterval t = distance / velocity;
    return MIN(MODMaxDuration, MAX(MODMinDuration, t));
}

- (MODSpringAnimation *)springFrom:(CGFloat)from to:(CGFloat)to velocity:(CGFloat)velocity
                          response:(CGFloat)response damping:(CGFloat)damping
                            update:(void (^)(CGFloat))update completion:(void (^)(BOOL))completion {
    if (!_animationsEnabled) {
        if (update) update(to);
        if (completion) completion(YES);
        return nil;
    }
    if (_reducedMotion) {
        damping = 1;
        response = MIN(response, 0.3);
    }
    MODSpringAnimation *spring = [[MODSpringAnimation alloc] initFrom:from to:to velocity:velocity
                                                             response:response damping:damping
                                                               update:update completion:completion];
    [spring start];
    return spring;
}

- (void)springAnimations:(void (^)(void))animations duration:(NSTimeInterval)duration damping:(CGFloat)damping
                velocity:(CGFloat)velocity completion:(void (^)(BOOL))completion {
    if (!_animationsEnabled) {
        [UIView performWithoutAnimation:animations];
        if (completion) completion(YES);
        return;
    }
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    if (_reducedMotion) {
        [UIView animateWithDuration:MODFadeDuration delay:0 options:options animations:animations completion:completion];
        return;
    }
    [UIView animateWithDuration:duration delay:0 usingSpringWithDamping:damping initialSpringVelocity:velocity
                        options:options animations:animations completion:completion];
}

- (void)animateWithDuration:(NSTimeInterval)duration
                   movement:(void (^)(void))movement
                       fade:(void (^)(void))fade
                 completion:(void (^)(BOOL finished))completion {
    BOOL reduced = _reducedMotion;
    void (^changes)(void) = ^{
        if (movement && !reduced) movement();
        if (fade) fade();
    };
    if (duration <= 0) {
        [UIView performWithoutAnimation:^{
            if (movement) movement();   // final positions must still be applied
            if (fade) fade();
        }];
        if (completion) completion(YES);
        return;
    }
    if (reduced && movement) [UIView performWithoutAnimation:movement];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction |
                                     UIViewAnimationOptionCurveEaseOut;
    [UIView animateWithDuration:duration delay:0 options:options animations:changes completion:completion];
}

- (void)animatePress:(UIView *)view pressed:(BOOL)pressed {
    if (!_animationsEnabled || _reducedMotion) {
        view.transform = pressed ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
        return;
    }
    if (pressed) {
        // Fast squeeze: the finger should feel the tile give immediately.
        [UIView animateWithDuration:0.09 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ view.transform = CGAffineTransformMakeScale(0.92, 0.92); }
                         completion:nil];
    } else {
        // Release with a little bounce back to rest.
        [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:4
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ view.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }
}

- (void)popView:(UIView *)view {
    if (!_animationsEnabled || _reducedMotion || !view.window) return;
    CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pop.values = @[ @1.0, @1.22, @0.94, @1.0 ];
    pop.keyTimes = @[ @0, @0.35, @0.7, @1 ];
    pop.duration = 0.34;
    pop.timingFunctions = @[ [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                             [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
                             [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut] ];
    [view.layer addAnimation:pop forKey:@"mod.pop"];
}

- (void)animateLayout:(void (^)(void))layout completion:(void (^)(BOOL finished))completion {
    [self springAnimations:layout duration:0.45 damping:0.86 velocity:0 completion:completion];
}

- (void)stopAnimationsInView:(UIView *)view {
    [view.layer removeAllAnimations];
    for (UIView *subview in view.subviews) [self stopAnimationsInView:subview];
}

@end
