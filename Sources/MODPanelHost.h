#import <UIKit/UIKit.h>
#import "MODSettings.h"

typedef NS_ENUM(NSInteger, MODPanelEdge) {
    MODPanelEdgeTop,      // pulled down from the top (modern Control Center)
    MODPanelEdgeBottom,   // pushed up from the bottom
};

// A panel is a view presented by the shared host.
@protocol MODPanel <NSObject>
@property (nonatomic, readonly) MODModule panelModule;
- (CGFloat)panelHeightForBounds:(CGRect)bounds;
@optional
// Views that cascade in from the entry edge during presentation (the ones
// nearest the edge arrive first). Their transform/alpha belong to the host
// while a transition runs.
- (NSArray<UIView *> *)panelAnimatedViews;
- (void)panelWillAppear;     // start observers, refresh data
- (void)panelDidDisappear;   // stop observers, timers, release heavy content
@end

// One secure window (visible above the lock screen, like SpringBoard's own
// secure windows) that hosts at most one ModernOS panel at a time over a
// frosted backdrop. The frost is static: one screen capture per presentation,
// downscaled 8x and blurred off the main thread, then shown as a single opaque
// image — iOS 9's frosted look without live blur on the A5.
@interface MODPanelHost : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isPresenting;
@property (nonatomic, readonly, strong) UIView<MODPanel> *currentPanel;
@property (nonatomic, readonly, strong) UIViewController *presentingViewController;  // for alerts

- (void)presentPanel:(UIView<MODPanel> *)panel fromEdge:(MODPanelEdge)edge animated:(BOOL)animated;

// Interactive presentation driven by a system edge gesture. `distance` is the
// finger's travel in the reveal direction (positive reveals more); `velocity`
// is measured in the same direction.
- (void)beginInteractivePresentationOfPanel:(UIView<MODPanel> *)panel fromEdge:(MODPanelEdge)edge;
- (void)updateInteractivePresentationWithDistance:(CGFloat)distance;
- (void)endInteractivePresentationWithVelocity:(CGFloat)velocity cancelled:(BOOL)cancelled;

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion;

// Drops the window, backdrop and all panel views (memory warning, lock).
- (void)releaseResources;

@end
