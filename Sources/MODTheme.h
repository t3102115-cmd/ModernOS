#import <UIKit/UIKit.h>

// Shared visual language for every ModernOS surface: iOS 9's frosted glass
// with a modern modular layout. Panels sit on a static frosted backdrop (see
// MODPanelHost), so surfaces are light translucent fills — small blended
// areas over one opaque image, never stacked live blur.
@interface MODTheme : NSObject

+ (instancetype)current;
+ (void)reloadFromSettings;

@property (nonatomic, readonly) BOOL dark;
@property (nonatomic, readonly, strong) UIColor *accent;
@property (nonatomic, readonly, strong) UIColor *panelBackground;   // sheet behind tiles
@property (nonatomic, readonly, strong) UIColor *tileBackground;
@property (nonatomic, readonly, strong) UIColor *tilePressed;
@property (nonatomic, readonly, strong) UIColor *primaryText;
@property (nonatomic, readonly, strong) UIColor *secondaryText;
@property (nonatomic, readonly, strong) UIColor *separator;
@property (nonatomic, readonly, strong) UIColor *selectedGlyph;
@property (nonatomic, readonly, strong) UIColor *glyph;
// Lock screen surfaces sit directly on the wallpaper: always dark glass with
// white text, independent of the appearance setting, for legibility.
@property (nonatomic, readonly, strong) UIColor *glassBackground;
@property (nonatomic, readonly, strong) UIColor *glassPressed;

// Layout metrics tuned for a 320 x 480 pt (960 x 640 px) screen.
@property (nonatomic, readonly) CGFloat margin;        // 14
@property (nonatomic, readonly) CGFloat gap;           // 10
@property (nonatomic, readonly) CGFloat tileRadius;    // 18
@property (nonatomic, readonly) CGFloat cardRadius;    // 16

- (UIFont *)fontOfSize:(CGFloat)size weight:(CGFloat)weight;
- (UIFont *)titleFont;     // 15 semibold
- (UIFont *)bodyFont;      // 14 regular
- (UIFont *)captionFont;   // 12 medium
- (UIFont *)monoDigitsFontOfSize:(CGFloat)size weight:(CGFloat)weight;

+ (NSArray<UIColor *> *)accentPalette;

@end
