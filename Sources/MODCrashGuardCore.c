#include "MODCrashGuardCore.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MOD_CG_MAX_FILE 4096

MODCGConfig MODCGDefaultConfig(void) {
    MODCGConfig config = { 3, 120, 20 };
    return config;
}

MODCGConfig MODCGSanitizedConfig(MODCGConfig config) {
    MODCGConfig d = MODCGDefaultConfig();
    if (config.threshold < 2 || config.threshold > 10) config.threshold = d.threshold;
    if (config.windowSeconds < 30 || config.windowSeconds > 1800) config.windowSeconds = d.windowSeconds;
    if (config.stableSeconds < 5 || config.stableSeconds > 120) config.stableSeconds = d.stableSeconds;
    return config;
}

void MODCGStateInit(MODCGState *state) {
    memset(state, 0, sizeof(*state));
}

void MODCGAddEvent(MODCGState *state, long now, const char *text) {
    if (state->eventCount == MOD_CG_MAX_EVENTS) {
        memmove(&state->eventTime[0], &state->eventTime[1], sizeof(long) * (MOD_CG_MAX_EVENTS - 1));
        memmove(&state->eventText[0], &state->eventText[1], MOD_CG_EVENT_LEN * (MOD_CG_MAX_EVENTS - 1));
        state->eventCount--;
    }
    state->eventTime[state->eventCount] = now;
    snprintf(state->eventText[state->eventCount], MOD_CG_EVENT_LEN, "%s", text);
    // Event text is stored on one line; strip separators.
    for (char *p = state->eventText[state->eventCount]; *p; p++) {
        if (*p == '\n' || *p == '\r' || *p == '|') *p = ' ';
    }
    state->eventCount++;
}

#pragma mark - Parsing

static int parseLong(const char *s, long *out) {
    if (!*s) return 0;
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || *end != '\0') return 0;
    *out = v;
    return 1;
}

// failures=t:k,t:k
static int parseFailures(char *value, MODCGState *state) {
    state->failureCount = 0;
    if (!*value) return 1;
    char *save = NULL;
    for (char *tok = strtok_r(value, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        char *colon = strchr(tok, ':');
        if (!colon || state->failureCount >= MOD_CG_MAX_FAILURES) return 0;
        *colon = '\0';
        long t;
        if (!parseLong(tok, &t)) return 0;
        char kind = colon[1];
        if ((kind != 'c' && kind != 'u') || colon[2] != '\0') return 0;
        state->failureTime[state->failureCount] = t;
        state->failureKind[state->failureCount] = kind;
        state->failureCount++;
    }
    return 1;
}

// faults=a,b,c,d,e
static int parseFaults(char *value, MODCGState *state) {
    int i = 0;
    char *save = NULL;
    for (char *tok = strtok_r(value, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        long v;
        if (i >= MOD_CG_MODULE_COUNT || !parseLong(tok, &v) || v < 0 || v > 255) return 0;
        state->moduleFaults[i++] = (unsigned)v;
    }
    return i == MOD_CG_MODULE_COUNT;
}

// event=t|text  (repeated, oldest first)
static int parseEvent(char *value, MODCGState *state) {
    char *bar = strchr(value, '|');
    if (!bar) return 0;
    *bar = '\0';
    long t;
    if (!parseLong(value, &t)) return 0;
    MODCGAddEvent(state, t, bar + 1);
    return 1;
}

MODCGLoadResult MODCGLoad(const char *path, MODCGState *outState) {
    MODCGStateInit(outState);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return errno == ENOENT ? MOD_CG_LOAD_MISSING : MOD_CG_LOAD_CORRUPT;

    char buf[MOD_CG_MAX_FILE + 1];
    ssize_t total = 0;
    for (;;) {
        ssize_t n = read(fd, buf + total, MOD_CG_MAX_FILE - total);
        if (n < 0) { if (errno == EINTR) continue; close(fd); return MOD_CG_LOAD_CORRUPT; }
        if (n == 0) break;
        total += n;
        if (total == MOD_CG_MAX_FILE) { close(fd); return MOD_CG_LOAD_CORRUPT; }
    }
    close(fd);
    buf[total] = '\0';
    if (total == 0 || buf[total - 1] != '\n') return MOD_CG_LOAD_CORRUPT;   // truncated write
    if (strlen(buf) != (size_t)total) return MOD_CG_LOAD_CORRUPT;           // embedded NUL

    int sawVersion = 0, sawEnd = 0;
    char *save = NULL;
    for (char *line = strtok_r(buf, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (sawEnd) return MOD_CG_LOAD_CORRUPT;
        if (line[0] == '#' || line[0] == '\0') continue;
        if (strcmp(line, "end") == 0) { sawEnd = 1; continue; }
        char *eq = strchr(line, '=');
        if (!eq) return MOD_CG_LOAD_CORRUPT;
        *eq = '\0';
        const char *key = line;
        char *value = eq + 1;
        long v = 0;
        int ok = 1;
        if (!strcmp(key, "version")) { ok = parseLong(value, &v) && v == MOD_CG_VERSION; sawVersion = ok; }
        else if (!strcmp(key, "safe_mode")) { ok = parseLong(value, &v) && (v == 0 || v == 1); outState->safeMode = (int)v; }
        else if (!strcmp(key, "safe_reason")) { snprintf(outState->safeReason, MOD_CG_REASON_LEN, "%s", value); }
        else if (!strcmp(key, "safe_since")) { ok = parseLong(value, &outState->safeSince); }
        else if (!strcmp(key, "pending")) { ok = parseLong(value, &v) && (v == 0 || v == 1); outState->pending = (int)v; }
        else if (!strcmp(key, "pending_since")) { ok = parseLong(value, &outState->pendingSince); }
        else if (!strcmp(key, "last_success")) { ok = parseLong(value, &outState->lastSuccess); }
        else if (!strcmp(key, "last_init_ms")) { ok = parseLong(value, &outState->lastInitMs); }
        else if (!strcmp(key, "failures")) { ok = parseFailures(value, outState); }
        else if (!strcmp(key, "module_faults")) { ok = parseFaults(value, outState); }
        else if (!strcmp(key, "disabled_modules")) { ok = parseLong(value, &v) && v >= 0 && v < (1 << MOD_CG_MODULE_COUNT); outState->disabledModules = (unsigned)v; }
        else if (!strcmp(key, "risky_modules")) { ok = parseLong(value, &v) && v >= 0 && v < (1 << MOD_CG_MODULE_COUNT); outState->riskyModules = (unsigned)v; }
        else if (!strcmp(key, "event")) { ok = parseEvent(value, outState); }
        // Unknown keys are ignored for forward compatibility.
        if (!ok) return MOD_CG_LOAD_CORRUPT;
    }
    // "end" is the last line written; its absence means the file is incomplete.
    if (!sawVersion || !sawEnd) return MOD_CG_LOAD_CORRUPT;
    return MOD_CG_LOAD_OK;
}

#pragma mark - Writing

static int appendf(char *buf, size_t cap, size_t *len, const char *fmt, ...) __attribute__((format(printf, 4, 5)));

static int appendf(char *buf, size_t cap, size_t *len, const char *fmt, ...) {
    if (*len >= cap) return 0;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + *len, cap - *len, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= cap - *len) return 0;
    *len += (size_t)n;
    return 1;
}

static int serialize(const MODCGState *s, char *buf, size_t cap, size_t *outLen) {
    size_t len = 0;
    int ok = appendf(buf, cap, &len,
        "# ModernOS crash guard state. Delete this file to reset (see README).\n"
        "version=%d\nsafe_mode=%d\nsafe_reason=%s\nsafe_since=%ld\npending=%d\npending_since=%ld\n"
        "last_success=%ld\nlast_init_ms=%ld\nfailures=",
        MOD_CG_VERSION, s->safeMode ? 1 : 0, s->safeReason, s->safeSince, s->pending ? 1 : 0,
        s->pendingSince, s->lastSuccess, s->lastInitMs);
    for (int i = 0; ok && i < s->failureCount; i++) {
        ok = appendf(buf, cap, &len, "%s%ld:%c", i ? "," : "", s->failureTime[i], s->failureKind[i]);
    }
    ok = ok && appendf(buf, cap, &len, "\nmodule_faults=");
    for (int i = 0; ok && i < MOD_CG_MODULE_COUNT; i++) {
        ok = appendf(buf, cap, &len, "%s%u", i ? "," : "", s->moduleFaults[i] > 255 ? 255 : s->moduleFaults[i]);
    }
    ok = ok && appendf(buf, cap, &len, "\ndisabled_modules=%u\nrisky_modules=%u\n", s->disabledModules, s->riskyModules);
    for (int i = 0; ok && i < s->eventCount; i++) {
        ok = appendf(buf, cap, &len, "event=%ld|%s\n", s->eventTime[i], s->eventText[i]);
    }
    ok = ok && appendf(buf, cap, &len, "end\n");
    *outLen = len;
    return ok;
}

int MODCGSave(const char *path, const MODCGState *state) {
    char buf[MOD_CG_MAX_FILE];
    size_t len = 0;
    if (!serialize(state, buf, sizeof(buf), &len)) return -1;

    char tmp[1024];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return -1;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, buf + written, len - written);
        if (n < 0) { if (errno == EINTR) continue; close(fd); unlink(tmp); return -1; }
        written += (size_t)n;
    }
    if (fsync(fd) != 0 || close(fd) != 0) { unlink(tmp); return -1; }
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

#pragma mark - Decisions

static void pruneFailures(MODCGState *state, long now, int windowSeconds) {
    int kept = 0;
    for (int i = 0; i < state->failureCount; i++) {
        long t = state->failureTime[i];
        // Drop entries outside the window, and entries from the "future" (clock moved back).
        if (t >= now - windowSeconds && t <= now + 60) {
            state->failureTime[kept] = t;
            state->failureKind[kept] = state->failureKind[i];
            kept++;
        }
    }
    state->failureCount = kept;
}

static void appendFailure(MODCGState *state, long t, char kind) {
    if (state->failureCount == MOD_CG_MAX_FAILURES) {
        memmove(&state->failureTime[0], &state->failureTime[1], sizeof(long) * (MOD_CG_MAX_FAILURES - 1));
        memmove(&state->failureKind[0], &state->failureKind[1], MOD_CG_MAX_FAILURES - 1);
        state->failureCount--;
    }
    state->failureTime[state->failureCount] = t;
    state->failureKind[state->failureCount] = kind;
    state->failureCount++;
}

MODCGDecision MODCGDecideLaunch(MODCGState *state, MODCGConfig config, long now,
                                int exitSafeModeRequested,
                                MODCGCrashProbe probe, void *probeContext,
                                int *outNeedsSave) {
    config = MODCGSanitizedConfig(config);
    *outNeedsSave = 0;

    if (state->safeMode) {
        if (!exitSafeModeRequested) return MOD_CG_SAFE_MODE;   // stays put; nothing to write
        // Deliberate user request: clear everything that could re-trigger safe mode.
        state->safeMode = 0;
        state->safeReason[0] = '\0';
        state->safeSince = 0;
        state->pending = 0;
        state->failureCount = 0;
        memset(state->moduleFaults, 0, sizeof(state->moduleFaults));
        state->disabledModules = 0;
        state->riskyModules = 0;
        MODCGAddEvent(state, now, "safe mode cleared by user request");
    }

    // Modules whose first-use operation never completed last session.
    for (int i = 0; i < MOD_CG_MODULE_COUNT; i++) {
        if (state->riskyModules & (1u << i)) MODCGRecordModuleFault(state, i, now);
    }
    if (state->riskyModules) *outNeedsSave = 1;
    state->riskyModules = 0;

    if (state->pending) {
        int crashed = probe ? probe(state->pendingSince, probeContext) : 0;
        appendFailure(state, state->pendingSince, crashed ? 'c' : 'u');
        MODCGAddEvent(state, now, crashed ? "previous launch crashed (crash report found)"
                                           : "previous launch did not finish (no crash report)");
        state->pending = 0;
    }

    pruneFailures(state, now, config.windowSeconds);

    if (state->failureCount >= config.threshold) {
        state->safeMode = 1;
        state->safeSince = now;
        snprintf(state->safeReason, MOD_CG_REASON_LEN, "%d unfinished launches within %d s",
                 state->failureCount, config.windowSeconds);
        MODCGAddEvent(state, now, "entered safe mode");
        *outNeedsSave = 1;
        return MOD_CG_SAFE_MODE;
    }

    state->pending = 1;
    state->pendingSince = now;
    *outNeedsSave = 1;
    return MOD_CG_ACTIVATE;
}

void MODCGMarkStable(MODCGState *state, long now, long initMs) {
    state->pending = 0;
    state->failureCount = 0;
    state->lastSuccess = now;
    state->lastInitMs = initMs;
}

int MODCGRecordModuleFault(MODCGState *state, int module, long now) {
    if (module < 0 || module >= MOD_CG_MODULE_COUNT) return 0;
    if (state->moduleFaults[module] < 255) state->moduleFaults[module]++;
    char text[MOD_CG_EVENT_LEN];
    snprintf(text, sizeof(text), "module %d fault #%u", module, state->moduleFaults[module]);
    MODCGAddEvent(state, now, text);
    if (state->moduleFaults[module] >= MOD_CG_MODULE_FAULT_LIMIT && !(state->disabledModules & (1u << module))) {
        state->disabledModules |= (1u << module);
        snprintf(text, sizeof(text), "module %d disabled after repeated faults", module);
        MODCGAddEvent(state, now, text);
        return 1;
    }
    return (state->disabledModules & (1u << module)) != 0;
}

void MODCGSetRisky(MODCGState *state, int module, int risky) {
    if (module < 0 || module >= MOD_CG_MODULE_COUNT) return;
    if (risky) state->riskyModules |= (1u << module);
    else state->riskyModules &= ~(1u << module);
}

int MODCGCrashReportExists(const char *directory, long since) {
    DIR *dir = opendir(directory);
    if (!dir) return 0;
    int found = 0;
    struct dirent *entry;
    char path[1024];
    while (!found && (entry = readdir(dir))) {
        if (strncmp(entry->d_name, "SpringBoard", 11) != 0) continue;
        if (snprintf(path, sizeof(path), "%s/%s", directory, entry->d_name) >= (int)sizeof(path)) continue;
        struct stat st;
        if (stat(path, &st) == 0 && S_ISREG(st.st_mode) && (long)st.st_mtime >= since - 2) found = 1;
    }
    closedir(dir);
    return found;
}

#pragma mark - Launch gate

static int probeCrashDirectory(long since, void *context) {
    const char *dir = (const char *)context;
    return dir ? MODCGCrashReportExists(dir, since) : 0;
}

MODCGGate MODCGLaunchGate(const MODCGLaunchInput *input, MODCGState *outState) {
    char statePath[1024], disablePath[1024], corruptPath[1100];
    MODCGStateInit(outState);
    if (snprintf(statePath, sizeof(statePath), "%s/%s", input->stateDirectory, MOD_CG_STATE_FILE) >= (int)sizeof(statePath) ||
        snprintf(disablePath, sizeof(disablePath), "%s/%s", input->stateDirectory, MOD_CG_DISABLE_FILE) >= (int)sizeof(disablePath)) {
        return MOD_CG_GATE_STORAGE_FAILURE;
    }

    // 1. Emergency disable: checked before anything else is touched.
    struct stat st;
    if (stat(disablePath, &st) == 0) return MOD_CG_GATE_EMERGENCY_DISABLE;

    // 2. Ensure the state directory exists (first launch after install).
    if (stat(input->stateDirectory, &st) != 0) {
        if (mkdir(input->stateDirectory, 0755) != 0 && errno != EEXIST) return MOD_CG_GATE_STORAGE_FAILURE;
    } else if (!S_ISDIR(st.st_mode)) {
        return MOD_CG_GATE_STORAGE_FAILURE;
    }

    // 3. Load. Missing = fresh install or deliberate reset. Unreadable = safe mode.
    MODCGLoadResult loaded = MODCGLoad(statePath, outState);
    if (loaded == MOD_CG_LOAD_CORRUPT) {
        snprintf(corruptPath, sizeof(corruptPath), "%s.corrupt", statePath);
        rename(statePath, corruptPath);   // keep it for inspection; best effort
        MODCGStateInit(outState);
        outState->safeMode = 1;
        outState->safeSince = input->now;
        snprintf(outState->safeReason, MOD_CG_REASON_LEN, "crash guard state was unreadable (saved as %s.corrupt)", MOD_CG_STATE_FILE);
        MODCGAddEvent(outState, input->now, "state unreadable; entered safe mode");
        if (!input->exitSafeModeRequested) {
            MODCGSave(statePath, outState);   // best effort; safe mode applies regardless
            return MOD_CG_GATE_SAFE_MODE;
        }
    } else if (loaded == MOD_CG_LOAD_MISSING) {
        MODCGAddEvent(outState, input->now, "new crash guard state");
    }

    // 4. Decide and persist before any feature can run.
    int needsSave = 0;
    MODCGDecision decision = MODCGDecideLaunch(outState, input->config, input->now,
                                               input->exitSafeModeRequested,
                                               probeCrashDirectory, (void *)input->crashReportDirectory,
                                               &needsSave);
    if (decision == MOD_CG_SAFE_MODE) {
        if (needsSave) MODCGSave(statePath, outState);
        return MOD_CG_GATE_SAFE_MODE;
    }
    if (MODCGSave(statePath, outState) != 0) return MOD_CG_GATE_STORAGE_FAILURE;
    return MOD_CG_GATE_ACTIVATE;
}
