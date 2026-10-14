#import "MODCrashGuard.h"

void (*MODModuleFaultHandler)(MODModule module) = NULL;

static MODCGState sState;
static MODCGGate sGate = MOD_CG_GATE_SAFE_MODE;
static MODCGConfig sConfig;
static BOOL sStable;
static BOOL sSessionDisabled[MODModuleCount];
static BOOL sFirstUseDone[MODModuleCount];

static dispatch_queue_t MODGuardQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.modernos.crashguard", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *MODStatePath(void) {
    return @MOD_STATE_DIRECTORY "/" MOD_CG_STATE_FILE;
}

@implementation MODCrashGuard

+ (MODCGGate)evaluateLaunch {
    sConfig = [MODSettings crashGuardConfig];
    BOOL exitRequested = [MODSettings exitSafeModeRequested];
    MODCGLaunchInput input = {
        MOD_STATE_DIRECTORY, MOD_CRASH_REPORT_DIRECTORY, sConfig, (long)time(NULL), exitRequested ? 1 : 0,
    };
    // Synchronous by necessity: the attempt must be on disk before any hook
    // exists. The file is < 1 KB; this is one small read and one fsync'd write.
    sGate = MODCGLaunchGate(&input, &sState);

    if (exitRequested && sGate != MOD_CG_GATE_EMERGENCY_DISABLE) [MODSettings clearExitSafeModeRequest];

    switch (sGate) {
        case MOD_CG_GATE_ACTIVATE:
            NSLog(@"[ModernOS] crash guard: launch recorded (failures in window: %d)", sState.failureCount);
            break;
        case MOD_CG_GATE_SAFE_MODE:
            NSLog(@"[ModernOS] crash guard: SAFE MODE (%s). ModernOS is inactive. See README for recovery.", sState.safeReason);
            break;
        case MOD_CG_GATE_EMERGENCY_DISABLE:
            NSLog(@"[ModernOS] emergency disable file present (" MOD_STATE_DIRECTORY "/" MOD_CG_DISABLE_FILE "). ModernOS is inactive.");
            break;
        case MOD_CG_GATE_STORAGE_FAILURE:
            NSLog(@"[ModernOS] crash guard could not record this launch; refusing to start unprotected.");
            break;
    }
    [MODSettings publishStatus:[self statusDescription]];
    return sGate;
}

+ (void)beginStabilityTimerWithLaunchStart:(CFAbsoluteTime)launchStart {
    if (sGate != MOD_CG_GATE_ACTIVATE) return;
    long initMs = (long)((CFAbsoluteTimeGetCurrent() - launchStart) * 1000.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)sConfig.stableSeconds * NSEC_PER_SEC), MODGuardQueue(), ^{
        MODCGMarkStable(&sState, (long)time(NULL), initMs);
        if (MODCGSave(MODStatePath().fileSystemRepresentation, &sState) != 0) {
            NSLog(@"[ModernOS] crash guard: failed to record stable launch");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            sStable = YES;
            [MODSettings publishStatus:[self statusDescription]];
            NSLog(@"[ModernOS] launch stable (init %ld ms)", initMs);
        });
    });
}

+ (void)withdrawLaunchAttempt:(NSString *)reason {
    if (sGate != MOD_CG_GATE_ACTIVATE) return;
    NSLog(@"[ModernOS] launch attempt withdrawn: %@", reason);
    dispatch_async(MODGuardQueue(), ^{
        sState.pending = 0;
        MODCGAddEvent(&sState, (long)time(NULL), reason.UTF8String ?: "withdrawn");
        MODCGSave(MODStatePath().fileSystemRepresentation, &sState);
    });
}

+ (BOOL)launchIsStable {
    return sStable;
}

+ (BOOL)isModuleDisabledByGuard:(MODModule)module {
    if (module < 0 || module >= MODModuleCount) return YES;
    return sSessionDisabled[module] || (sState.disabledModules & (1u << module)) != 0;
}

+ (void)recordFaultInModule:(MODModule)module reason:(NSString *)reason {
    if (module < 0 || module >= MODModuleCount) return;
    sSessionDisabled[module] = YES;
    NSLog(@"[ModernOS] module %ld fault, disabled for this session: %@", (long)module, reason);
    if (sGate != MOD_CG_GATE_ACTIVATE) return;
    dispatch_async(MODGuardQueue(), ^{
        if (MODCGRecordModuleFault(&sState, (int)module, (long)time(NULL))) {
            NSLog(@"[ModernOS] module %ld disabled until the crash guard is reset", (long)module);
        }
        MODCGSave(MODStatePath().fileSystemRepresentation, &sState);
    });
}

+ (NSString *)statusDescription {
    switch (sGate) {
        case MOD_CG_GATE_EMERGENCY_DISABLE: return @"Disabled by emergency file";
        case MOD_CG_GATE_STORAGE_FAILURE: return @"Inactive: state not writable";
        case MOD_CG_GATE_SAFE_MODE: return [NSString stringWithFormat:@"SAFE MODE: %s", sState.safeReason];
        case MOD_CG_GATE_ACTIVATE: break;
    }
    if (sState.disabledModules) return [NSString stringWithFormat:@"Active (modules disabled after faults: 0x%x)", sState.disabledModules];
    return sStable ? @"Active" : @"Starting";
}

@end

void MODGuarded(MODModule module, NSString *what, dispatch_block_t block) {
    if ([MODCrashGuard isModuleDisabledByGuard:module]) return;
    @try {
        block();
    } @catch (NSException *exception) {
        NSString *reason = [NSString stringWithFormat:@"%@: %@ %@", what, exception.name, exception.reason];
        [MODCrashGuard recordFaultInModule:module reason:reason];
        if (MODModuleFaultHandler) MODModuleFaultHandler(module);
    }
}

void MODFirstUse(MODModule module, NSString *what, dispatch_block_t block) {
    if (module < 0 || module >= MODModuleCount) return;
    if (sFirstUseDone[module] || sGate != MOD_CG_GATE_ACTIVATE || [MODCrashGuard isModuleDisabledByGuard:module]) {
        MODGuarded(module, what, block);
        return;
    }
    sFirstUseDone[module] = YES;
    // Durable before the risky work starts; this is the only reason to wait here.
    dispatch_sync(MODGuardQueue(), ^{
        MODCGSetRisky(&sState, (int)module, 1);
        MODCGSave(MODStatePath().fileSystemRepresentation, &sState);
    });
    MODGuarded(module, what, block);
    // Most first-use crashes are immediate or happen during the first
    // animation; two seconds covers both without leaving the marker set.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), MODGuardQueue(), ^{
        MODCGSetRisky(&sState, (int)module, 0);
        MODCGSave(MODStatePath().fileSystemRepresentation, &sState);
    });
}
