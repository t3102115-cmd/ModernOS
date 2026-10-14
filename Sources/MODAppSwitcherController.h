#import "MODCoordinator.h"

@class SBDeckSwitcherViewController;

// Decorates the native iOS 9 card ("deck") switcher instead of replacing it:
// horizontal card navigation, icons and names, lazy snapshot loading, swipe-up
// to quit, and app activation all remain SpringBoard's own code. ModernOS adds
// rounded cards while the switcher rests, removes the per-card blur of stacked
// cards (a GPU cost on the A5 and a dated look), and adds a Home button.
// Apps are never terminated by ModernOS.
@interface MODAppSwitcherController : NSObject <MODModuleController>

- (BOOL)overridesBlur;   // -_blurForIndex:scrollProgress: returns 0 when YES
- (void)deckDidAppear:(SBDeckSwitcherViewController *)deck;
- (void)deckDidAddContainer:(UIView *)container inDeck:(SBDeckSwitcherViewController *)deck;
- (void)deckWillDismiss:(SBDeckSwitcherViewController *)deck;

@end
