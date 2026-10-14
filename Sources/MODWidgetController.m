#import "MODWidgetController.h"
#import "MODTheme.h"
#import "MODComponents.h"
#import "MODPanelHost.h"
#import "MODSystemAdapters.h"
#import "MODWeatherService.h"
#import "MODCrashGuard.h"
#import <EventKit/EventKit.h>

static const NSUInteger MODAgendaLimit = 4;
static const NSTimeInterval MODAgendaMaxAge = 15 * 60;

#pragma mark - Calendar provider

@interface MODAgendaProvider : NSObject
- (void)eventsWithCompletion:(void (^)(NSArray<EKEvent *> *events, NSString *problem))completion;
- (void)purge;
@end

@implementation MODAgendaProvider {
    EKEventStore *_store;
    NSArray<EKEvent *> *_events;
    NSDate *_fetchedAt;
    BOOL _fetching;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)purge {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _store = nil;
    _events = nil;
    _fetchedAt = nil;
}

- (void)storeChanged {
    _fetchedAt = nil;   // refetch on next display
}

- (void)eventsWithCompletion:(void (^)(NSArray<EKEvent *> *, NSString *))completion {
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status == EKAuthorizationStatusDenied || status == EKAuthorizationStatusRestricted) {
        completion(nil, @"Calendar access unavailable");
        return;
    }
    NSDate *now = [NSDate date];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    BOOL fresh = _fetchedAt && -[_fetchedAt timeIntervalSinceNow] < MODAgendaMaxAge && [calendar isDate:_fetchedAt inSameDayAsDate:now];
    if (fresh) {
        completion([self upcoming:_events], nil);
        return;
    }
    if (_fetching) {
        completion([self upcoming:_events], nil);
        return;
    }
    if (!_store) {
        _store = [[EKEventStore alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storeChanged) name:EKEventStoreChangedNotification object:_store];
    }
    _fetching = YES;
    EKEventStore *store = _store;
    NSDate *start = [calendar startOfDayForDate:now];
    NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:2 toDate:start options:0];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSPredicate *predicate = [store predicateForEventsWithStartDate:start endDate:end calendars:nil];
        NSArray *events = [[store eventsMatchingPredicate:predicate] sortedArrayUsingSelector:@selector(compareStartDateWithEvent:)];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_fetching = NO;
            self->_events = events;
            self->_fetchedAt = [NSDate date];
            completion([self upcoming:events], nil);
        });
    });
}

- (NSArray<EKEvent *> *)upcoming:(NSArray<EKEvent *> *)events {
    NSDate *now = [NSDate date];
    NSMutableArray *result = [NSMutableArray array];
    for (EKEvent *event in events) {
        if ([event.endDate compare:now] == NSOrderedAscending) continue;
        [result addObject:event];
        if (result.count == MODAgendaLimit) break;
    }
    return result;
}

@end

#pragma mark - Dashboard panel

@interface MODDashboardPanel : UIView <MODPanel>
@property (nonatomic, weak) MODAgendaProvider *agenda;
@end

@implementation MODDashboardPanel {
    UIScrollView *_scroll;
    MODCardView *_clockCard, *_batteryCard, *_agendaCard, *_weatherCard, *_shortcutsCard;
    UILabel *_time, *_date;
    UILabel *_batteryLabel;
    CALayer *_batteryTrack, *_batteryFill;
    MODNowPlayingView *_nowPlaying;
    UILabel *_agendaTitle;
    NSMutableArray<UILabel *> *_agendaRows;
    UILabel *_weatherTemp, *_weatherDetail;
    NSMutableArray<UIButton *> *_shortcutButtons;
    NSTimer *_minuteTimer;
    NSDateFormatter *_timeFormatter, *_dateFormatter, *_eventFormatter;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        MODTheme *theme = [MODTheme current];
        self.backgroundColor = theme.panelBackground;
        _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scroll.alwaysBounceVertical = YES;
        _scroll.backgroundColor = theme.panelBackground;
        [self addSubview:_scroll];

        _timeFormatter = [NSDateFormatter new];
        _timeFormatter.timeStyle = NSDateFormatterShortStyle;
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEEdMMMM" options:0 locale:[NSLocale currentLocale]];
        _eventFormatter = [NSDateFormatter new];
        _eventFormatter.timeStyle = NSDateFormatterShortStyle;

        _clockCard = [self card];
        _time = MODMakeLabel([theme monoDigitsFontOfSize:48 weight:UIFontWeightSemibold], theme.primaryText);
        _date = MODMakeLabel([theme fontOfSize:16 weight:UIFontWeightMedium], theme.secondaryText);
        [_clockCard addSubview:_time];
        [_clockCard addSubview:_date];

        _batteryCard = [self card];
        _batteryLabel = MODMakeLabel([theme titleFont], theme.primaryText);
        _batteryTrack = [CALayer layer];
        _batteryTrack.backgroundColor = theme.tilePressed.CGColor;
        _batteryTrack.cornerRadius = 4;
        _batteryFill = [CALayer layer];
        _batteryFill.cornerRadius = 4;
        [_batteryCard addSubview:_batteryLabel];
        [_batteryCard.layer addSublayer:_batteryTrack];
        [_batteryCard.layer addSublayer:_batteryFill];

        _nowPlaying = [[MODNowPlayingView alloc] initWithFrame:CGRectZero];
        _nowPlaying.openNowPlayingApp = ^(NSString *bundleID) {
            [[MODPanelHost shared] dismissAnimated:YES completion:^{ [MODSystemAdapters openAfterUnlockBundleID:bundleID URL:nil]; }];
        };
        [_scroll addSubview:_nowPlaying];

        _agendaCard = [self card];
        _agendaTitle = MODMakeLabel([theme captionFont], theme.accent);
        _agendaTitle.text = @"UP NEXT";
        [_agendaCard addSubview:_agendaTitle];
        _agendaRows = [NSMutableArray array];
        for (NSUInteger i = 0; i < MODAgendaLimit; i++) {
            UILabel *row = MODMakeLabel([theme bodyFont], theme.primaryText);
            [_agendaRows addObject:row];
            [_agendaCard addSubview:row];
        }

        _weatherCard = [self card];
        _weatherTemp = MODMakeLabel([theme fontOfSize:34 weight:UIFontWeightMedium], theme.primaryText);
        _weatherDetail = MODMakeLabel([theme bodyFont], theme.secondaryText);
        _weatherDetail.numberOfLines = 2;
        [_weatherCard addSubview:_weatherTemp];
        [_weatherCard addSubview:_weatherDetail];

        _shortcutsCard = [self card];
        _shortcutButtons = [NSMutableArray array];
    }
    return self;
}

- (MODCardView *)card {
    MODCardView *card = [[MODCardView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:card];
    return card;
}

- (MODModule)panelModule { return MODModuleWidgets; }

- (NSArray<UIView *> *)panelAnimatedViews {
    NSMutableArray *views = [NSMutableArray array];
    for (UIView *card in @[ _clockCard, _batteryCard, _weatherCard, _nowPlaying, _agendaCard, _shortcutsCard ]) {
        if (!card.hidden) [views addObject:card];
    }
    return views;
}

- (CGFloat)panelHeightForBounds:(CGRect)bounds {
    return bounds.size.height - 40;   // leaves the status bar and a sliver of context visible
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _scroll.frame = self.bounds;
    MODTheme *theme = [MODTheme current];
    CGFloat m = theme.margin, g = theme.gap, w = self.bounds.size.width - 2 * m, y = 4;

    _clockCard.frame = CGRectMake(m, y, w, 96);
    _time.frame = CGRectMake(16, 10, w - 32, 54);
    _date.frame = CGRectMake(16, 64, w - 32, 20);
    y += 96 + g;

    CGFloat half = floor((w - g) / 2);
    _batteryCard.frame = CGRectMake(m, y, half, 76);
    _batteryLabel.frame = CGRectMake(14, 12, half - 28, 20);
    _batteryTrack.frame = CGRectMake(14, 44, half - 28, 8);
    [self layoutBatteryFill];
    _weatherCard.hidden = ![MODSettings current].weatherEnabled;
    if (!_weatherCard.hidden) {
        _weatherCard.frame = CGRectMake(m + half + g, y, half, 76);
        _weatherTemp.frame = CGRectMake(14, 6, half - 28, 40);
        _weatherDetail.frame = CGRectMake(14, 44, half - 28, 28);
    } else {
        _batteryCard.frame = CGRectMake(m, y, w, 76);
        _batteryLabel.frame = CGRectMake(14, 12, w - 28, 20);
        _batteryTrack.frame = CGRectMake(14, 44, w - 28, 8);
        [self layoutBatteryFill];
    }
    y += 76 + g;

    _nowPlaying.frame = CGRectMake(m, y, w, 80);
    y += 80 + g;

    CGFloat rowH = 22;
    NSUInteger visibleRows = 0;
    for (UILabel *row in _agendaRows) if (row.text.length) visibleRows++;
    CGFloat agendaH = 36 + MAX(1, visibleRows) * rowH + 8;
    _agendaCard.frame = CGRectMake(m, y, w, agendaH);
    _agendaTitle.frame = CGRectMake(14, 10, w - 28, 18);
    for (NSUInteger i = 0; i < _agendaRows.count; i++) {
        _agendaRows[i].frame = CGRectMake(14, 34 + i * rowH, w - 28, rowH);
    }
    y += agendaH + g;

    _shortcutsCard.hidden = _shortcutButtons.count == 0;
    if (!_shortcutsCard.hidden) {
        _shortcutsCard.frame = CGRectMake(m, y, w, 86);
        CGFloat bw = floor((w - 16) / 4);
        for (NSUInteger i = 0; i < _shortcutButtons.count; i++) {
            _shortcutButtons[i].frame = CGRectMake(8 + i * bw, 8, bw, 70);
        }
        y += 86 + g;
    }
    _scroll.contentSize = CGSizeMake(self.bounds.size.width, y + 8);
}

- (void)layoutBatteryFill {
    NSInteger percent = MAX(0, [MODSystemAdapters batteryPercent]);
    CGRect track = _batteryTrack.frame;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _batteryFill.frame = CGRectMake(track.origin.x, track.origin.y, round(track.size.width * percent / 100.0), track.size.height);
    [CATransaction commit];
}

#pragma mark Lifecycle (everything below runs only while visible)

- (void)panelWillAppear {
    [self refreshClock];
    [self scheduleMinuteTimer];
    [self refreshBattery];
    [self rebuildShortcuts];
    [_nowPlaying refresh];
    [self refreshAgenda];
    [self refreshWeather];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(refreshBattery) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refreshBattery) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(significantTimeChange) name:UIApplicationSignificantTimeChangeNotification object:nil];
    [self setNeedsLayout];
}

- (void)panelDidDisappear {
    [_minuteTimer invalidate];
    _minuteTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dealloc {
    [_minuteTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)scheduleMinuteTimer {
    [_minuteTimer invalidate];
    // Fire on the next minute boundary, then re-arm (no repeating timer).
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval delay = 60.0 - fmod(now, 60.0) + 0.05;
    _minuteTimer = [NSTimer scheduledTimerWithTimeInterval:delay target:self selector:@selector(minuteTick) userInfo:nil repeats:NO];
    _minuteTimer.tolerance = 0.5;
}

- (void)minuteTick {
    _minuteTimer = nil;
    if (!self.window) return;
    [self refreshClock];
    [self refreshAgenda];   // drops events that just ended (cached data)
    [self scheduleMinuteTimer];
}

- (void)significantTimeChange {
    [self refreshClock];
    [self.agenda purge];
    [self refreshAgenda];
}

- (void)refreshClock {
    NSDate *now = [NSDate date];
    _time.text = [_timeFormatter stringFromDate:now];
    _date.text = [_dateFormatter stringFromDate:now];
}

- (void)refreshBattery {
    NSInteger percent = [MODSystemAdapters batteryPercent];
    BOOL charging = [MODSystemAdapters isCharging];
    MODTheme *theme = [MODTheme current];
    _batteryLabel.text = percent >= 0 ? [NSString stringWithFormat:@"%@Battery %ld%%", charging ? @"⚡︎ " : @"", (long)percent] : @"Battery";
    UIColor *fill = percent >= 0 && percent <= 20 && !charging ? [UIColor colorWithRed:1 green:0.27 blue:0.23 alpha:1]
                    : (charging ? [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1] : theme.accent);
    _batteryFill.backgroundColor = fill.CGColor;
    [self layoutBatteryFill];
}

- (void)refreshAgenda {
    __weak MODDashboardPanel *weakSelf = self;
    MODAgendaProvider *agenda = self.agenda;
    if (!agenda) return;
    [agenda eventsWithCompletion:^(NSArray<EKEvent *> *events, NSString *problem) {
        MODDashboardPanel *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.window) return;
        MODGuarded(MODModuleWidgets, @"agenda", ^{ [strongSelf showEvents:events problem:problem]; });
    }];
}

- (void)showEvents:(NSArray<EKEvent *> *)events problem:(NSString *)problem {
    // The dashboard can be opened from the lock screen; event details are
    // personal data that the passcode protects, so they need an unlock.
    if ([MODSystemAdapters isDeviceLocked]) {
        events = nil;
        problem = @"Unlock to see your calendar";
    }
    NSCalendar *calendar = [NSCalendar currentCalendar];
    for (NSUInteger i = 0; i < _agendaRows.count; i++) {
        UILabel *row = _agendaRows[i];
        if (i < events.count) {
            EKEvent *event = events[i];
            NSString *when = event.allDay ? @"All day" : [_eventFormatter stringFromDate:event.startDate];
            if (![calendar isDateInToday:event.startDate] && !event.allDay) when = [@"Tomorrow " stringByAppendingString:when];
            else if (![calendar isDateInToday:event.startDate]) when = @"Tomorrow";
            row.text = [NSString stringWithFormat:@"%@  ·  %@", when, event.title ?: @"Event"];
            row.textColor = [MODTheme current].primaryText;
        } else if (i == 0) {
            row.text = problem ?: @"No upcoming events";
            row.textColor = [MODTheme current].secondaryText;
        } else {
            row.text = nil;
        }
    }
    [self setNeedsLayout];
}

- (void)refreshWeather {
    MODSettings *settings = [MODSettings current];
    if (!settings.weatherEnabled) return;
    MODWeatherService *service = [MODWeatherService shared];
    [self showWeather:[service cachedWeather] error:nil fahrenheit:settings.weatherFahrenheit];
    __weak MODDashboardPanel *weakSelf = self;
    [service refreshIfStaleForLatitude:settings.weatherLatitude longitude:settings.weatherLongitude fahrenheit:settings.weatherFahrenheit
                            completion:^(MODWeather *weather, NSError *error) {
        MODDashboardPanel *strongSelf = weakSelf;
        if (strongSelf.window) [strongSelf showWeather:weather error:error fahrenheit:settings.weatherFahrenheit];
    }];
}

- (void)showWeather:(MODWeather *)weather error:(NSError *)error fahrenheit:(BOOL)fahrenheit {
    if (!weather) {
        _weatherTemp.text = @"--°";
        _weatherDetail.text = error ? @"Weather unavailable" : @"Loading…";
        return;
    }
    _weatherTemp.text = [NSString stringWithFormat:@"%.0f°%@", weather.temperature, fahrenheit ? @"F" : @"C"];
    NSInteger minutes = (NSInteger)(-[weather.fetchedAt timeIntervalSinceNow] / 60);
    NSString *age = minutes < 1 ? @"just now" : [NSString stringWithFormat:@"%ld min ago", (long)minutes];
    _weatherDetail.text = [NSString stringWithFormat:@"%@\n%@%@", weather.summary, error ? @"Offline · " : @"", age];
}

- (void)rebuildShortcuts {
    for (UIButton *b in _shortcutButtons) [b removeFromSuperview];
    [_shortcutButtons removeAllObjects];
    MODTheme *theme = [MODTheme current];
    for (NSString *bundleID in [MODSettings current].shortcutBundleIDs) {
        UIImage *icon = [MODSystemAdapters iconForBundleID:bundleID];
        if (!icon) continue;   // not installed
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setImage:icon forState:UIControlStateNormal];
        [button setTitle:[MODSystemAdapters displayNameForBundleID:bundleID] forState:UIControlStateNormal];
        [button setTitleColor:theme.primaryText forState:UIControlStateNormal];
        button.titleLabel.font = [theme captionFont];
        button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        button.accessibilityIdentifier = bundleID;
        // Icon above title.
        CGSize image = icon.size;
        button.imageEdgeInsets = UIEdgeInsetsMake(-20, 0, 0, 0);
        button.titleEdgeInsets = UIEdgeInsetsMake(image.height + 10, -image.width, 0, 0);
        [button addTarget:self action:@selector(shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_shortcutsCard addSubview:button];
        [_shortcutButtons addObject:button];
    }
}

- (void)shortcutTapped:(UIButton *)button {
    NSString *bundleID = button.accessibilityIdentifier;
    [[MODPanelHost shared] dismissAnimated:YES completion:^{
        [MODSystemAdapters openAfterUnlockBundleID:bundleID URL:nil];
    }];
}

@end

#pragma mark - Controller

@implementation MODWidgetController {
    MODDashboardPanel *_panel;
    MODAgendaProvider *_agenda;
}

- (void)activate {}

- (void)deactivate {
    MODPanelHost *host = [MODPanelHost shared];
    if (host.currentPanel == _panel) [host dismissAnimated:NO completion:nil];
    _panel = nil;
    [_agenda purge];
    _agenda = nil;
    [[MODWeatherService shared] purge];
}

- (void)settingsDidChange:(MODSettings *)settings {
    if ([MODPanelHost shared].currentPanel != _panel) _panel = nil;   // rebuilt with the new theme
}

- (void)didReceiveMemoryWarning {
    if ([MODPanelHost shared].currentPanel != _panel) _panel = nil;
    [_agenda purge];
    [[MODWeatherService shared] purge];
}

- (void)presentDashboard {
    if (!_agenda) _agenda = [MODAgendaProvider new];
    if (!_panel) _panel = [[MODDashboardPanel alloc] initWithFrame:CGRectZero];
    _panel.agenda = _agenda;
    [[MODPanelHost shared] presentPanel:_panel fromEdge:MODPanelEdgeBottom animated:YES];
}

@end
