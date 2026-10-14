#import "MODCoordinator.h"

// Lightweight widget dashboard (iOS 9 has no WidgetKit; this is an in-tweak
// panel reached from the ModernOS Control Center "Widgets" tile and from the
// lock screen "Widgets" pill). Data is fetched only while it is visible and
// cached: clock (minute timer while visible), battery, Now Playing, calendar
// agenda (EventKit; SpringBoard holds kTCCServiceCalendar), optional weather
// and app shortcuts.
@interface MODWidgetController : NSObject <MODModuleController>
- (void)presentDashboard;
@end
