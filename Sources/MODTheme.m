#import "MODTheme.h"
#import "MODSettings.h"
#import <CoreText/CoreText.h>

static MODTheme *sTheme;

static UIColor *MODRGB(unsigned hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1.0];
}

@implementation MODTheme

+ (NSArray<UIColor *> *)accentPalette {
    // Blue, green, orange, pink, purple, teal.
    return @[ MODRGB(0x0A84FF), MODRGB(0x30D158), MODRGB(0xFF9F0A), MODRGB(0xFF375F), MODRGB(0xBF5AF2), MODRGB(0x40C8E0) ];
}

+ (instancetype)current {
    if (!sTheme) [self reloadFromSettings];
    return sTheme;
}

+ (void)reloadFromSettings {
    MODSettings *settings = [MODSettings current];
    sTheme = [[self alloc] initDark:settings.darkAppearance accentIndex:settings.accentIndex];
}

- (instancetype)initDark:(BOOL)dark accentIndex:(NSInteger)accentIndex {
    if ((self = [super init])) {
        NSArray *palette = [MODTheme accentPalette];
        _dark = dark;
        _accent = palette[(NSUInteger)MAX(0, accentIndex) % palette.count];
        if (dark) {
            _panelBackground = [UIColor clearColor];
            _tileBackground = [UIColor colorWithWhite:1 alpha:0.14];
            _tilePressed = [UIColor colorWithWhite:1 alpha:0.30];
            _primaryText = [UIColor whiteColor];
            _secondaryText = [UIColor colorWithWhite:1 alpha:0.62];
            _separator = [UIColor colorWithWhite:1 alpha:0.35];
            _glyph = [UIColor whiteColor];
        } else {
            _panelBackground = [UIColor clearColor];
            _tileBackground = [UIColor colorWithWhite:1 alpha:0.55];
            _tilePressed = [UIColor colorWithWhite:1 alpha:0.85];
            _primaryText = MODRGB(0x000000);
            _secondaryText = [UIColor colorWithWhite:0 alpha:0.55];
            _separator = [UIColor colorWithWhite:0 alpha:0.25];
            _glyph = MODRGB(0x1C1C1E);
        }
        _glassBackground = [UIColor colorWithWhite:0.08 alpha:0.42];
        _glassPressed = [UIColor colorWithWhite:0.08 alpha:0.60];
        _selectedGlyph = MODRGB(0xFFFFFF);
        _margin = 14;
        _gap = 10;
        _tileRadius = 18;
        _cardRadius = 16;
    }
    return self;
}

- (UIFont *)fontOfSize:(CGFloat)size weight:(CGFloat)weight {
    // +systemFontOfSize:weight: exists since iOS 8.2 (San Francisco on iOS 9).
    return [UIFont systemFontOfSize:size weight:weight];
}

- (UIFont *)titleFont { return [self fontOfSize:15 weight:UIFontWeightSemibold]; }
- (UIFont *)bodyFont { return [self fontOfSize:14 weight:UIFontWeightRegular]; }
- (UIFont *)captionFont { return [self fontOfSize:12 weight:UIFontWeightMedium]; }

- (UIFont *)monoDigitsFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    UIFont *base = [self fontOfSize:size weight:weight];
    UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorFeatureSettingsAttribute : @[ @{
            UIFontFeatureTypeIdentifierKey : @(kNumberSpacingType),
            UIFontFeatureSelectorIdentifierKey : @(kMonospacedNumbersSelector),
        } ],
    }];
    return [UIFont fontWithDescriptor:descriptor size:size];
}

@end
