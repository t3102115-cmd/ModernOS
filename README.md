# ModernOS

One jailbreak tweak — one dylib, one settings pane, one Debian package — that gives an
iPhone 4S on iOS 9.3.6 a modern-iOS look: Control Center, lock screen, widget
dashboard, grouped lock-screen notifications and a decorated app switcher. A persistent
crash guard sits in front of all of it.

```
packages/com.modernos.tweak_1.2.0_iphoneos-arm.deb
```

**Status:** the package has been built and validated, but it has **not been installed or run
inside SpringBoard yet** (deliberately — see [Testing report](#testing-report)). Treat the first
install as a supervised test and keep an SSH session ready.

---

## Install

From the computer that holds the package (device: `root@<iphone-ip>`, OpenSSH is installed):

```bash
scp packages/com.modernos.tweak_1.2.0_iphoneos-arm.deb root@<iphone-ip>:/var/tmp/
```

```bash
ssh root@<iphone-ip> 'dpkg -i /var/tmp/com.modernos.tweak_1.2.0_iphoneos-arm.deb && rm /var/tmp/com.modernos.tweak_1.2.0_iphoneos-arm.deb'
```

Nothing changes until SpringBoard restarts. When ready:

```bash
ssh root@<iphone-ip> 'killall -9 SpringBoard'
```

Requirements (declared in `control`): MobileSubstrate ≥ 0.9.5000, PreferenceLoader, firmware
9.x. The device was checked to have Substrate 0.9.6301 and PreferenceLoader 2.2.6.
The root partition had ~36 MB free; the package needs < 0.3 MB.

## Remove

```bash
ssh root@<iphone-ip> 'dpkg -r com.modernos.tweak && killall -9 SpringBoard'
```

`dpkg -r` keeps `/var/mobile/Library/ModernOS` (crash-guard history, for diagnostics) and your
preferences. `dpkg -P com.modernos.tweak` (purge) deletes both. No other tweak or file is touched.

## Emergency disable and recovery

All of these work without the ModernOS UI. Pick the first that is available:

| Situation | What to do |
|---|---|
| SSH or MobileTerminal works | `modernosctl disable` then `killall -9 SpringBoard` |
| Only a file manager (Filza) works | Create an empty file **`/var/mobile/Library/ModernOS/DISABLE`**, then respring |
| SpringBoard is unusable, no shell | Substrate safe mode: **hold Volume Up while SpringBoard starts** (after a reboot or respring) — no tweak loads; then use Filza/SSH as above |
| Settings app works | Settings → ModernOS → *Enable ModernOS* off, respring |
| Uninstall | `dpkg -r com.modernos.tweak` (or Cydia/Zebra) |

The `DISABLE` file is checked first in the constructor — before preferences, before the crash
guard, before any hook. While it exists ModernOS does nothing at all.

### `modernosctl` (installed in `/usr/bin`)

| Command | Effect |
|---|---|
| `modernosctl status` | Prints whether `DISABLE` exists and the full crash-guard state file |
| `modernosctl disable` | Creates the `DISABLE` file |
| `modernosctl enable` | Removes the `DISABLE` file (does not touch safe mode) |
| `modernosctl reset` | Deletes the crash-guard state: clears counters, module faults and safe mode |

Every change applies at the next respring. `modernosctl` never restarts SpringBoard itself.

### Leaving safe mode deliberately

Safe mode never clears itself. After fixing the cause, do **one** of:

* Settings → ModernOS → *Leave Safe Mode on Next Respring* → respring, or
* `modernosctl reset` → respring, or
* delete `/var/mobile/Library/ModernOS/crashguard.state` (Filza) → respring.

To return to the stock interface while keeping other tweaks: `modernosctl disable` (or turn
ModernOS off in Settings) and respring. ModernOS changes no files outside its own.

---

## Crash guard

### What it protects against

1. **Crash loops during start-up.** The constructor records a launch attempt *on disk* before a
   single hook is installed. An attempt counts as successful only after SpringBoard finished
   launching with ModernOS started and then **stayed up for 20 s** (the stable point). If
   SpringBoard restarts before that, the attempt counts as a failure. **Three failures within
   120 s → persistent safe mode** (thresholds: Settings → ModernOS → Crash Guard; sanitised to
   2–10 failures, 30–1800 s window, 5–120 s stable delay).
2. **Crashes on a module's first use** (e.g. the first Control Center pull, the first switcher
   decoration). Before a module's first risky operation in a session, a first-use marker is
   written durably and cleared 2 s after the operation survives. A marker still set at the next
   launch counts as a fault for **that module only**. Two faults disable that module until the
   guard is reset; ModernOS itself keeps running.
3. **Objective-C exceptions** inside a module are contained per module: the module is switched
   off for the session, and the fault counts toward the same per-module limit.

Native crashes (bad memory access, signals) cannot be "caught" safely; points 1–2 detect them
after the fact. That is the reason those mechanisms exist.

### In safe mode

The constructor returns right after the gate. No hook is installed, so: no panels, no gestures,
no windows, no animation coordinator, no timers, no observers, no network. SpringBoard is stock.

### Telling crashes from ordinary restarts

When an unfinished launch is found, the guard checks
`/var/mobile/Library/Logs/CrashReporter` for a `SpringBoard*` report written after that launch
began. The result is recorded per failure (`c` = crash report found, `u` = unknown).

**Limitation:** ReportCrash may write the report after SpringBoard has already restarted, and a
user respring (`killall`, `sbreload`, Settings changes) within the first 20 s looks exactly like
a crash. Both kinds therefore count. In practice that means three manual resprings, each within
20 s of the previous launch and all within 2 minutes, would enter safe mode. That is unlikely in
normal use and is recovered as described above.

### State file

`/var/mobile/Library/ModernOS/crashguard.state` — plain `key=value` text, < 1 KB, readable with
`cat`. Writes are atomic (temp file → `fsync` → `rename`). A missing file means a fresh state
(first install or deliberate reset). An unreadable, truncated or zero-length file
(e.g. after a power loss) means **safe mode**; the bad file is kept as `crashguard.state.corrupt`.
If the state cannot be written at all, ModernOS refuses to start unprotected.

Bounded by design: failures older than the window are dropped, a successful launch clears them,
the event log is a ring of 8 entries, fault counters saturate. No counter grows with normal use
(tested over 1000 simulated launches).

Disk access on the main thread: one small read and one fsync'd write in the constructor (they
must precede the hooks), and one write per module the first time it's used in a session. All
other writes happen on a background queue.

---

## Features and how each one is integrated

| Module | Integration point (verified on 9.3.6) | Stays native |
|---|---|---|
| **Control Center** | Bottom edge: `-[SBControlCenterController _handleShowControlCenterGesture:]`. Top edge (*Pull Down for Control Center*, on by default): `-[SBNotificationCenterController _handleShowNotificationCenterGesture:]`. Both are the stock system gestures, so the stock lock-screen / in-app access policies still apply | Landscape (ModernOS is portrait-only); Notification Center when the pull-down setting is off; VoiceOver/other callers of the native panels |
| **Lock Screen** | `SBFLockScreenDateView` `_timeFont`/`_dateFont`/`layoutSubviews`; `-[SBLockScreenView _layoutNotificationView]` | Passcode, slide to unlock, emergency call, unlock/auth, media controls, camera grabber |
| **Widget dashboard** | No hooks: a ModernOS panel opened from the CC *Widgets* tile or the lock-screen *Widgets* pill | — |
| **Grouped notifications** | Observes `SBLockScreenNotificationListController` model updates (after `%orig`) and reads its list items | Delivery, sounds, vibration, screen wake, realerts, Notification Center |
| **App switcher** | `SBDeckSwitcherViewController` appearance/dismissal/blur | Cards, scrolling, snapshots, swipe-to-quit, activation |

### Look: frosted glass, modern layout
Panels open over a **static frosted backdrop**: one screen capture per presentation
(`_UICreateScreenUIImage`, verified on 9.3.6), downscaled 8× to 80×120 px, triple box-blurred
with Accelerate and tinted on a background thread, then shown as a single opaque image. That is
iOS 9's frosted look without live blur. Tiles and cards are light translucent fills on top
(white glass in Dark, milky in Light). Lock-screen surfaces (notification cards, pills, the
switcher Home button) use dark glass with white text so they read on any wallpaper. Panels
follow the finger in and out (transform + opacity only); tap anywhere outside the tiles, drag
back toward the edge, or press Home to close.

### Motion
One spring engine drives every ModernOS animation (`MODAnimationCoordinator`):

* **The math:** a closed-form damped spring (the analytic solution, not a step-by-step
  simulation). It was checked against a numeric simulation to within 6·10⁻⁵.
* **The clock:** a display link that runs only while something is moving and is invalidated the
  moment the spring settles, with a hard stop at 2 s.
* **Control Center entry:** the panel tracks the finger 1:1 and rubber-bands past fully open,
  using the iOS scroll-view curve. On release the finger's speed is handed to a spring
  (response 0.44 s, damping 0.78), so there is no jolt, only one soft overshoot of about 2 % of
  the travel. Tiles cascade in from the edge you pulled from: each grows from 86 % and slides the
  last 22 pt on its own schedule. You can catch the panel mid-flight and throw it back. Closing
  is a critically damped spring (no bounce) that keeps your flick speed.
* **Small interactions:**
  * tiles squeeze on touch and bounce back on release;
  * toggles crossfade their color while the glyph pops;
  * sliders swell while dragged and stretch at the ends;
  * Now Playing crossfades track changes and artwork;
  * the frosted backdrop fades in once it's ready.
* **Notification stacks:** they spring open, with the hidden cards fanning out from under the
  top card, and fold back on *Show less*. New notifications drop in from above, and hidden ones
  shrink and fade. Views are reused per bulletin, so nothing jumps.
* **Lock-screen pills:** they settle in under the clock.
* **Settings:** Reduce Motion replaces all of this with short crossfades, and *Animations* off
  makes everything instant.

### Pull down for Control Center
Pulling down from the top edge opens Control Center from the top, like modern iOS. Notification
Center's pull-down is suppressed (not removed) while *Settings → ModernOS → Pull Down for
Control Center* is on; turn it off to get Notification Center back. Swiping up from the bottom
still opens Control Center too.

### Control Center
2×2 connectivity block (Airplane, Wi-Fi, Bluetooth, Do Not Disturb), Now Playing, Rotation
Lock, Widgets, battery tile, vertical brightness and volume sliders, then Flashlight, Timer,
Calculator, Camera.

Every toggle drives Apple's own iOS 9 module objects (`SBCCWiFiSetting`, `SBCCBluetoothSetting`,
`SBCCAirplaneModeSetting`, `SBCCDoNotDisturbSetting`, `SBCCOrientationLockSetting`,
`SBCCFlashlightSetting`, `SBCCTimerShortcut`, `SBCCCalculatorShortcut`, `SBCCCameraShortcut`)
through `-toggleState`. These are the real system actions; no private Wi-Fi or Bluetooth API is
called directly. Their glyphs are Apple's. A restricted or inoperative module renders disabled.
If a module asks for confirmation, Apple's message is shown in an alert.

Brightness uses `SBBrightnessController` (no HUD). Volume uses `SBMediaController` with its HUD
suppressed while dragging. Both follow external changes while visible. The Home button, a tap
above the panel, a downward drag, or the accessibility escape gesture closes it.

**Not included:** cellular data, Low Power Mode, AirPlay. Their iOS 9 private APIs could not be
verified, so the panel omits them rather than shipping toggles that might only change color.

### Lock screen
A large semibold clock with tabular digits, the date above the time, and a battery pill plus a
*Widgets* pill under the clock. The labels are reordered only when the expected two-label
structure is found; otherwise the native layout stays.

**Custom wallpaper (optional, off by default):** copy a JPEG to
`/var/mobile/Library/ModernOS/LockWallpaper.jpg`. It is decoded once at screen size on a
background thread and released on unlock and on memory warnings. *Limitation:* the passcode page
still shows the blurred **system** wallpaper. For a permanent wallpaper, iOS 9's own picker
(Settings → Wallpaper) is the better tool.

Now Playing on the lock screen is the native iOS 9 media control, which is fully functional and
sits under the ModernOS clock.

### Grouped notifications (lock screen)
* **Grouping:** by app (most recent first), with the app icon, name and a count.
* **Stacks:** collapsed stacks show the newest card plus a "shelf"; tapping the header expands
  them, and *Show less* collapses them again.
* **Tap-through:** works without touching authentication. On a locked device the card shows
  *Unlock to open*, and the app opens (via the bulletin's launch URL, or its app) after the user
  unlocks the normal way. It expires after 60 s.
* **Dismissal:** × on an expanded group, or a long press on a single card, hides it from the
  ModernOS lock screen until the next unlock. iOS 9 has no per-bulletin dismissal on the lock
  screen, so the bulletins stay in Notification Center.
* **Fallback to native:** the native list stays visible when it contains anything other than
  ordinary bulletins (system alerts, alarms, Passbook passes, more than 40 items). Nothing is
  ever hidden that ModernOS cannot show.
* **Privacy:** messages come from the native list items, which already apply per-app *Show on
  Lock Screen* and message-preview privacy.
* **Limitation:** opening from a card launches the app or URL but doesn't pass a third-party
  app's push payload, which the native swipe would.

### Widget dashboard
* **Clock and date:** a one-shot timer re-armed at each minute boundary, only while visible.
* **Battery:** level bar; green while charging, red at 20 % and below.
* **Now Playing:** shared with Control Center; artwork is downscaled once per track.
* **Calendar agenda:** the next 4 events today and tomorrow, via EventKit. SpringBoard holds the
  `kTCCServiceCalendar` entitlement, so there is no permission prompt. Fetched off the main
  thread and cached for 15 minutes or until the calendar changes. **Event details are hidden
  while the device is locked.**
* **Weather (optional, off by default):** Open-Meteo, no API key. Fetched only while the
  dashboard is visible and the cache is older than 30 minutes. 10 s hard timeout, 16 KB response
  limit, cached on disk.
  *Why plain HTTP:* SpringBoard enforces ATS, and iOS 9 does not trust the service's ISRG Root X1
  certificate chain, so `NSURLSession` cannot reach it. The request uses CFNetwork instead. Only
  coordinates rounded to ~1 km are sent.
* **Shortcuts:** up to 4 apps (bundle IDs in Settings). While locked they open after unlock.

### App switcher
Native deck switcher, plus:
* **card shadows** with an explicit `shadowPath` around each card (no offscreen rendering);
  they fade in when the switcher settles and are removed before the native dismissal animation;
* **Home** and **Clear All** pills that rise in with a staggered spring. Clear All needs a second
  tap within 3 s (the pill turns red and says *Tap to Clear*). It then quits the apps through the
  same native path a swipe-up uses (`switcherContentController:deletedItem:`, verified), one card
  after another, and returns Home;
* rounded cards while the switcher is at rest, using SpringBoard's own corner-radius progress;
  the original value is restored before the dismissal animation runs;
* no blur on stacked cards, which saves GPU work;
* a **Home** button. It sets the switcher's return item to the home screen and dismisses it
  through SpringBoard's own non-interactive path.

ModernOS never terminates an app; previews are SpringBoard's own lazily loaded snapshots.

### Settings
Settings → ModernOS: master switch, one switch per module, Dark/Light, accent color, animations,
reduce motion, lock/switcher/widget options, crash-guard thresholds, and the current crash-guard
status.

* **Applies immediately:** turning a module off, theme, motion, and every option.
* **Needs a respring:** turning ModernOS or a module *on* (its hooks are only installed at launch
  when enabled), and crash-guard thresholds.

---

## Performance design

* **Memory:** one dylib (223 KB). Panels are built on first use; the panel window is hidden when
  idle and dropped on lock and on memory warnings. Bounded caches: 24 app icons, 32 glyphs,
  1 artwork thumbnail, 1 wallpaper bitmap (only while locked).
* **Idle cost:** no polling loops, no display links, no repeating timers, no background services.
  Observers are attached only while their view is on screen; the only permanent ones are lock,
  memory-warning, settings and now-playing notifications.
* **Animation:** one coordinator. Transform and opacity only, 0.20 s panel transitions (0.12–0.26 s
  when finishing a gesture), ease-out, no springs. Reduce Motion crossfades; animations off makes
  everything instant.
* **Rendering:** opaque colors everywhere except a few small pills; corner radii without
  `masksToBounds`; artwork corners baked into the bitmap; no blur, no shadows, no full-screen
  translucent layer. The panel's tap-catcher is a clear, non-drawing view.
* **Main thread:** artwork decoding, wallpaper decoding, calendar fetches and weather requests run
  on background queues. Layout is frame-based; the lock-screen layout hook only sets frames.

**Measuring on the device:**
```bash
ssh root@<iphone-ip> 'modernosctl status'
```
`last_init_ms` is the time from constructor to SpringBoard launch completion, and syslog prints
`[ModernOS] constructor finished in … ms`. Frame pacing, CPU and memory have to be measured on
the device (Instruments isn't available for iOS 9 from this Linux build host); see the testing
report.

---

## Compatibility report — iOS 9.3.6 (13G37), iPhone4,1, ARMv7

**Build environment (inspected):** Theos `304e079`, clang 11.1.0 (L1ghtmann iOS toolchain),
ld64-609, iPhoneOS 9.3 SDK, target `iphone:clang:9.3:9.0`, `ARCHS = armv7`, ARC, built with
`-Wall -Wextra -Werror`. Links only public frameworks (UIKit, Foundation, QuartzCore,
CoreGraphics, CoreText, CFNetwork, EventKit) plus CydiaSubstrate. **Every private class is looked
up at runtime; none is a link-time dependency.**

**How the private APIs were verified:**
1. **SpringBoard classes:** the ObjC metadata of the device's own
   `/System/Library/CoreServices/SpringBoard.app/SpringBoard` (armv7) was dumped:
   4,876 classes and 19,473 methods with type encodings.
2. **Shared-cache classes** (`SBFLockScreenDateView`, `BBBulletin`, `BBAction`,
   `UIImage _applicationIconImage…`, `UIWindow +_isSecure`, MediaRemote symbols,
   `BKSDisplayBrightness*`): checked by a probe process run on the device.
3. **Cross-checks:** all 23 hook specs in `Tweak.xm` and all 77 private selectors declared in
   `Sources/MODPrivate.h` were matched against those results by script. Zero mismatches.
4. **At runtime:** before installing each hook group, the tweak re-verifies class, selector and
   exact type encoding. On any mismatch the group is skipped, that module stays native, and the
   reason is logged.

**Entitlements and policies relied on (read from the device):** SpringBoard holds
`com.apple.private.tcc.allow` including `kTCCServiceCalendar`. SpringBoard's Info.plist has no
ATS exceptions. SpringBoard's own windows use `+_isSecure` to stay visible above the lock screen.

**Not available on iOS 9, so not used:** WidgetKit, Liquid Glass/materials, `UIVisualEffectView`
in hot paths, SF Symbols, Dynamic Island APIs.

**Other tweaks on this device that hook SpringBoard:** FreeGrid, Zeppelin, SiriIntelligence and
DailyDriverTweak (UIKit). ModernOS hooks none of the home-screen icon layout or status bar
classes those usually target, and always calls the original implementation when it does not take
over. Interactions can't be ruled out without running them together.

---

## Testing report

### Actually run

| Test | Where | Result |
|---|---|---|
| Crash-guard unit tests (`make test` / `tests/run.sh`): fresh launch, crash loop → safe mode, safe mode persisting over 20 later launches, deliberate exit, 1000 stable launches with a bounded file, sporadic failures outside the window, 6 corrupt-file variants (truncated, zero-length, malformed, out-of-range, missing `end`, missing newline), the emergency file winning over everything, unwritable storage refusing to start, crash-report classification incl. stale reports, module fault limit, first-use markers, round trip | Linux host (gcc) | **3124 checks, 0 failures** |
| Same test binary compiled for armv7 | **On the iPhone 4S**, `/var/tmp`, as `mobile` (SpringBoard's user) and as root | **3124 checks, 0 failures** as `mobile`; 3123 as root (the unwritable-storage check is skipped, root ignores permissions) |
| Hook spec and private-selector cross-check | SpringBoard dump + device probe | 23/23 hooks and 77/77 selectors match (`+[UIWindow _isSecure]` confirmed on device: `c8@0:4`) |
| Theos build, debug and release (`-Werror`) | Linux host | Compiles and links, 0 warnings |
| `dlopen(ModernOS.dylib, RTLD_NOW)`, debug and release, in a separate non-SpringBoard process (its constructor returns immediately there) | **On the iPhone 4S** | Loads; **all symbols bind on iOS 9.3.6** |
| Package read by the device's own dpkg 1.18 (`dpkg-deb -I`, `-x`), no install | **On the iPhone 4S** | OK; `modernosctl` parses and runs under the device shell |
| Weather endpoint reachable over plain HTTP | Linux host | HTTP 200 |

The device was left as found: nothing installed (`dpkg-query` confirms) and every temporary file
removed. SpringBoard was never restarted.

### Not yet verified (needs the first supervised install)

All of these are protected by the crash guard, the per-module fault isolation and the native
fallbacks. They are still assumptions until observed on the device:

* **Everything inside SpringBoard.** No hook has run in SpringBoard yet. Visual layout on the
  real screen is unverified; dimensions are computed for 320 × 480 pt.
* **Control Center**
  * Creating the stock `SBCC*` module objects outside Apple's section controller, and their
    `state` values and glyphs. If this crashes, the first-use guard disables Control Center after
    two faults.
  * Window level 1050 relative to system alerts.
  * Whether returning without `%orig` from the gesture handler leaves any native state (e.g. the
    "grabber on first swipe" in full-screen apps) inconsistent.
* **Lock screen**
  * The date-above-time reorder heuristic and the clock size within the native date-view frame.
  * Native code changing the notification view's `hidden` flag while ModernOS hides it.
* **Notifications:** the `listItemAtIndexPath:` section-0 assumption. It is type-checked, and a
  mismatch shows the native list.
* **Unlock hook:** `_finishUIUnlockFromSource:withOptions:` as the signal for "opens after unlock".
* **Switcher:** the visual effect of `contentCornerRadiusProgress` = 1 and of a zero blur; whether
  `setReturnToDisplayItem:` + `dismissSwitcherNoninteractively` reliably goes Home.
* **Weather:** the CFNetwork request on the device itself.
* **Performance:** CPU, memory and frame pacing during panel animations are not measured yet.
  60 FPS is a goal, not a measured result.

### Installed on the device (supervised)
* **1.0.0**, then **1.1.0** (pull-down Control Center, frosted UI). After each respring the
  crash guard marked the launch stable, with no faults and no SpringBoard crash reports. On 1.1.0
  the Control Center first-use marker was set and cleared, so the panel opened and survived.
* **1.2.0** (spring animations, switcher shadows, Clear All): the launch was marked stable with
  no faults and no crash reports. SpringBoard resident memory was 53 MB at 1.2 % CPU, with
  whatever UI state the device had at the time.
* **Idle cost on 1.1.0:** SpringBoard resident memory 41 MB at 0.8 % CPU; `last_init_ms` 8864
  (this is mostly SpringBoard's own start-up).

### Suggested first-install procedure
1. Keep SSH open: `ssh root@<iphone-ip>`.
2. Install, respring, then wait 25 s. `modernosctl status` should show `pending=0` and
   `last_init_ms=…`.
3. Try one module at a time; Settings → ModernOS can turn modules off instantly.
4. Watch the log for `[ModernOS]` lines: `hook group … NOT installed`, `module … fault`.
5. If anything misbehaves: `modernosctl disable && killall -9 SpringBoard`, then share
   `modernosctl status` and the `[ModernOS]` log lines.

---

## Source layout

```
ModernOS/
  Makefile, control, ModernOS.plist (SpringBoard filter)
  Tweak.xm                       entry point, crash-guard gate, verified hook groups
  Sources/
    MODCrashGuardCore.[ch]       pure-C guard: state machine, atomic persistence, launch gate
    MODCrashGuard.[hm]           ObjC front end: stability timer, MODGuarded, MODFirstUse
    MODSettings.[hm]             single preference model (com.modernos.prefs)
    MODCoordinator.[hm]          lifecycle, module activation, memory/lock/unlock events
    MODTheme.[hm]                shared colors, metrics, fonts
    MODAnimationCoordinator.[hm] the one animation policy
    MODPanelHost.[hm]            the one secure panel window
    MODComponents.[hm]           tiles, sliders, cards, Now Playing, procedural glyphs
    MODSystemAdapters.[hm]       defensive wrappers for verified SpringBoard APIs
    MODPrivate.h                 verified private interfaces
    MODControlCenterController.[hm]  MODLockScreenController.[hm]  MODWidgetController.[hm]
    MODWeatherService.[hm]       MODNotificationController.[hm]   MODAppSwitcherController.[hm]
  layout/
    Library/PreferenceLoader/Preferences/ModernOS.plist   settings pane (plist only, no bundle)
    usr/bin/modernosctl                                   recovery tool
    DEBIAN/postinst, postrm
  tests/test_crashguard.c, tests/run.sh
```

Build: `export THEOS=~/theos && make package FINALPACKAGE=1`. Tests: `make test`.
