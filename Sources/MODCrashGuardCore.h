// MODCrashGuardCore — pure C crash-loop guard state machine and persistence.
//
// Kept free of Objective-C and CoreFoundation so it can be unit-tested on the
// build host (see tests/test_crashguard.c). The state file is a small
// line-based "key=value" text file so it can be inspected with `cat` over SSH
// (the device has no plutil) and edited/deleted by hand for recovery.

#ifndef MOD_CRASH_GUARD_CORE_H
#define MOD_CRASH_GUARD_CORE_H

#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOD_CG_VERSION 1
#define MOD_CG_MAX_FAILURES 16
#define MOD_CG_MAX_EVENTS 8
#define MOD_CG_EVENT_LEN 64
#define MOD_CG_REASON_LEN 128
#define MOD_CG_MODULE_COUNT 5          // cc, lock, widgets, notifications, switcher
#define MOD_CG_MODULE_FAULT_LIMIT 2    // faults before a module is disabled persistently

typedef struct {
    int threshold;        // unfinished launches that trigger safe mode
    int windowSeconds;    // ...within this many seconds
    int stableSeconds;    // seconds after launch before a launch counts as successful
} MODCGConfig;

typedef struct {
    int safeMode;
    char safeReason[MOD_CG_REASON_LEN];
    long safeSince;
    int pending;                  // 1 while a launch has not reached the stable point
    long pendingSince;
    long lastSuccess;
    long lastInitMs;
    int failureCount;
    long failureTime[MOD_CG_MAX_FAILURES];
    char failureKind[MOD_CG_MAX_FAILURES];  // 'c' = SpringBoard crash log found, 'u' = unknown cause
    int eventCount;               // ring buffer, oldest first
    long eventTime[MOD_CG_MAX_EVENTS];
    char eventText[MOD_CG_MAX_EVENTS][MOD_CG_EVENT_LEN];
    unsigned moduleFaults[MOD_CG_MODULE_COUNT];
    unsigned disabledModules;     // bitmask, bit i = module i
    unsigned riskyModules;        // bitmask: first-use operation in progress (not yet survived)
} MODCGState;

typedef enum {
    MOD_CG_LOAD_OK = 0,
    MOD_CG_LOAD_MISSING,
    MOD_CG_LOAD_CORRUPT,
} MODCGLoadResult;

typedef enum {
    MOD_CG_ACTIVATE = 0,   // record written; features may start
    MOD_CG_SAFE_MODE,      // persistent safe mode; start nothing
} MODCGDecision;

// Returns non-zero if a SpringBoard crash report newer than `since` exists.
typedef int (*MODCGCrashProbe)(long since, void *context);

MODCGConfig MODCGDefaultConfig(void);
MODCGConfig MODCGSanitizedConfig(MODCGConfig config);
void MODCGStateInit(MODCGState *state);

MODCGLoadResult MODCGLoad(const char *path, MODCGState *outState);
// Atomic replace: write temp file, fsync, rename over `path`. Returns 0 on success.
int MODCGSave(const char *path, const MODCGState *state);

// The launch decision. Mutates `state`; `outNeedsSave` tells the caller whether
// the state changed and must be persisted before acting on the decision.
MODCGDecision MODCGDecideLaunch(MODCGState *state, MODCGConfig config, long now,
                                int exitSafeModeRequested,
                                MODCGCrashProbe probe, void *probeContext,
                                int *outNeedsSave);

// Called once the launch reached the stable point.
void MODCGMarkStable(MODCGState *state, long now, long initMs);

// Records a contained module fault. Returns 1 if the module is now disabled.
int MODCGRecordModuleFault(MODCGState *state, int module, long now);

// First-use markers. A marker that survives into the next launch means the
// module's first risky operation took SpringBoard down: it counts as a fault
// for that module (MODCGDecideLaunch converts and clears the markers).
void MODCGSetRisky(MODCGState *state, int module, int risky);

void MODCGAddEvent(MODCGState *state, long now, const char *text);

// Scans `directory` for SpringBoard crash reports modified at or after `since`.
int MODCGCrashReportExists(const char *directory, long since);

typedef enum {
    MOD_CG_GATE_ACTIVATE = 0,      // attempt recorded on disk; features may start
    MOD_CG_GATE_SAFE_MODE,         // persistent safe mode (repeated failures or unreadable state)
    MOD_CG_GATE_EMERGENCY_DISABLE, // the emergency disable file exists
    MOD_CG_GATE_STORAGE_FAILURE,   // the attempt could not be recorded; refuse to start unprotected
} MODCGGate;

typedef struct {
    const char *stateDirectory;     // e.g. /var/mobile/Library/ModernOS
    const char *crashReportDirectory;
    MODCGConfig config;
    long now;
    int exitSafeModeRequested;
} MODCGLaunchInput;

// The complete launch gate used by the tweak entry point. Never starts features
// unless the new attempt has been durably recorded first. `outState` receives
// the resulting state for diagnostics.
MODCGGate MODCGLaunchGate(const MODCGLaunchInput *input, MODCGState *outState);

// Paths derived from the state directory.
#define MOD_CG_STATE_FILE "crashguard.state"
#define MOD_CG_DISABLE_FILE "DISABLE"

#ifdef __cplusplus
}
#endif

#endif
