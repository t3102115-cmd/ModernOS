#import "MODComponents.h"
#import "MODTheme.h"
#import "MODAnimationCoordinator.h"
#import "MODSystemAdapters.h"

UILabel *MODMakeLabel(UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = font;
    label.textColor = color;
    label.backgroundColor = [UIColor clearColor];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

#pragma mark - Icons

static NSCache *sGlyphCache;

@implementation MODIcons

+ (void)purge {
    [sGlyphCache removeAllObjects];
}

static void MODTriangle(UIBezierPath *p, CGFloat x, CGFloat y, CGFloat w, CGFloat h, BOOL right) {
    if (right) {
        [p moveToPoint:CGPointMake(x, y)];
        [p addLineToPoint:CGPointMake(x + w, y + h / 2)];
        [p addLineToPoint:CGPointMake(x, y + h)];
    } else {
        [p moveToPoint:CGPointMake(x + w, y)];
        [p addLineToPoint:CGPointMake(x, y + h / 2)];
        [p addLineToPoint:CGPointMake(x + w, y + h)];
    }
    [p closePath];
}

+ (UIImage *)glyph:(MODGlyph)glyph size:(CGFloat)s {
    if (!sGlyphCache) {
        sGlyphCache = [NSCache new];
        sGlyphCache.countLimit = 32;
    }
    NSString *key = [NSString stringWithFormat:@"%ld-%.0f", (long)glyph, s];
    UIImage *cached = [sGlyphCache objectForKey:key];
    if (cached) return cached;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0);
    [[UIColor blackColor] setFill];
    [[UIColor blackColor] setStroke];
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat u = s / 24.0;   // design grid: 24 units
    p.lineWidth = 2 * u;
    p.lineCapStyle = kCGLineCapRound;
    p.lineJoinStyle = kCGLineJoinRound;
    BOOL fill = YES;
    switch (glyph) {
        case MODGlyphSun: {
            [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(7 * u, 7 * u, 10 * u, 10 * u)]];
            [p fill];
            p = [UIBezierPath bezierPath];
            p.lineWidth = 2 * u; p.lineCapStyle = kCGLineCapRound;
            for (int i = 0; i < 8; i++) {
                CGFloat a = i * M_PI / 4;
                [p moveToPoint:CGPointMake(12 * u + cos(a) * 8 * u, 12 * u + sin(a) * 8 * u)];
                [p addLineToPoint:CGPointMake(12 * u + cos(a) * 10.5 * u, 12 * u + sin(a) * 10.5 * u)];
            }
            fill = NO;
            break;
        }
        case MODGlyphSpeaker: {
            [p moveToPoint:CGPointMake(3 * u, 9 * u)];
            [p addLineToPoint:CGPointMake(7 * u, 9 * u)];
            [p addLineToPoint:CGPointMake(12 * u, 4 * u)];
            [p addLineToPoint:CGPointMake(12 * u, 20 * u)];
            [p addLineToPoint:CGPointMake(7 * u, 15 * u)];
            [p addLineToPoint:CGPointMake(3 * u, 15 * u)];
            [p closePath];
            [p fill];
            p = [UIBezierPath bezierPath];
            p.lineWidth = 2 * u; p.lineCapStyle = kCGLineCapRound;
            [p addArcWithCenter:CGPointMake(12 * u, 12 * u) radius:5 * u startAngle:-M_PI / 4 endAngle:M_PI / 4 clockwise:YES];
            [p moveToPoint:CGPointMake(12 * u + cos(-M_PI / 3.2) * 9 * u, 12 * u + sin(-M_PI / 3.2) * 9 * u)];
            [p addArcWithCenter:CGPointMake(12 * u, 12 * u) radius:9 * u startAngle:-M_PI / 3.2 endAngle:M_PI / 3.2 clockwise:YES];
            fill = NO;
            break;
        }
        case MODGlyphPlay: MODTriangle(p, 6 * u, 4 * u, 14 * u, 16 * u, YES); break;
        case MODGlyphPause:
            [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6 * u, 4 * u, 4 * u, 16 * u) cornerRadius:u]];
            [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(14 * u, 4 * u, 4 * u, 16 * u) cornerRadius:u]];
            break;
        case MODGlyphNext:
            MODTriangle(p, 2 * u, 6 * u, 10 * u, 12 * u, YES);
            MODTriangle(p, 11 * u, 6 * u, 10 * u, 12 * u, YES);
            break;
        case MODGlyphPrevious:
            MODTriangle(p, 3 * u, 6 * u, 10 * u, 12 * u, NO);
            MODTriangle(p, 12 * u, 6 * u, 10 * u, 12 * u, NO);
            break;
        case MODGlyphWidgets:
            for (int i = 0; i < 4; i++) {
                CGFloat x = (i % 2) ? 13 * u : 3 * u, y = (i / 2) ? 13 * u : 3 * u;
                [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, 8 * u, 8 * u) cornerRadius:2.5 * u]];
            }
            break;
        case MODGlyphHome:
            [p moveToPoint:CGPointMake(3 * u, 12 * u)];
            [p addLineToPoint:CGPointMake(12 * u, 3.5 * u)];
            [p addLineToPoint:CGPointMake(21 * u, 12 * u)];
            [p moveToPoint:CGPointMake(6 * u, 10 * u)];
            [p addLineToPoint:CGPointMake(6 * u, 20 * u)];
            [p addLineToPoint:CGPointMake(18 * u, 20 * u)];
            [p addLineToPoint:CGPointMake(18 * u, 10 * u)];
            fill = NO;
            break;
        case MODGlyphChevronDown:
            [p moveToPoint:CGPointMake(5 * u, 9 * u)];
            [p addLineToPoint:CGPointMake(12 * u, 15 * u)];
            [p addLineToPoint:CGPointMake(19 * u, 9 * u)];
            p.lineWidth = 2.5 * u;
            fill = NO;
            break;
        case MODGlyphClose:
            [p moveToPoint:CGPointMake(6 * u, 6 * u)];
            [p addLineToPoint:CGPointMake(18 * u, 18 * u)];
            [p moveToPoint:CGPointMake(18 * u, 6 * u)];
            [p addLineToPoint:CGPointMake(6 * u, 18 * u)];
            p.lineWidth = 2.5 * u;
            fill = NO;
            break;
        case MODGlyphBolt:
            [p moveToPoint:CGPointMake(13 * u, 2 * u)];
            [p addLineToPoint:CGPointMake(5 * u, 14 * u)];
            [p addLineToPoint:CGPointMake(11 * u, 14 * u)];
            [p addLineToPoint:CGPointMake(10 * u, 22 * u)];
            [p addLineToPoint:CGPointMake(19 * u, 9 * u)];
            [p addLineToPoint:CGPointMake(13 * u, 9 * u)];
            [p closePath];
            break;
        case MODGlyphMusic:
            [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(3 * u, 15 * u, 7 * u, 6 * u)]];
            [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(13 * u, 13 * u, 7 * u, 6 * u)]];
            [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(8 * u, 4 * u, 2 * u, 14 * u)]];
            [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(18 * u, 2 * u, 2 * u, 14 * u)]];
            [p moveToPoint:CGPointMake(8 * u, 4 * u)];
            [p addLineToPoint:CGPointMake(20 * u, 2 * u)];
            [p addLineToPoint:CGPointMake(20 * u, 5 * u)];
            [p addLineToPoint:CGPointMake(8 * u, 7 * u)];
            [p closePath];
            break;
    }
    if (fill) [p fill]; else [p stroke];
    UIImage *image = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();
    if (image) [sGlyphCache setObject:image forKey:key];
    return image;
}

+ (UIImage *)roundedImage:(UIImage *)image side:(CGFloat)side radius:(CGFloat)radius {
    if (!image) return nil;
    CGRect rect = CGRectMake(0, 0, side, side);
    // Corners are baked in (transparent), so the image needs no layer mask.
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius] addClip];
    // Aspect-fill.
    CGSize size = image.size;
    CGFloat scale = MAX(side / MAX(size.width, 1), side / MAX(size.height, 1));
    CGSize drawn = CGSizeMake(size.width * scale, size.height * scale);
    [image drawInRect:CGRectMake((side - drawn.width) / 2, (side - drawn.height) / 2, drawn.width, drawn.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

+ (UIImage *)roundedThumbnailFromData:(NSData *)data side:(CGFloat)side radius:(CGFloat)radius {
    if (!data.length) return nil;
    UIImage *image = [UIImage imageWithData:data];
    return [self roundedImage:image side:side radius:radius];
}

@end

#pragma mark - Tile

@implementation MODTileButton {
    UIImageView *_glyphView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _glyphView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _glyphView.contentMode = UIViewContentModeScaleAspectFit;
        _titleLabel = MODMakeLabel([[MODTheme current] captionFont], nil);
        _subtitleLabel = MODMakeLabel([[MODTheme current] captionFont], nil);
        [self addSubview:_glyphView];
        [self addSubview:_titleLabel];
        [self addSubview:_subtitleLabel];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self applyTheme];
    }
    return self;
}

- (void)setGlyphImage:(UIImage *)glyphImage {
    _glyphImage = glyphImage;
    _glyphView.image = [glyphImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self setNeedsLayout];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleLabel.text = title;
    self.accessibilityLabel = title;
    [self setNeedsLayout];
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitle = [subtitle copy];
    _subtitleLabel.text = subtitle;
    self.accessibilityValue = subtitle;
    [self setNeedsLayout];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    MODAnimationCoordinator *animator = [MODAnimationCoordinator shared];
    if (!self.window || !animator.animationsEnabled) {
        [self applyTheme];
        return;
    }
    // Color crossfades while the glyph pops: the toggle visibly "clicks".
    [UIView animateWithDuration:0.22 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ [self applyTheme]; }
                     completion:nil];
    [animator popView:_glyphView];
}

- (void)setWhiteWhenActive:(BOOL)whiteWhenActive {
    _whiteWhenActive = whiteWhenActive;
    [self applyTheme];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1.0 : 0.38;
    if (enabled) self.accessibilityTraits &= ~UIAccessibilityTraitNotEnabled;
    else self.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
}

- (void)setHighlighted:(BOOL)highlighted {
    BOOL changed = highlighted != self.highlighted;
    [super setHighlighted:highlighted];
    if (!changed) return;
    [[MODAnimationCoordinator shared] animatePress:self pressed:highlighted];
    [self applyTheme];
}

- (void)applyTheme {
    MODTheme *theme = [MODTheme current];
    UIColor *activeBackground = _whiteWhenActive ? [UIColor whiteColor] : theme.accent;
    UIColor *activeGlyph = _whiteWhenActive ? [UIColor colorWithWhite:0.1 alpha:1] : theme.selectedGlyph;
    UIColor *background = _active ? activeBackground : (self.highlighted ? theme.tilePressed : theme.tileBackground);
    if (_active && self.highlighted) background = [activeBackground colorWithAlphaComponent:0.8];
    self.backgroundColor = background;
    if (self.layer.cornerRadius < 1) self.layer.cornerRadius = theme.tileRadius;   // keep custom (circular) radii
    _glyphView.tintColor = _active ? activeGlyph : theme.glyph;
    _titleLabel.textColor = _active ? activeGlyph : theme.primaryText;
    _subtitleLabel.textColor = _active ? activeGlyph : theme.secondaryText;
    if (_active) self.accessibilityTraits |= UIAccessibilityTraitSelected;
    else self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat glyph = MIN(26, floor(MIN(b.size.width, b.size.height) * 0.42));
    BOOL wide = b.size.width > b.size.height * 1.6 && (_title.length || _subtitle.length);
    if (wide) {
        _glyphView.frame = CGRectMake(14, floor((b.size.height - glyph) / 2), glyph, glyph);
        CGFloat x = CGRectGetMaxX(_glyphView.frame) + 10, w = b.size.width - x - 10;
        BOOL two = _subtitle.length > 0;
        _titleLabel.frame = CGRectMake(x, two ? floor(b.size.height / 2 - 17) : floor((b.size.height - 17) / 2), w, 17);
        _subtitleLabel.frame = CGRectMake(x, floor(b.size.height / 2 + 1), w, 16);
        _subtitleLabel.hidden = !two;
        _titleLabel.hidden = NO;
    } else {
        _glyphView.frame = CGRectMake(floor((b.size.width - glyph) / 2), floor((b.size.height - glyph) / 2), glyph, glyph);
        _titleLabel.hidden = YES;
        _subtitleLabel.hidden = YES;
    }
}

@end

#pragma mark - Vertical slider

@implementation MODVerticalSlider {
    CALayer *_fill;
    UIImageView *_glyphView;
    float _startValue;
    CGFloat _startY;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _fill = [CALayer layer];
        [self.layer addSublayer:_fill];
        _glyphView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self addSubview:_glyphView];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
        [self applyTheme];
    }
    return self;
}

- (void)applyTheme {
    MODTheme *theme = [MODTheme current];
    self.backgroundColor = theme.tileBackground;
    self.layer.cornerRadius = theme.tileRadius;
    // The fill is clipped by hand (its own corner radius) instead of masksToBounds.
    _fill.backgroundColor = (theme.dark ? [UIColor whiteColor] : theme.accent).CGColor;
    _fill.cornerRadius = theme.tileRadius;
    [self updateGlyphTint];
}

- (void)setGlyphImage:(UIImage *)glyphImage {
    _glyphImage = glyphImage;
    _glyphView.image = [glyphImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self setNeedsLayout];
}

- (void)updateGlyphTint {
    MODTheme *theme = [MODTheme current];
    BOOL covered = _value > 0.18f;
    _glyphView.tintColor = covered ? (theme.dark ? [UIColor blackColor] : [UIColor whiteColor]) : theme.glyph;
}

- (void)setValue:(float)value {
    [self setValue:value animated:NO];
}

- (void)setValue:(float)value animated:(BOOL)animated {
    _value = MIN(1.f, MAX(0.f, value));
    self.accessibilityValue = [NSString stringWithFormat:@"%d%%", (int)lroundf(_value * 100)];
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];
    [self layoutFill];
    [CATransaction commit];
    [self updateGlyphTint];
}

- (void)layoutFill {
    CGRect b = self.bounds;
    CGFloat h = round(b.size.height * _value);
    _fill.frame = CGRectMake(0, b.size.height - h, b.size.width, h);
    // Square off the top edge when the fill is shorter than the radius would allow.
    _fill.cornerRadius = MIN([MODTheme current].tileRadius, h / 2);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _glyphView.frame = CGRectMake(floor((b.size.width - 22) / 2), b.size.height - 36, 22, 22);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self layoutFill];
    [CATransaction commit];
}

// While dragged the slider swells slightly (modern iOS) and springs back on release.
- (void)setSwollen:(BOOL)swollen {
    CGAffineTransform target = swollen ? CGAffineTransformMakeScale(1.07, 1.03) : CGAffineTransformIdentity;
    [[MODAnimationCoordinator shared] springAnimations:^{ self.transform = target; }
                                              duration:swollen ? 0.3 : 0.45
                                               damping:swollen ? 0.8 : 0.6
                                              velocity:0 completion:nil];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _adjusting = YES;
    _startValue = _value;
    _startY = [touch locationInView:self].y;
    [self setSwollen:YES];
    if (self.adjustingChanged) self.adjustingChanged(YES);
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat dy = _startY - [touch locationInView:self].y;
    CGFloat h = MAX(self.bounds.size.height, 1);
    float raw = _startValue + (float)(dy / h);
    [self setValue:raw animated:NO];
    // Past either end the slider stretches a little (rubber band) instead of stopping dead.
    CGFloat over = raw > 1 ? (raw - 1) * h : (raw < 0 ? -raw * h : 0);
    CGFloat stretch = MODRubberBand(over, h) / h;
    CGAffineTransform swell = CGAffineTransformMakeScale(1.07, 1.03 + stretch * 0.5);
    self.transform = CGAffineTransformTranslate(swell, 0, (raw > 1 ? -1 : 1) * stretch * h * 0.25);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self finishTracking];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self finishTracking];
}

- (void)finishTracking {
    _adjusting = NO;
    [self setSwollen:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    if (self.adjustingChanged) self.adjustingChanged(NO);
}

- (void)accessibilityIncrement {
    [self setValue:_value + 0.1f animated:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)accessibilityDecrement {
    [self setValue:_value - 0.1f animated:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end

#pragma mark - Card

@implementation MODCardView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) [self applyTheme];
    return self;
}

- (void)applyTheme {
    MODTheme *theme = [MODTheme current];
    self.backgroundColor = theme.tileBackground;
    self.layer.cornerRadius = theme.cardRadius;
}

@end

#pragma mark - Now Playing

@implementation MODNowPlayingView {
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_previous, *_playPause, *_next;
    UIButton *_openButton;
    NSString *_artworkKey;
    NSString *_bundleID;
    BOOL _observing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artwork.contentMode = UIViewContentModeCenter;
        _titleLabel = MODMakeLabel([[MODTheme current] titleFont], nil);
        _artistLabel = MODMakeLabel([[MODTheme current] captionFont], nil);
        _previous = [self controlButton:MODGlyphPrevious action:@selector(previousTapped)];
        _playPause = [self controlButton:MODGlyphPlay action:@selector(playPauseTapped)];
        _next = [self controlButton:MODGlyphNext action:@selector(nextTapped)];
        _previous.accessibilityLabel = @"Previous track";
        _next.accessibilityLabel = @"Next track";
        _openButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_openButton addTarget:self action:@selector(openTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_openButton];   // below the controls
        for (UIView *v in @[ _artwork, _titleLabel, _artistLabel, _previous, _playPause, _next ]) [self addSubview:v];
        [self applyTheme];
    }
    return self;
}

- (UIButton *)controlButton:(MODGlyph)glyph action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[MODIcons glyph:glyph size:22] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)applyTheme {
    [super applyTheme];
    MODTheme *theme = [MODTheme current];
    _titleLabel.textColor = theme.primaryText;
    _artistLabel.textColor = theme.secondaryText;
    // Called from -[MODCardView initWithFrame:] before the buttons exist; the
    // nil-terminated list is then empty.
    for (UIButton *b in [NSArray arrayWithObjects:_previous, _playPause, _next, nil]) b.tintColor = theme.glyph;
    _artwork.backgroundColor = theme.tilePressed;
    _artwork.tintColor = theme.secondaryText;
    _artwork.layer.cornerRadius = 8;
    _artworkKey = nil;   // re-render artwork with the new background
    if (self.window) [self refresh];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !_observing) {
        _observing = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:MODNowPlayingDidChangeNotification object:nil];
        [self refresh];
    } else if (!self.window && _observing) {
        _observing = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:self name:MODNowPlayingDidChangeNotification object:nil];
        // Release artwork while hidden; it is cheap to rebuild for one track.
        _artwork.image = nil;
        _artworkKey = nil;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refresh {
    MODNowPlayingInfo *info = [MODSystemAdapters nowPlaying];
    _bundleID = info.appBundleID;
    if (self.window && [MODAnimationCoordinator shared].animationsEnabled) {
        CATransition *fade = [CATransition animation];   // track changes crossfade
        fade.type = kCATransitionFade;
        fade.duration = 0.2;
        [_titleLabel.layer addAnimation:fade forKey:@"mod.text"];
        [_artistLabel.layer addAnimation:fade forKey:@"mod.text"];
    }
    if (info.hasContent) {
        _titleLabel.text = info.title.length ? info.title : (info.appName ?: @"Now Playing");
        NSString *detail = info.artist.length ? info.artist : info.album;
        _artistLabel.text = detail.length ? detail : info.appName;
    } else {
        _titleLabel.text = @"Not Playing";
        _artistLabel.text = nil;
    }
    UIImage *playGlyph = [MODIcons glyph:info.playing ? MODGlyphPause : MODGlyphPlay size:24];
    if ([_playPause imageForState:UIControlStateNormal] != playGlyph) {
        [_playPause setImage:playGlyph forState:UIControlStateNormal];
        [[MODAnimationCoordinator shared] popView:_playPause];
    }
    _playPause.accessibilityLabel = info.playing ? @"Pause" : @"Play";
    BOOL enabled = info.hasContent;
    _previous.enabled = _playPause.enabled = _next.enabled = enabled;
    _openButton.enabled = enabled && _bundleID.length > 0;

    // Artwork: decode + downscale once per track, off the main thread.
    NSString *key = [NSString stringWithFormat:@"%@|%@|%lu", info.title, info.album, (unsigned long)info.artworkData.length];
    if ([key isEqualToString:_artworkKey]) return;
    _artworkKey = key;
    NSData *data = info.artworkData;
    CGFloat side = [self artworkSide];
    if (!data.length) {
        _artwork.image = [MODIcons glyph:MODGlyphMusic size:side * 0.45];
        return;
    }
    __weak MODNowPlayingView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        UIImage *thumb = [MODIcons roundedThumbnailFromData:data side:side radius:8];
        dispatch_async(dispatch_get_main_queue(), ^{
            MODNowPlayingView *strongSelf = weakSelf;
            if (strongSelf && [strongSelf->_artworkKey isEqualToString:key] && strongSelf.window) {
                [UIView transitionWithView:strongSelf->_artwork duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                                animations:^{ strongSelf->_artwork.image = thumb ?: [MODIcons glyph:MODGlyphMusic size:side * 0.45]; }
                                completion:nil];
            }
        });
    });
}

- (CGFloat)artworkSide {
    return _compact ? 44 : 56;
}

- (void)setCompact:(BOOL)compact {
    _compact = compact;
    _artworkKey = nil;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat side = [self artworkSide], pad = 12;
    if (_compact) {
        // 2x2 tile: artwork + labels on top, transport controls on the bottom.
        _artwork.frame = CGRectMake(pad, pad, side, side);
        CGFloat x = pad, w = b.size.width - 2 * pad;
        _titleLabel.frame = CGRectMake(x, CGRectGetMaxY(_artwork.frame) + 6, w, 18);
        _artistLabel.frame = CGRectMake(x, CGRectGetMaxY(_titleLabel.frame), w, 15);
        CGFloat bw = floor(w / 3), y = b.size.height - 40;
        _previous.frame = CGRectMake(x, y, bw, 34);
        _playPause.frame = CGRectMake(x + bw, y, bw, 34);
        _next.frame = CGRectMake(x + 2 * bw, y, bw, 34);
    } else {
        _artwork.frame = CGRectMake(pad, floor((b.size.height - side) / 2), side, side);
        CGFloat x = CGRectGetMaxX(_artwork.frame) + 12, controls = 3 * 40;
        CGFloat w = b.size.width - x - controls - pad;
        _titleLabel.frame = CGRectMake(x, floor(b.size.height / 2) - 19, w, 19);
        _artistLabel.frame = CGRectMake(x, floor(b.size.height / 2) + 1, w, 16);
        CGFloat cx = b.size.width - pad - controls, cy = floor((b.size.height - 40) / 2);
        _previous.frame = CGRectMake(cx, cy, 40, 40);
        _playPause.frame = CGRectMake(cx + 40, cy, 40, 40);
        _next.frame = CGRectMake(cx + 80, cy, 40, 40);
    }
    _openButton.frame = CGRectMake(0, 0, b.size.width, _compact ? b.size.height - 44 : b.size.height);
}

- (void)previousTapped { [MODSystemAdapters skipTrack:-1]; }
- (void)nextTapped { [MODSystemAdapters skipTrack:1]; }
- (void)playPauseTapped {
    [MODSystemAdapters togglePlayPause];
    // SBMediaNowPlayingChangedNotification follows; refresh early for responsiveness.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.window) [self refresh];
    });
}
- (void)openTapped {
    if (_bundleID.length && self.openNowPlayingApp) self.openNowPlayingApp(_bundleID);
}

@end
