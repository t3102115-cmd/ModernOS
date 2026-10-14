#import <Foundation/Foundation.h>
#import "MODCrashGuardCore.h"
#import "MODSettings.h"

#define MOD_STATE_DIRECTORY "/var/mobile/Library/ModernOS"
#define MOD_CRASH_REPORT_DIRECTORY "/var/mobile/Library/Logs/CrashReporter"

// Objective-C front end of the crash guard. All state mutation after the
// launch gate happens on a private serial queue, never on the main thread.
@interface MODCrashGuard : NSObject

// Runs the launch gate. Must be called first in the tweak constructor, before
// any hook is installed. Only MOD_CG_GATE_ACTIVATE permits starting features.
+ (MODCGGate)evaluateLaunch;

// Starts the stable-point timer. The launch counts as successful only if
// SpringBoard keeps running for `stableSeconds` after finishing its own launch
// with ModernOS modules started.
+ (void)beginStabilityTimerWithLaunchStart:(CFAbsoluteTime)launchStart;
+ (BOOL)launchIsStable;

// Called when the gate allowed activation but ModernOS installs nothing after
// all (e.g. core hooks failed verification): the attempt is not a failure.
+ (void)withdrawLaunchAttempt:(NSString *)reason;

+ (BOOL)isModuleDisabledByGuard:(MODModule)module;
// Records a contained (Objective-C exception) fault: the module is disabled for
// this session immediately and persistently after repeated faults (until the
// crash guard is reset). Persistence happens off the main thread.
+ (void)recordFaultInModule:(MODModule)module reason:(NSString *)reason;

+ (NSString *)statusDescription;

@end

// Runs `block` with Objective-C exception containment for `module`. An
// exception disables the module for this session (and persistently after
// repeated faults). This cannot contain native crashes (bad memory access,
// signals); those are handled by the launch-window guard.
FOUNDATION_EXTERN void MODGuarded(MODModule module, NSString *what, dispatch_block_t block);

// Like MODGuarded, but the first call per module and session is bracketed by a
// durable first-use marker (one small synchronous write per module per boot).
// If SpringBoard dies natively inside it, the next launch counts a fault for
// that module; after repeated faults only that module is disabled.
FOUNDATION_EXTERN void MODFirstUse(MODModule module, NSString *what, dispatch_block_t block);

// Set by the coordinator so faults can deactivate the module immediately.
FOUNDATION_EXTERN void (*MODModuleFaultHandler)(MODModule module);
