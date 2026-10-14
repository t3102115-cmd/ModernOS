#import "MODCoordinator.h"

// Modern Control Center. Presented by the native bottom-edge system gesture
// (the gesture's own allow/deny policy, including the lock-screen and in-app
// settings, still runs before the handler is reached). All toggles drive the
// stock iOS 9 SBCC* module objects, so every action is the real system action.
@interface MODControlCenterController : NSObject <MODModuleController>

// From the system edge-gesture hooks: the bottom edge
// (-[SBControlCenterController _handleShowControlCenterGesture:]) and, when
// "Pull Down for Control Center" is on, the top edge
// (-[SBNotificationCenterController _handleShowNotificationCenterGesture:]).
// Returns YES when ModernOS handled the gesture (the native panel must not run).
- (BOOL)handleShowGesture:(UIGestureRecognizer *)recognizer fromTop:(BOOL)fromTop;

@end
