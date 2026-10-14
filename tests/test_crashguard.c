// Host-side tests for the ModernOS crash guard (pure C core).
// Build & run: make -C tests   (or: sh tests/run.sh)

#include "../Sources/MODCrashGuardCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utime.h>
#include <dirent.h>

static int failures = 0, checks = 0;
#define CHECK(cond) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static char root[512];

static void removeTree(const char *path) {
    DIR *dir = opendir(path);
    if (dir) {
        struct dirent *e;
        char child[1024];
        while ((e = readdir(dir))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            snprintf(child, sizeof child, "%s/%s", path, e->d_name);
            removeTree(child);
        }
        closedir(dir);
        chmod(path, 0755);
        rmdir(path);
    } else {
        unlink(path);
    }
}

static void freshDir(const char *name, char *out, size_t cap) {
    snprintf(out, cap, "%s/%s", root, name);
    removeTree(out);
}

static MODCGLaunchInput input(const char *dir, const char *crashDir, long now) {
    MODCGLaunchInput in = { dir, crashDir, MODCGDefaultConfig(), now, 0 };
    return in;
}

static void writeFile(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

static void markStable(const char *dir, long now) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, MOD_CG_STATE_FILE);
    MODCGState s;
    CHECK(MODCGLoad(path, &s) == MOD_CG_LOAD_OK);
    MODCGMarkStable(&s, now, 42);
    CHECK(MODCGSave(path, &s) == 0);
}

static void testFreshLaunchActivatesAndRecordsAttempt(void) {
    char dir[600]; freshDir("fresh", dir, sizeof dir);
    MODCGState s;
    MODCGLaunchInput in = input(dir, NULL, 1000);
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    CHECK(s.pending == 1 && s.pendingSince == 1000);
    char path[1024]; snprintf(path, sizeof path, "%s/%s", dir, MOD_CG_STATE_FILE);
    MODCGState onDisk;
    CHECK(MODCGLoad(path, &onDisk) == MOD_CG_LOAD_OK);
    CHECK(onDisk.pending == 1);   // attempt durably recorded before activation
}

static void testCrashLoopEntersSafeModeAndStays(void) {
    char dir[600]; freshDir("loop", dir, sizeof dir);
    MODCGState s;
    long t = 5000;
    // Launch 1 + three launches that each follow an unfinished launch.
    MODCGLaunchInput in = input(dir, NULL, t);
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    in.now = t += 12; CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);   // 1 failure
    in.now = t += 12; CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);   // 2 failures
    in.now = t += 12; CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_SAFE_MODE);  // 3 failures
    CHECK(s.safeMode == 1 && s.failureCount == 3);
    // Safe mode persists across many later launches and long gaps (reboots).
    for (int i = 0; i < 20; i++) {
        in.now = t += 3600;
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_SAFE_MODE);
        CHECK(s.pending == 0);   // never re-records attempts while in safe mode
    }
    // Deliberate exit request clears it.
    in.exitSafeModeRequested = 1;
    in.now = t += 10;
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    CHECK(s.safeMode == 0 && s.failureCount == 0);
}

static void testStableLaunchesNeverAccumulate(void) {
    char dir[600]; freshDir("stable", dir, sizeof dir);
    MODCGState s;
    long t = 100000;
    MODCGLaunchInput in = input(dir, NULL, t);
    for (int i = 0; i < 1000; i++) {
        in.now = t += 15;    // rapid but successful launches
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
        markStable(dir, t + 10);
    }
    char path[1024]; snprintf(path, sizeof path, "%s/%s", dir, MOD_CG_STATE_FILE);
    struct stat st; stat(path, &st);
    CHECK(st.st_size < 2048);   // bounded file; no ever-growing counters
    CHECK(MODCGLoad(path, &s) == MOD_CG_LOAD_OK && s.failureCount == 0 && s.eventCount <= MOD_CG_MAX_EVENTS);
}

static void testSporadicFailuresOutsideWindowDoNotTrigger(void) {
    char dir[600]; freshDir("sporadic", dir, sizeof dir);
    MODCGState s;
    long t = 200000;
    MODCGLaunchInput in = input(dir, NULL, t);
    for (int i = 0; i < 10; i++) {   // each launch unfinished, but 5 minutes apart
        in.now = t += 300;
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    }
    CHECK(s.failureCount <= 1);
}

static void testCorruptStateEntersSafeModeAndIsRecoverable(void) {
    char dir[600]; freshDir("corrupt", dir, sizeof dir);
    mkdir(dir, 0755);
    char path[1024]; snprintf(path, sizeof path, "%s/%s", dir, MOD_CG_STATE_FILE);
    const char *bad[] = {
        "version=1\nsafe_mode=0\n",                     // truncated (no end)
        "garbage\n",                                    // malformed
        "version=1\nsafe_mode=7\nend\n",               // out of range
        "version=1\nfailures=12:x\nend\n",             // bad failure kind
        "version=1\nsafe_mode=0\nend",                 // missing trailing newline
        "",                                             // zero-length (power loss)
    };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        writeFile(path, bad[i]);
        MODCGState s;
        MODCGLaunchInput in = input(dir, NULL, 300000 + (long)i);
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_SAFE_MODE);
        CHECK(s.safeMode == 1);
        // Stays in safe mode on the next launch without user action.
        in.now += 100;
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_SAFE_MODE);
        unlink(path);   // documented reset: delete the state file
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
        unlink(path);
    }
}

static void testEmergencyDisableFileWins(void) {
    char dir[600]; freshDir("disable", dir, sizeof dir);
    mkdir(dir, 0755);
    char flag[1024]; snprintf(flag, sizeof flag, "%s/%s", dir, MOD_CG_DISABLE_FILE);
    writeFile(flag, "");
    MODCGState s;
    MODCGLaunchInput in = input(dir, NULL, 400000);
    in.exitSafeModeRequested = 1;
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_EMERGENCY_DISABLE);
    char path[1024]; snprintf(path, sizeof path, "%s/%s", dir, MOD_CG_STATE_FILE);
    CHECK(access(path, F_OK) != 0);   // nothing written while disabled
    unlink(flag);
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
}

static void testUnwritableStorageRefusesToStart(void) {
    if (geteuid() == 0) return;   // root ignores permissions
    char dir[600]; freshDir("readonly", dir, sizeof dir);
    mkdir(dir, 0555);
    MODCGState s;
    MODCGLaunchInput in = input(dir, NULL, 500000);
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_STORAGE_FAILURE);
    chmod(dir, 0755);
}

static void testCrashReportClassification(void) {
    char dir[600]; freshDir("classify", dir, sizeof dir);
    char crash[700]; snprintf(crash, sizeof crash, "%s/CrashReporter", dir);
    mkdir(dir, 0755); mkdir(crash, 0755);
    char report[900]; snprintf(report, sizeof report, "%s/SpringBoard_2026-10-14-120000_iPhone.ips", crash);
    MODCGState s;
    long now = (long)time(NULL);
    MODCGLaunchInput in = input(dir, crash, now - 20);
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    writeFile(report, "crash");             // mtime = now, after the pending launch
    in.now = now;
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    CHECK(s.failureCount == 1 && s.failureKind[0] == 'c');
    // An old report must not classify a newer unfinished launch as a crash.
    struct utimbuf old = { now - 5000, now - 5000 };
    utime(report, &old);
    in.now = now + 10;
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
    CHECK(s.failureCount == 2 && s.failureKind[1] == 'u');
}

static void testModuleFaultsDisableAfterLimit(void) {
    MODCGState s; MODCGStateInit(&s);
    CHECK(MODCGRecordModuleFault(&s, 2, 1) == 0);
    CHECK(MODCGRecordModuleFault(&s, 2, 2) == 1);
    CHECK(s.disabledModules == (1u << 2));
    CHECK(MODCGRecordModuleFault(&s, 99, 3) == 0);   // out of range ignored
}

static void testFirstUseMarkersBecomeModuleFaults(void) {
    char dir[600]; freshDir("risky", dir, sizeof dir);
    char path[1024]; snprintf(path, sizeof path, "%s/%s", dir, MOD_CG_STATE_FILE);
    MODCGState s;
    long t = 600000;
    for (int round = 0; round < 2; round++) {
        MODCGLaunchInput in = input(dir, NULL, t += 100);
        CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);
        markStable(dir, t + 25);
        // First use of module 1 starts and SpringBoard dies before it completes.
        CHECK(MODCGLoad(path, &s) == MOD_CG_LOAD_OK);
        MODCGSetRisky(&s, 1, 1);
        CHECK(MODCGSave(path, &s) == 0);
        t += 600;   // well outside the launch window: not a launch failure
    }
    MODCGLaunchInput in = input(dir, NULL, t);
    CHECK(MODCGLaunchGate(&in, &s) == MOD_CG_GATE_ACTIVATE);   // ModernOS itself stays up
    CHECK(s.riskyModules == 0);
    CHECK(s.moduleFaults[1] == 2 && (s.disabledModules & (1u << 1)));
    CHECK(s.failureCount == 0 && s.safeMode == 0);
    // A completed first use leaves no trace.
    MODCGSetRisky(&s, 3, 1);
    MODCGSetRisky(&s, 3, 0);
    CHECK(s.riskyModules == 0);
}

static void testRoundTrip(void) {
    char dir[600]; freshDir("roundtrip", dir, sizeof dir);
    mkdir(dir, 0755);
    char path[1024]; snprintf(path, sizeof path, "%s/%s", dir, MOD_CG_STATE_FILE);
    MODCGState a; MODCGStateInit(&a);
    a.safeMode = 1; a.safeSince = 9; a.pending = 0; a.lastSuccess = 77; a.lastInitMs = 123;
    snprintf(a.safeReason, sizeof a.safeReason, "reason with spaces");
    a.failureCount = 2; a.failureTime[0] = 5; a.failureKind[0] = 'c'; a.failureTime[1] = 6; a.failureKind[1] = 'u';
    a.moduleFaults[4] = 3; a.disabledModules = 16; a.riskyModules = 5;
    for (int i = 0; i < 12; i++) MODCGAddEvent(&a, i, "evt|with\nseparators");
    CHECK(MODCGSave(path, &a) == 0);
    MODCGState b;
    CHECK(MODCGLoad(path, &b) == MOD_CG_LOAD_OK);
    CHECK(b.safeMode == 1 && b.safeSince == 9 && b.lastSuccess == 77 && b.lastInitMs == 123);
    CHECK(strcmp(b.safeReason, "reason with spaces") == 0);
    CHECK(b.failureCount == 2 && b.failureKind[0] == 'c' && b.failureKind[1] == 'u');
    CHECK(b.moduleFaults[4] == 3 && b.disabledModules == 16 && b.riskyModules == 5);
    CHECK(b.eventCount == MOD_CG_MAX_EVENTS && b.eventTime[0] == 4);
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
    CHECK(access(tmp, F_OK) != 0);   // no stray temp file
}

int main(void) {
    snprintf(root, sizeof root, "%s", getenv("CG_TEST_DIR") ? getenv("CG_TEST_DIR") : "/tmp/modcg-test");
    mkdir(root, 0755);
    testFreshLaunchActivatesAndRecordsAttempt();
    testCrashLoopEntersSafeModeAndStays();
    testStableLaunchesNeverAccumulate();
    testSporadicFailuresOutsideWindowDoNotTrigger();
    testCorruptStateEntersSafeModeAndIsRecoverable();
    testEmergencyDisableFileWins();
    testUnwritableStorageRefusesToStart();
    testCrashReportClassification();
    testModuleFaultsDisableAfterLimit();
    testFirstUseMarkersBecomeModuleFaults();
    testRoundTrip();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
