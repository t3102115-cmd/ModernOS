#import "MODNotificationController.h"
#import "MODLockScreenController.h"
#import "MODPrivate.h"
#import "MODTheme.h"
#import "MODComponents.h"
#import "MODAnimationCoordinator.h"
#import "MODSystemAdapters.h"
#import "MODCrashGuard.h"
#import <objc/runtime.h>

static const NSUInteger MODMaxItems = 40;   // bound the work per rebuild

#pragma mark - Model

@interface MODNotificationEntry : NSObject
@property (nonatomic, copy) NSString *bulletinID;
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, strong) NSURL *launchURL;
@property (nonatomic, copy) NSString *launchBundleID;
@end
@implementation MODNotificationEntry
@end

@interface MODNotificationGroup : NSObject
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, strong) NSMutableArray<MODNotificationEntry *> *entries;   // newest first
@property (nonatomic, readonly) NSDate *latest;
@end
@implementation MODNotificationGroup
- (NSDate *)latest { return self.entries.firstObject.date ?: [NSDate distantPast]; }
@end

static NSString *MODRelativeTime(NSDate *date) {
    if (!date) return @"";
    NSTimeInterval age = -[date timeIntervalSinceNow];
    if (age < 60) return @"now";
    if (age < 3600) return [NSString stringWithFormat:@"%dm ago", (int)(age / 60)];
    if (age < 6 * 3600) return [NSString stringWithFormat:@"%dh ago", (int)(age / 3600)];
    static NSDateFormatter *formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
    }
    return [formatter stringFromDate:date];
}

#pragma mark - Views

@interface MODNotificationCard : MODCardView
@property (nonatomic, strong) MODNotificationEntry *entry;
@property (nonatomic, copy) void (^tapped)(MODNotificationCard *card);
- (void)configureWithEntry:(MODNotificationEntry *)entry header:(NSString *)header icon:(UIImage *)icon footer:(NSString *)footer;
- (void)showHint:(NSString *)hint;
+ (CGFloat)heightForEntry:(MODNotificationEntry *)entry width:(CGFloat)width header:(BOOL)header footer:(BOOL)footer;
@end

@implementation MODNotificationCard {
    UIImageView *_icon;
    UILabel *_header, *_time, *_title, *_message, *_footer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Lock screen cards sit on the wallpaper: dark glass, white text.
        MODTheme *theme = [MODTheme current];
        UIColor *secondary = [UIColor colorWithWhite:1 alpha:0.68];
        _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _header = MODMakeLabel([theme captionFont], secondary);
        _time = MODMakeLabel([theme captionFont], secondary);
        _time.textAlignment = NSTextAlignmentRight;
        _title = MODMakeLabel([theme titleFont], [UIColor whiteColor]);
        _message = MODMakeLabel([theme bodyFont], [UIColor whiteColor]);
        _message.numberOfLines = 2;
        _footer = MODMakeLabel([theme captionFont], secondary);
        for (UIView *v in @[ _icon, _header, _time, _title, _message, _footer ]) [self addSubview:v];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)]];
    }
    return self;
}

- (void)applyTheme {
    self.backgroundColor = [MODTheme current].glassBackground;
    self.layer.cornerRadius = [MODTheme current].cardRadius;
}

+ (CGFloat)heightForEntry:(MODNotificationEntry *)entry width:(CGFloat)width header:(BOOL)header footer:(BOOL)footer {
    MODTheme *theme = [MODTheme current];
    CGFloat textWidth = width - 24;
    CGFloat h = 10;
    if (header) h += 22;
    if (entry.title.length) h += 19;
    if (entry.message.length) {
        CGRect r = [entry.message boundingRectWithSize:CGSizeMake(textWidth, theme.bodyFont.lineHeight * 2 + 1)
                                               options:NSStringDrawingUsesLineFragmentOrigin
                                            attributes:@{ NSFontAttributeName : theme.bodyFont } context:nil];
        h += ceil(r.size.height);
    }
    if (footer) h += 20;
    return h + 10;
}

- (void)configureWithEntry:(MODNotificationEntry *)entry header:(NSString *)header icon:(UIImage *)icon footer:(NSString *)footer {
    _entry = entry;
    _icon.image = icon;
    _header.text = header.uppercaseString;
    _time.text = MODRelativeTime(entry.date);
    _title.text = entry.title;
    _message.text = entry.message;
    _footer.text = footer;
    _icon.hidden = _header.hidden = header == nil;
    _time.hidden = NO;
    _footer.hidden = footer == nil;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@", header ?: @"", entry.title ?: @"", entry.message ?: @""];
    self.accessibilityHint = @"Opens after you unlock";
    [self setNeedsLayout];
}

- (void)showHint:(NSString *)hint {
    _footer.text = hint;
    _footer.hidden = NO;
    _footer.textColor = [UIColor whiteColor];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, x = 12, y = 10, tw = w - 24;
    if (!_header.hidden) {
        _icon.frame = CGRectMake(x, y, 18, 18);
        _header.frame = CGRectMake(x + 24, y, tw - 24 - 70, 18);
        _time.frame = CGRectMake(w - 12 - 70, y, 70, 18);
        y += 22;
    } else {
        _time.frame = CGRectMake(w - 12 - 70, y, 70, 18);
    }
    CGFloat titleWidth = _header.hidden ? tw - 74 : tw;
    if (_title.text.length) {
        _title.frame = CGRectMake(x, y, titleWidth, 19);
        y += 19;
    } else {
        _title.frame = CGRectZero;
    }
    if (_message.text.length) {
        CGSize s = [_message sizeThatFits:CGSizeMake(tw, CGFLOAT_MAX)];
        CGFloat h = MIN(ceil(s.height), ceil(_message.font.lineHeight * 2 + 1));
        _message.frame = CGRectMake(x, y, tw, h);
        y += h;
    }
    _footer.frame = CGRectMake(x, y + 2, tw, 16);
}

- (void)handleTap {
    if (self.tapped) self.tapped(self);
}

@end

@interface MODGroupedNotificationView : UIScrollView
@property (nonatomic, weak) MODNotificationController *controller;
// `animated`: existing cards spring to their new places, new cards slide in,
// removed cards fade out. Views are reused per bulletin, so nothing jumps.
- (void)reloadWithGroups:(NSArray<MODNotificationGroup *> *)groups expanded:(NSSet<NSString *> *)expanded animated:(BOOL)animated;
@end

#pragma mark - Controller

@interface MODNotificationController ()
- (void)toggleGroup:(NSString *)sectionID;
- (void)dismissGroup:(MODNotificationGroup *)group;
- (void)openEntry:(MODNotificationEntry *)entry fromCard:(MODNotificationCard *)card;
@end

@implementation MODGroupedNotificationView {
    NSArray<MODNotificationGroup *> *_groups;
    NSSet<NSString *> *_expanded;
    NSMutableDictionary<NSString *, MODNotificationCard *> *_cards;   // bulletinID -> card
    NSMutableDictionary<NSString *, UIView *> *_shelves;              // sectionID -> stack shelf
    NSMutableDictionary<NSString *, UIView *> *_bars;                 // sectionID -> expanded header bar
    CGFloat _laidOutWidth;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.alwaysBounceVertical = NO;
        self.showsVerticalScrollIndicator = NO;
        self.delaysContentTouches = NO;
        _cards = [NSMutableDictionary dictionary];
        _shelves = [NSMutableDictionary dictionary];
        _bars = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)reloadWithGroups:(NSArray<MODNotificationGroup *> *)groups expanded:(NSSet<NSString *> *)expanded animated:(BOOL)animated {
    _groups = groups;
    _expanded = [expanded copy];
    [self layoutGroupsAnimated:animated && self.window != nil];
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (frame.size.width != _laidOutWidth) [self layoutGroupsAnimated:NO];
}

- (UIView *)barForGroup:(MODNotificationGroup *)group width:(CGFloat)w {
    UIView *bar = _bars[group.sectionID];
    if (!bar) {
        bar = [[UIView alloc] initWithFrame:CGRectZero];
        UILabel *name = MODMakeLabel([[MODTheme current] titleFont], [UIColor whiteColor]);
        name.tag = 1;
        [bar addSubview:name];
        __weak MODGroupedNotificationView *weakSelf = self;
        NSString *sectionID = group.sectionID;
        UIButton *less = [self pillWithTitle:@"Show less" action:^{ [weakSelf.controller toggleGroup:sectionID]; }];
        less.tag = 2;
        [bar addSubview:less];
        UIButton *clear = [self pillWithTitle:nil action:^{
            MODGroupedNotificationView *strongSelf = weakSelf;
            for (MODNotificationGroup *g in strongSelf->_groups) {
                if ([g.sectionID isEqualToString:sectionID]) [strongSelf.controller dismissGroup:g];
            }
        }];
        [clear setImage:[MODIcons glyph:MODGlyphClose size:14] forState:UIControlStateNormal];
        clear.tag = 3;
        [bar addSubview:clear];
        _bars[group.sectionID] = bar;
    }
    UILabel *name = (UILabel *)[bar viewWithTag:1];
    name.text = [NSString stringWithFormat:@"%@  %lu", group.appName, (unsigned long)group.entries.count];
    name.frame = CGRectMake(4, 0, w - 130, 30);
    [bar viewWithTag:2].frame = CGRectMake(w - 124, 2, 86, 26);
    [bar viewWithTag:3].frame = CGRectMake(w - 32, 2, 30, 26);
    [bar viewWithTag:3].accessibilityLabel = [NSString stringWithFormat:@"Hide %@ notifications", group.appName];
    return bar;
}

// Places `view` at `frame`. New views enter from `origin` (scaled down, faded);
// existing ones move. Everything happens inside one spring when animated.
static void MODPlace(UIView *view, CGRect frame, CGRect origin, BOOL isNew, NSMutableArray *moves, NSMutableArray *appears) {
    if (isNew) {
        view.transform = CGAffineTransformIdentity;
        view.frame = origin;
        view.alpha = 0;
        view.transform = CGAffineTransformMakeScale(0.94, 0.94);
        [appears addObject:@[ view, [NSValue valueWithCGRect:frame] ]];
    } else {
        [moves addObject:@[ view, [NSValue valueWithCGRect:frame] ]];
    }
}

- (void)layoutGroupsAnimated:(BOOL)animated {
    CGFloat w = self.bounds.size.width - 16, x = 8, y = 4;
    _laidOutWidth = self.bounds.size.width;
    if (w <= 0) return;
    __weak MODGroupedNotificationView *weakSelf = self;
    NSMutableSet *usedCards = [NSMutableSet set], *usedShelves = [NSMutableSet set], *usedBars = [NSMutableSet set];
    NSMutableArray *moves = [NSMutableArray array], *appears = [NSMutableArray array];

    for (MODNotificationGroup *group in _groups) {
        BOOL expanded = group.entries.count > 1 && [_expanded containsObject:group.sectionID];
        BOOL stacked = !expanded && group.entries.count > 1;
        MODNotificationCard *topCard = _cards[group.entries.firstObject.bulletinID];
        CGRect stackOrigin = topCard ? topCard.frame : CGRectMake(x, y - 24, w, 60);   // new arrivals drop in from above

        if (expanded) {
            UIView *bar = [self barForGroup:group width:w];
            BOOL isNew = bar.superview != self;
            if (isNew) [self addSubview:bar];
            MODPlace(bar, CGRectMake(x, y, w, 30), CGRectMake(x, CGRectGetMinY(stackOrigin), w, 30), isNew, moves, appears);
            [usedBars addObject:group.sectionID];
            y += 34;
        }
        NSUInteger shown = expanded ? group.entries.count : 1;
        for (NSUInteger i = 0; i < shown; i++) {
            MODNotificationEntry *entry = group.entries[i];
            BOOL header = !expanded || i == 0;
            NSString *footer = stacked ? [NSString stringWithFormat:@"%lu more from %@ · tap header to expand",
                                                                     (unsigned long)group.entries.count - 1, group.appName] : nil;
            CGFloat h = [MODNotificationCard heightForEntry:entry width:w header:header footer:footer != nil];
            CGRect frame = CGRectMake(x, y, w, h);

            if (stacked) {
                UIView *shelf = _shelves[group.sectionID];
                BOOL isNew = !shelf;
                if (!shelf) {
                    shelf = [[MODCardView alloc] initWithFrame:CGRectZero];
                    shelf.backgroundColor = [MODTheme current].glassBackground;
                    _shelves[group.sectionID] = shelf;
                    [self insertSubview:shelf atIndex:0];   // behind the cards
                }
                MODPlace(shelf, CGRectMake(x + 10, y + h - 6, w - 20, 14), CGRectMake(x + 10, y + h - 20, w - 20, 14), isNew, moves, appears);
                [usedShelves addObject:group.sectionID];
            }

            MODNotificationCard *card = _cards[entry.bulletinID];
            BOOL isNew = !card;
            if (!card) {
                card = [[MODNotificationCard alloc] initWithFrame:CGRectZero];
                [card addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)]];
                _cards[entry.bulletinID] = card;
                [self addSubview:card];
            }
            [card configureWithEntry:entry header:header ? group.appName : nil icon:group.icon footer:footer];
            NSString *sectionID = group.sectionID;
            card.tapped = ^(MODNotificationCard *tappedCard) {
                MODGroupedNotificationView *strongSelf = weakSelf;
                if (!strongSelf) return;
                // Tapping the header area of a collapsed stack expands it.
                if (stacked && [tappedCard.gestureRecognizers.firstObject locationInView:tappedCard].y < 32) {
                    [strongSelf.controller toggleGroup:sectionID];
                } else {
                    [strongSelf.controller openEntry:tappedCard.entry fromCard:tappedCard];
                }
            };
            // Expanding: hidden cards fan out from under the stack's top card.
            MODPlace(card, frame, (expanded && i > 0) ? stackOrigin : CGRectOffset(frame, 0, -24), isNew, moves, appears);
            [usedCards addObject:entry.bulletinID];
            y += h + (stacked ? 16 : 8);
        }
    }

    // Views that are no longer needed fade out (or fold back into their stack).
    NSMutableArray *removals = [NSMutableArray array];
    void (^collect)(NSMutableDictionary *, NSSet *) = ^(NSMutableDictionary *pool, NSSet *used) {
        for (NSString *key in [pool.allKeys copy]) {
            if ([used containsObject:key]) continue;
            [removals addObject:pool[key]];
            [pool removeObjectForKey:key];
        }
    };
    collect(_cards, usedCards);
    collect(_shelves, usedShelves);
    collect(_bars, usedBars);

    void (^apply)(void) = ^{
        for (NSArray *move in moves) {
            UIView *view = move[0];
            view.transform = CGAffineTransformIdentity;
            view.frame = [move[1] CGRectValue];
            view.alpha = 1;
        }
        for (NSArray *appear in appears) {
            UIView *view = appear[0];
            view.transform = CGAffineTransformIdentity;
            view.frame = [appear[1] CGRectValue];
            view.alpha = 1;
        }
        for (UIView *view in removals) {
            view.alpha = 0;
            view.transform = CGAffineTransformMakeScale(0.94, 0.94);
        }
    };
    void (^cleanup)(BOOL) = ^(BOOL finished) {
        for (UIView *view in removals) [view removeFromSuperview];
    };
    self.contentSize = CGSizeMake(self.bounds.size.width, y);
    if (animated) {
        [[MODAnimationCoordinator shared] animateLayout:apply completion:cleanup];
    } else {
        [UIView performWithoutAnimation:apply];
        cleanup(YES);
    }
}

- (UIButton *)pillWithTitle:(NSString *)title action:(void (^)(void))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [MODTheme current].glassBackground;
    button.layer.cornerRadius = 13;
    button.tintColor = [UIColor whiteColor];
    button.titleLabel.font = [[MODTheme current] fontOfSize:13 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    objc_setAssociatedObject(button, @selector(pillTapped:), action, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [button addTarget:self action:@selector(pillTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)pillTapped:(UIButton *)sender {
    void (^action)(void) = objc_getAssociatedObject(sender, @selector(pillTapped:));
    if (action) action();
}

// Long press on a card hides its whole group until the next unlock.
- (void)longPressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    MODNotificationCard *card = (MODNotificationCard *)press.view;
    for (MODNotificationGroup *group in _groups) {
        if ([group.entries containsObject:card.entry]) {
            [self.controller dismissGroup:group];
            return;
        }
    }
}

@end

@implementation MODNotificationController {
    __weak SBLockScreenNotificationListController *_list;
    NSArray<MODNotificationGroup *> *_groups;
    NSUInteger _nativeCount;
    BOOL _renderable;
    BOOL _rebuildScheduled;
    NSString *_signature;
    NSMutableSet<NSString *> *_expanded;
    NSMutableSet<NSString *> *_dismissedBulletins;
    MODGroupedNotificationView *_view;
}

- (instancetype)init {
    if ((self = [super init])) {
        _expanded = [NSMutableSet set];
        _dismissedBulletins = [NSMutableSet set];
    }
    return self;
}

- (void)activate {
    if (_list) [self scheduleRebuild];
}

- (void)deactivate {
    _view = nil;
    _groups = nil;
    _renderable = NO;
    [MODLockScreenController relayoutLockScreen];   // native list comes back
}

- (void)settingsDidChange:(MODSettings *)settings {
    _view = nil;   // theme may have changed; rebuilt on next layout
    _signature = nil;
    [self scheduleRebuild];
}

- (void)didReceiveMemoryWarning {
    if (!_view.window) _view = nil;
}

- (void)deviceDidUnlock {
    // Mirrors the native list, which removes its items on unlock.
    [_expanded removeAllObjects];
    [_dismissedBulletins removeAllObjects];
    _view = nil;
    _groups = nil;
    _signature = nil;
}

- (void)nativeListDidChange:(SBLockScreenNotificationListController *)listController {
    _list = listController;
    [self scheduleRebuild];
}

- (void)scheduleRebuild {
    if (_rebuildScheduled) return;   // coalesce bursts of model updates into one pass
    _rebuildScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_rebuildScheduled = NO;
        MODGuarded(MODModuleNotifications, @"rebuild", ^{ [self rebuild]; });
    });
}

- (void)rebuild {
    SBLockScreenNotificationListController *list = _list;
    Class bulletinItemClass = objc_getClass("SBAwayBulletinListItem");
    NSUInteger count = [list respondsToSelector:@selector(count)] ? [list count] : 0;
    BOOL renderable = list && bulletinItemClass && [list respondsToSelector:@selector(listItemAtIndexPath:)] && count <= MODMaxItems;
    NSMutableDictionary<NSString *, MODNotificationGroup *> *bySection = [NSMutableDictionary dictionary];
    NSMutableString *signature = [NSMutableString string];

    for (NSUInteger i = 0; renderable && i < count; i++) {
        id item = [list listItemAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
        if (![item isKindOfClass:bulletinItemClass]) {
            renderable = NO;   // system alert, alarm, Passbook card...: keep the native list
            break;
        }
        SBAwayBulletinListItem *bulletinItem = item;
        BBBulletin *bulletin = [bulletinItem respondsToSelector:@selector(activeBulletin)] ? [bulletinItem activeBulletin] : nil;
        NSString *sectionID = [bulletin respondsToSelector:@selector(sectionID)] ? [bulletin sectionID] : nil;
        NSString *bulletinID = [bulletin respondsToSelector:@selector(bulletinID)] ? [bulletin bulletinID] : nil;
        if (!sectionID.length || !bulletinID.length) {
            renderable = NO;
            break;
        }
        [signature appendFormat:@"%@|", bulletinID];
        if ([_dismissedBulletins containsObject:bulletinID]) continue;

        MODNotificationEntry *entry = [MODNotificationEntry new];
        entry.bulletinID = bulletinID;
        entry.sectionID = sectionID;
        entry.title = [bulletin respondsToSelector:@selector(title)] ? [bulletin title] : nil;
        // The list item's message already honours per-app message privacy.
        entry.message = [bulletinItem respondsToSelector:@selector(message)] ? [bulletinItem message] : nil;
        entry.date = [bulletinItem respondsToSelector:@selector(date)] ? [bulletinItem date] : nil;
        if (!entry.date && [bulletin respondsToSelector:@selector(date)]) entry.date = [bulletin date];
        entry.icon = [bulletinItem respondsToSelector:@selector(iconImage)] ? [bulletinItem iconImage] : nil;
        BBAction *action = [bulletin respondsToSelector:@selector(defaultAction)] ? [bulletin defaultAction] : nil;
        entry.launchURL = [action respondsToSelector:@selector(launchURL)] ? [action launchURL] : nil;
        NSString *actionBundle = [action respondsToSelector:@selector(bundleID)] ? [action bundleID] : nil;
        entry.launchBundleID = actionBundle.length ? actionBundle : sectionID;

        MODNotificationGroup *group = bySection[sectionID];
        if (!group) {
            group = [MODNotificationGroup new];
            group.sectionID = sectionID;
            group.appName = [MODSystemAdapters displayNameForBundleID:sectionID];
            group.icon = entry.icon ?: [MODSystemAdapters iconForBundleID:sectionID];
            group.entries = [NSMutableArray array];
            bySection[sectionID] = group;
        }
        [group.entries addObject:entry];
    }

    NSArray *groups = [bySection.allValues sortedArrayUsingComparator:^NSComparisonResult(MODNotificationGroup *a, MODNotificationGroup *b) {
        return [b.latest compare:a.latest];
    }];
    for (MODNotificationGroup *group in groups) {
        [group.entries sortUsingComparator:^NSComparisonResult(MODNotificationEntry *a, MODNotificationEntry *b) {
            return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])];
        }];
    }
    [signature appendFormat:@"r%d", renderable];

    _renderable = renderable;
    _nativeCount = count;
    _groups = groups;
    if (![signature isEqualToString:_signature]) {
        _signature = [signature copy];
        [_view reloadWithGroups:_groups expanded:_expanded animated:YES];
        [MODLockScreenController relayoutLockScreen];
    }
}

- (UIView *)groupedViewForDisplay {
    if (!_renderable || _nativeCount == 0) return nil;
    if (!_view) {
        _view = [[MODGroupedNotificationView alloc] initWithFrame:CGRectZero];
        _view.controller = self;
        [_view reloadWithGroups:_groups expanded:_expanded animated:NO];
    }
    return _view;
}

- (void)toggleGroup:(NSString *)sectionID {
    if (!sectionID) return;
    if ([_expanded containsObject:sectionID]) [_expanded removeObject:sectionID];
    else [_expanded addObject:sectionID];
    [_view reloadWithGroups:_groups expanded:_expanded animated:YES];
}

// Hides a group from the ModernOS lock screen until the next unlock. The
// bulletins themselves are untouched and remain in Notification Center
// (iOS 9 has no per-bulletin dismissal on the lock screen).
- (void)dismissGroup:(MODNotificationGroup *)group {
    for (MODNotificationEntry *entry in group.entries) [_dismissedBulletins addObject:entry.bulletinID];
    [_expanded removeObject:group.sectionID];
    _signature = nil;
    [self rebuild];
}

- (void)openEntry:(MODNotificationEntry *)entry fromCard:(MODNotificationCard *)card {
    if (!entry) return;
    if ([MODSystemAdapters isDeviceLocked]) {
        // Authentication stays native: the app opens after the user unlocks.
        [MODSystemAdapters openAfterUnlockBundleID:entry.launchBundleID URL:entry.launchURL];
        [card showHint:@"Unlock to open"];
    } else {
        [MODSystemAdapters openBundleID:entry.launchBundleID URL:entry.launchURL];
    }
}

@end
