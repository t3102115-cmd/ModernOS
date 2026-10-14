#import "MODAppSwitcherController.h"
#import "MODPrivate.h"
#import "MODTheme.h"
#import "MODComponents.h"
#import "MODSystemAdapters.h"
#import "MODAnimationCoordinator.h"
#import <objc/runtime.h>

static const NSInteger MODPillBarTag = 0x4D4F4410;
static const NSTimeInterval MODClearConfirmWindow = 3.0;

@interface NSObject (MODSwitcherContentDelegate)
// SBMainSwitcherViewController, verified on 9.3.6 (c16@0:4@8@12 / v16@0:4@8@12).
- (BOOL)switcherContentController:(id)controller canDeleteItem:(id)item;
- (void)switcherContentController:(id)controller deletedItem:(id)item;
@end

@interface SBDeckSwitcherViewController (MODVerified)
- (id)delegate;
- (NSArray *)displayItems;
@end

@interface SBDeckSwitcherItemContainer (MODVerified)
- (UIView *)pageView;
@end

@implementation MODAppSwitcherController {
    __weak SBDeckSwitcherViewController *_deck;
    BOOL _resting;   // switcher fully presented and not dismissing
    NSMapTable<UIView *, NSNumber *> *_originalRadius;   // weak keys: containers we rounded
    NSHashTable<UIView *> *_shadowed;                     // weak: containers we gave a shadow
    UIButton *_clearButton;
    NSDate *_clearArmedAt;
    BOOL _clearing;
}

- (instancetype)init {
    if ((self = [super init])) {
        _originalRadius = [NSMapTable weakToStrongObjectsMapTable];
        _shadowed = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)activate {}

- (void)deactivate {
    SBDeckSwitcherViewController *deck = _deck;
    [self restoreCards];
    [[deck.view viewWithTag:MODPillBarTag] removeFromSuperview];
    _deck = nil;
    _resting = NO;
}

- (void)settingsDidChange:(MODSettings *)settings {
    SBDeckSwitcherViewController *deck = _deck;
    if (!_resting || !deck) return;
    [self restoreCards];
    for (UIView *container in [self visibleContainersOf:deck]) [self decorateContainer:container animated:NO];
    [[deck.view viewWithTag:MODPillBarTag] removeFromSuperview];
    [self installPillBarIn:deck.view];
}

- (BOOL)overridesBlur {
    return [MODSettings current].switcherReduceBlur;
}

- (NSArray<UIView *> *)visibleContainersOf:(SBDeckSwitcherViewController *)deck {
    NSArray *containers = [deck respondsToSelector:@selector(_visibleItemContainers)] ? [deck _visibleItemContainers] : nil;
    return [containers isKindOfClass:[NSArray class]] ? containers : @[];
}

#pragma mark Cards: corners (native corner-radius progress) and shadows

- (void)decorateContainer:(UIView *)container animated:(BOOL)animated {
    MODSettings *settings = [MODSettings current];
    if (settings.switcherRoundedCards && [container respondsToSelector:@selector(setContentCornerRadiusProgress:)] &&
        [container respondsToSelector:@selector(contentCornerRadiusProgress)]) {
        SBDeckSwitcherItemContainer *item = (SBDeckSwitcherItemContainer *)container;
        if (![_originalRadius objectForKey:container]) {
            [_originalRadius setObject:@([item contentCornerRadiusProgress]) forKey:container];
        }
        [item setContentCornerRadiusProgress:1.0];
    }
    if (settings.switcherCardShadows) [self addShadowToContainer:container animated:animated];
}

// The shadow lives on the container with an explicit shadowPath around the
// card (pageView), so Core Animation never has to compute it from content:
// no offscreen pass, and it is unaffected by the card's own clipping.
- (void)addShadowToContainer:(UIView *)container animated:(BOOL)animated {
    UIView *page = [container respondsToSelector:@selector(pageView)] ? [(SBDeckSwitcherItemContainer *)container pageView] : nil;
    if (![page isKindOfClass:[UIView class]] || page.superview == nil) return;
    CGRect card = [page.superview convertRect:page.frame toView:container];
    if (CGRectIsEmpty(card)) return;
    CALayer *layer = container.layer;
    layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:10].CGPath;
    layer.shadowColor = [UIColor blackColor].CGColor;
    layer.shadowOffset = CGSizeMake(0, 6);
    layer.shadowRadius = 14;
    float target = 0.38f;
    if (animated && [MODAnimationCoordinator shared].animationsEnabled) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        fade.fromValue = @(layer.shadowOpacity);
        fade.toValue = @(target);
        fade.duration = 0.3;
        [layer addAnimation:fade forKey:@"mod.shadow"];
    }
    layer.shadowOpacity = target;
    [_shadowed addObject:container];
}

- (void)restoreCards {
    for (UIView *container in [[_originalRadius keyEnumerator] allObjects]) {
        NSNumber *original = [_originalRadius objectForKey:container];
        if ([container respondsToSelector:@selector(setContentCornerRadiusProgress:)]) {
            [(SBDeckSwitcherItemContainer *)container setContentCornerRadiusProgress:original.floatValue];
        }
    }
    [_originalRadius removeAllObjects];
    for (UIView *container in _shadowed.allObjects) {
        [container.layer removeAnimationForKey:@"mod.shadow"];
        container.layer.shadowOpacity = 0;
        container.layer.shadowPath = NULL;
    }
    [_shadowed removeAllObjects];
}

#pragma mark Hook entry points

- (void)deckDidAppear:(SBDeckSwitcherViewController *)deck {
    _deck = deck;
    _resting = YES;
    for (UIView *container in [self visibleContainersOf:deck]) [self decorateContainer:container animated:YES];
    [self installPillBarIn:deck.view];
}

- (void)deckDidAddContainer:(UIView *)container inDeck:(SBDeckSwitcherViewController *)deck {
    if (_resting && deck == _deck) [self decorateContainer:container animated:YES];
}

- (void)deckWillDismiss:(SBDeckSwitcherViewController *)deck {
    if (deck != _deck || !_resting) return;
    _resting = NO;
    _clearArmedAt = nil;
    // Hand card geometry back to the native transition before it animates.
    [self restoreCards];
    UIView *bar = [deck.view viewWithTag:MODPillBarTag];
    MODAnimationCoordinator *animator = [MODAnimationCoordinator shared];
    [animator springAnimations:^{
        bar.alpha = 0;
        bar.transform = CGAffineTransformMakeTranslation(0, 30);
    } duration:0.3 damping:1 velocity:0 completion:^(BOOL finished) { [bar removeFromSuperview]; }];
}

#pragma mark Pill bar: Home and Clear All

- (UIButton *)pillWithGlyph:(MODGlyph)glyph title:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [MODTheme current].glassBackground;
    button.layer.cornerRadius = 18;
    button.tintColor = [UIColor whiteColor];
    button.titleLabel.font = [[MODTheme current] fontOfSize:14 weight:UIFontWeightSemibold];
    [button setImage:[MODIcons glyph:glyph size:16] forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(pillDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [button addTarget:self action:@selector(pillUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                                                                       UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return button;
}

- (void)pillDown:(UIButton *)button { [[MODAnimationCoordinator shared] animatePress:button pressed:YES]; }
- (void)pillUp:(UIButton *)button { [[MODAnimationCoordinator shared] animatePress:button pressed:NO]; }

- (void)installPillBarIn:(UIView *)view {
    MODSettings *settings = [MODSettings current];
    if (!view || [view viewWithTag:MODPillBarTag] || (!settings.switcherHomeButton && !settings.switcherClearAll)) return;
    NSMutableArray<UIButton *> *pills = [NSMutableArray array];
    if (settings.switcherHomeButton) {
        UIButton *home = [self pillWithGlyph:MODGlyphHome title:@"  Home" action:@selector(homeTapped)];
        home.accessibilityLabel = @"Go to Home Screen";
        [pills addObject:home];
    }
    if (settings.switcherClearAll) {
        _clearButton = [self pillWithGlyph:MODGlyphClose title:@"  Clear All" action:@selector(clearTapped)];
        _clearButton.accessibilityLabel = @"Close all apps";
        _clearButton.accessibilityHint = @"Tap twice to confirm";
        [pills addObject:_clearButton];
    }
    CGFloat w = 118, h = 36, gap = 10, total = pills.count * w + (pills.count - 1) * gap;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(floor((view.bounds.size.width - total) / 2),
                                                           view.bounds.size.height - h - 14, total, h)];
    bar.tag = MODPillBarTag;
    bar.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    [pills enumerateObjectsUsingBlock:^(UIButton *pill, NSUInteger i, BOOL *stop) {
        pill.frame = CGRectMake(i * (w + gap), 0, w, h);
        [bar addSubview:pill];
    }];
    [view addSubview:bar];

    // Pills rise in with a soft bounce, one after the other.
    MODAnimationCoordinator *animator = [MODAnimationCoordinator shared];
    [pills enumerateObjectsUsingBlock:^(UIButton *pill, NSUInteger i, BOOL *stop) {
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, 40);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [animator springAnimations:^{
                pill.alpha = 1;
                pill.transform = CGAffineTransformIdentity;
            } duration:0.55 damping:0.7 velocity:0 completion:nil];
        });
    }];
}

- (void)homeTapped {
    if (![MODSystemAdapters dismissSwitcherToHome]) {
        NSLog(@"[ModernOS] switcher home request was not accepted by SpringBoard");
    }
}

// First tap arms (the pill turns red and asks), a second tap within 3 s clears.
// Apps are quit only on this explicit, confirmed request.
- (void)clearTapped {
    if (_clearing) return;
    if (!_clearArmedAt || -[_clearArmedAt timeIntervalSinceNow] > MODClearConfirmWindow) {
        _clearArmedAt = [NSDate date];
        [self setClearArmed:YES];
        NSDate *armed = _clearArmedAt;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MODClearConfirmWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_clearArmedAt == armed && !self->_clearing) {
                self->_clearArmedAt = nil;
                [self setClearArmed:NO];
            }
        });
        return;
    }
    _clearArmedAt = nil;
    [self clearAll];
}

- (void)setClearArmed:(BOOL)armed {
    UIButton *button = _clearButton;
    [UIView animateWithDuration:0.2 animations:^{
        button.backgroundColor = armed ? [UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:0.9] : [MODTheme current].glassBackground;
    }];
    [button setTitle:armed ? @"  Tap to Clear" : @"  Clear All" forState:UIControlStateNormal];
    [[MODAnimationCoordinator shared] popView:button];
}

// Uses the same native path a swipe-up-to-quit takes after its animation:
// the switcher's delegate is told the item was deleted, then SpringBoard quits
// the app and removes the card with its own animation. Staggered for a cascade.
- (void)clearAll {
    SBDeckSwitcherViewController *deck = _deck;
    id delegate = [deck respondsToSelector:@selector(delegate)] ? [deck delegate] : nil;
    if (![delegate respondsToSelector:@selector(switcherContentController:deletedItem:)] ||
        ![delegate respondsToSelector:@selector(switcherContentController:canDeleteItem:)] ||
        ![deck respondsToSelector:@selector(displayItems)]) {
        NSLog(@"[ModernOS] clear all unavailable: switcher delegate not as expected");
        [self setClearArmed:NO];
        return;
    }
    Class displayItemClass = objc_getClass("SBDisplayItem");
    NSMutableArray *items = [NSMutableArray array];
    for (id item in [[deck displayItems] copy]) {
        if (displayItemClass && ![item isKindOfClass:displayItemClass]) continue;
        if ([item respondsToSelector:@selector(isHomeScreenDisplayItem)] && [item isHomeScreenDisplayItem]) continue;
        if ([delegate switcherContentController:deck canDeleteItem:item]) [items addObject:item];
    }
    if (!items.count) {
        [self setClearArmed:NO];
        [self homeTapped];
        return;
    }
    _clearing = YES;
    [_clearButton setTitle:@"  Clearing…" forState:UIControlStateNormal];
    __weak SBDeckSwitcherViewController *weakDeck = deck;
    [items enumerateObjectsUsingBlock:^(id item, NSUInteger i, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SBDeckSwitcherViewController *strongDeck = weakDeck;
            if (!strongDeck || strongDeck != self->_deck) return;
            [delegate switcherContentController:strongDeck deletedItem:item];
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((items.count * 0.09 + 0.45) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_clearing = NO;
        [self homeTapped];
    });
}

@end
