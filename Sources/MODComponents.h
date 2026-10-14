#import <UIKit/UIKit.h>

// Shared, reusable UI building blocks. Frame-based layout only (no Auto
// Layout), opaque backgrounds, corner radii without masksToBounds (no
// offscreen rendering), glyphs rendered once and cached.

typedef NS_ENUM(NSInteger, MODGlyph) {
    MODGlyphSun,
    MODGlyphSpeaker,
    MODGlyphPlay,
    MODGlyphPause,
    MODGlyphNext,
    MODGlyphPrevious,
    MODGlyphWidgets,
    MODGlyphHome,
    MODGlyphChevronDown,
    MODGlyphClose,
    MODGlyphBolt,
    MODGlyphMusic,
};

@interface MODIcons : NSObject
// Template images (tint with tintColor). Cached; purged on memory warning.
+ (UIImage *)glyph:(MODGlyph)glyph size:(CGFloat)size;
+ (void)purge;
// Bakes rounded corners into a downscaled bitmap once, so the image can be
// shown without any layer masking. Returns nil for undecodable data.
+ (UIImage *)roundedThumbnailFromData:(NSData *)data side:(CGFloat)side radius:(CGFloat)radius;
+ (UIImage *)roundedImage:(UIImage *)image side:(CGFloat)side radius:(CGFloat)radius;
@end

// Square/rectangular tile with selected, unselected, disabled and pressed states.
@interface MODTileButton : UIControl
@property (nonatomic, strong) UIImage *glyphImage;
@property (nonatomic, copy) NSString *title;      // optional caption (wide tiles show it beside the glyph)
@property (nonatomic, copy) NSString *subtitle;   // optional second line
@property (nonatomic, assign, getter=isActive) BOOL active;  // "selected" in the design language
// iOS 9 Control Center style: an active tile turns white with a dark glyph.
// Otherwise active tiles use the accent color (connectivity toggles).
@property (nonatomic, assign) BOOL whiteWhenActive;
- (void)applyTheme;
@end

// Vertical, modern-style slider (fills from the bottom). Value 0...1.
@interface MODVerticalSlider : UIControl
@property (nonatomic, assign) float value;
@property (nonatomic, assign, readonly, getter=isAdjusting) BOOL adjusting;
@property (nonatomic, strong) UIImage *glyphImage;
@property (nonatomic, copy) void (^adjustingChanged)(BOOL adjusting);
- (void)setValue:(float)value animated:(BOOL)animated;
- (void)applyTheme;
@end

// Rounded opaque card used by widgets and notifications.
@interface MODCardView : UIView
- (void)applyTheme;
@end

// Now Playing view shared by Control Center and the widget dashboard. It only
// observes media notifications while it is in a window.
@interface MODNowPlayingView : MODCardView
@property (nonatomic, assign) BOOL compact;   // CC 2x2 tile vs. dashboard card
@property (nonatomic, copy) void (^openNowPlayingApp)(NSString *bundleID);
- (void)refresh;
@end

FOUNDATION_EXTERN UILabel *MODMakeLabel(UIFont *font, UIColor *color);
