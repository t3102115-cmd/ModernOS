#import <UIKit/UIKit.h>

// A running spring. Cancel it to take over (e.g. the user grabs a panel mid-flight).
@interface MODSpringAnimation : NSObject
@property (nonatomic, readonly) CGFloat value;
@property (nonatomic, readonly) CGFloat velocity;   // units per second, for hand-off to a gesture
@property (nonatomic, readonly, getter=isRunning) BOOL running;
- (void)cancel;
@end

// The single animation policy for ModernOS. Every feature animates through
// these helpers so motion, reduced motion and "animations off" are applied
// consistently. Only transform and opacity are animated.
//
// Springs are evaluated in closed form (the analytic solution of a damped
// harmonic oscillator, like SwiftUI's spring(response:dampingFraction:)): no
// numeric integration, exact at any frame, velocity-continuous when a gesture
// hands over. A CADisplayLink drives them only while something is moving and
// is invalidated as soon as the spring settles — nothing ticks while idle.
@interface MODAnimationCoordinator : NSObject

+ (instancetype)shared;

// Re-reads the animation settings (called on preference changes).
- (void)reloadSettings;

@property (nonatomic, readonly) BOOL animationsEnabled;
@property (nonatomic, readonly) BOOL reducedMotion;

// Panel transition duration (~0.2 s, 0 when animations are off).
- (NSTimeInterval)panelDuration;
// Duration for finishing an interactive gesture given the remaining distance and velocity.
- (NSTimeInterval)durationForDistance:(CGFloat)distance velocity:(CGFloat)velocity;

// Drives `update` from `from` to `to`. `response` is the period of the
// undamped oscillation in seconds (smaller = snappier), `damping` the damping
// fraction (1 = no overshoot, ~0.8 = one gentle overshoot). With animations off
// the final value is applied at once; under Reduce Motion damping becomes 1.
- (MODSpringAnimation *)springFrom:(CGFloat)from
                                to:(CGFloat)to
                          velocity:(CGFloat)velocity
                          response:(CGFloat)response
                           damping:(CGFloat)damping
                            update:(void (^)(CGFloat value))update
                        completion:(void (^)(BOOL finished))completion;

// UIKit spring for discrete changes (press release, pills, layout). Runs in the
// render server, so it stays smooth even if SpringBoard's main thread is busy.
- (void)springAnimations:(void (^)(void))animations
                duration:(NSTimeInterval)duration
                 damping:(CGFloat)damping
                velocity:(CGFloat)velocity
              completion:(void (^)(BOOL finished))completion;

// Runs a panel transition. Under reduced motion `movement` is skipped and only
// `fade` runs (crossfade). `completion` always runs on the main thread.
- (void)animateWithDuration:(NSTimeInterval)duration
                   movement:(void (^)(void))movement
                       fade:(void (^)(void))fade
                 completion:(void (^)(BOOL finished))completion;

// Pressed-state feedback: quick squeeze down, springy release.
- (void)animatePress:(UIView *)view pressed:(BOOL)pressed;

// A small "pop" (scale up and settle) for state changes such as a toggle.
- (void)popView:(UIView *)view;

// Content change (e.g. expand/collapse of a notification group), springy.
- (void)animateLayout:(void (^)(void))layout completion:(void (^)(BOOL finished))completion;

// Cancels running animations on a view tree before it is hidden.
- (void)stopAnimationsInView:(UIView *)view;

@end

// Rubber band: maps an overshoot `x` beyond a limit to a diminishing offset,
// the same curve iOS scroll views use (coefficient 0.55).
FOUNDATION_EXTERN CGFloat MODRubberBand(CGFloat x, CGFloat dimension);
