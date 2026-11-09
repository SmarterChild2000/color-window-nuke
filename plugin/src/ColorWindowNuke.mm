// ColorWindowNuke.mm — Color Window Nuke for Illustrator (native plug-in).
//
// Keeps the Color panel user-controlled. When a toolbar Fill/Stroke proxy click
// makes Illustrator open a Color panel the user had closed, the plug-in closes
// it again with the public AIPaintStyleSuite::ToggleColorDialog() — the same
// code path as Window > Color — in the same run-loop turn as the click.
// Window > Color, its shortcut, and a panel the user already had open are never
// touched. See plugin/src/IntentModel.h for the decision rules.
//
// Settings (defaults domain com.colorwindownuke.illustrator), all optional:
//   mode               off | diagnose | enforce. Default: enforce on verified
//                      Illustrator builds, diagnose (observe only) elsewhere.
//   experimentalDrawer false switches off icon-dock drawer hiding (default on).
//   logging            true writes ~/Library/Logs/ColorWindowNuke/*.jsonl (default off).
//   debugLog           true also records panel changes (troubleshooting only).
// Removing the plug-in from Illustrator's Plug-ins folder removes the fix.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <os/log.h>
#include <stdio.h>
#include <string.h>

#ifdef PC_OFFICIAL_SDK
#include "PCOfficialSDK.h"
#else
#include "PCShim.h"
#endif
#include "IntentModel.h"

#define PC_VERSION "1.0.0"
// Test hosts may redirect settings/logs; Illustrator never sets these.
static NSString *domain() {
    const char *d = getenv("CWN_DEFAULTS_DOMAIN");
    return d ? @(d) : @"com.colorwindownuke.illustrator";
}
static const char *const kPluginName = "Color Window Nuke";
static const char *const kColorCommandKey = "Adobe Color Palette";

// Illustrator builds this release was verified against (see docs/COMPATIBILITY.md).
// On any other build the plug-in only observes and Illustrator behaves normally.
static const char *const kVerifiedBuilds[] = {
    "com.adobe.illustratorBeta/31.1.0",  // Illustrator 2027 Beta
    "com.adobe.illustrator/30.8.2",      // Illustrator 2026
};

namespace {

struct State {
    SPBasicSuite *basic = nullptr;
    SPPluginRef self = nullptr;
    const AINotifierSuite *notifier = nullptr;
    const AIMenuSuite *menu = nullptr;
    const AIPaintStyleSuite *paint = nullptr;
    int32_t notifierVersion = 0;
    AIMenuItemHandle colorItem = nullptr;
    AINotifierHandle nFillStroke = nullptr, nColorPre = nullptr, nColorPost = nullptr,
                     nShutdown = nullptr, nAllStarted = nullptr, nWorkspace = nullptr;
    id monitor = nil;
    pc::IntentModel model;
    uint64_t gesture = 0;
    NSSet *windowsAtDown = nil;  // visible window numbers when this click/key press started
    double inputAt = 0;          // when the current click/key press started
    uint64_t colorChangeGesture = 0;  // input during which Fill/Stroke or art properties changed
    NSMutableSet *evaluated = nil;  // window numbers already judged during this input
    AINotifierHandle nWatch[3] = {};
    id menuBegin = nil, menuAction = nil;
    CFRunLoopObserverRef checkObserver = nullptr;
    bool started = false;
    bool buildVerified = false;
    bool diagVerbose = false;
    char build[128] = "unknown";
    FILE *log = nullptr;
    double prefsReadAt = -1;
    // Debug recorder (defaults key "debugLog"; off by default, never in normal use).
    bool debug = false;
    id debugMonitor = nil;
    CFRunLoopObserverRef turnObserver = nullptr;
    bool inputThisTurn = false;
    NSString *baselineEvent = nil;
    NSDictionary *baseline = nil;               // window number -> fingerprint
    NSMutableArray<NSString *> *turnNotifiers = nil;
    AINotifierHandle nExtra[8] = {};
};
State g;

double now() { return CACurrentMediaTime(); }

// ---------------------------------------------------------------- logging
void openLog() {
    if (g.log) return;
    const char *override = getenv("CWN_LOG_DIR");
    NSString *dir = override ? @(override)
                             : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/ColorWindowNuke"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd";
    NSString *path = [dir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"colorwindownuke-%@.jsonl", [f stringFromDate:[NSDate date]]]];
    g.log = fopen(path.fileSystemRepresentation, "a");
    if (g.log) setvbuf(g.log, nullptr, _IOLBF, 0);
}

void logEvent(NSString *event, NSDictionary *fields) {
    if (!g.log) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    d[@"event"] = event;
    d[@"t"] = @(now());
    d[@"wall"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (json) {
        fwrite(json.bytes, 1, json.length, g.log);
        fputc('\n', g.log);
    }
}

// ---------------------------------------------------------------- suites
// The Paint Style suite is provided by another Illustrator plug-in and is
// not available yet while plug-ins are still starting; retry later.
void acquirePaint() {
    if (g.paint || !g.basic) return;
    const void *s = nullptr;
    if (g.basic->AcquireSuite(kAIPaintStyleSuite, kAIPaintStyleSuiteVersion10, &s) == kNoErr)
        g.paint = (const AIPaintStyleSuite *)s;
}

// ---------------------------------------------------------------- settings
void readPrefs(bool force) {
    if (!force && g.prefsReadAt >= 0 && now() - g.prefsReadAt < 1.0) return;
    g.prefsReadAt = now();
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain());
    NSString *mode = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("mode"), (__bridge CFStringRef)domain()));
    NSNumber *paused = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("paused"), (__bridge CFStringRef)domain()));
    NSNumber *allowUnverified = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("allowUnverifiedBuild"), (__bridge CFStringRef)domain()));
    NSNumber *verbose = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("verboseDiagnostics"), (__bridge CFStringRef)domain()));
    NSNumber *drawerExp = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("experimentalDrawer"), (__bridge CFStringRef)domain()));

    // Release default: on wherever this Illustrator build is verified; on any
    // other build the plug-in only observes (and logs nothing unless logging is
    // on), so Illustrator behaves natively. Settings only override the default.
    bool verified = g.buildVerified || [allowUnverified boolValue];
    pc::Mode m = verified ? pc::Mode::Enforce : pc::Mode::Diagnose;
    if ([mode isKindOfClass:NSString.class]) {
        if ([mode isEqualToString:@"off"]) m = pc::Mode::Off;
        else if ([mode isEqualToString:@"diagnose"]) m = pc::Mode::Diagnose;
        else if ([mode isEqualToString:@"enforce"]) m = pc::Mode::Enforce;
    }
    // Feature detection: never enforce on an unverified build, or without the
    // suite that closes the panel.
    if (m == pc::Mode::Enforce && !verified) m = pc::Mode::Diagnose;
    if (m == pc::Mode::Enforce && !g.paint) m = pc::Mode::Diagnose;
    g.model.setMode(m);
    g.model.setPaused([paused boolValue]);
    // Icon-dock drawer hiding is on unless switched off (docs/HOW-IT-WORKS.md).
    g.model.setDrawerExperiment(drawerExp ? [drawerExp boolValue] : true);
    g.diagVerbose = [verbose boolValue];
    NSNumber *debugLog = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("debugLog"), (__bridge CFStringRef)domain()));
    g.debug = [debugLog boolValue];
}

// ---------------------------------------------------------------- evidence
NSString *eventTypeName(NSEvent *e) {
    if (!e) return @"none";
    switch (e.type) {
        case NSEventTypeLeftMouseDown: return @"leftMouseDown";
        case NSEventTypeLeftMouseUp: return @"leftMouseUp";
        case NSEventTypeLeftMouseDragged: return @"leftMouseDragged";
        case NSEventTypeKeyDown: return @"keyDown";
        case NSEventTypeKeyUp: return @"keyUp";
        default: return [NSString stringWithFormat:@"type%lu", (unsigned long)e.type];
    }
}

bool isPointerEvent(NSEvent *e) {
    return e && (e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeLeftMouseUp ||
                 e.type == NSEventTypeLeftMouseDragged);
}

NSSet *visibleWindowNumbers() {
    NSMutableSet *set = [NSMutableSet set];
    for (NSWindow *w in NSApp.windows)
        if (w.isVisible) [set addObject:@(w.windowNumber)];
    return set;
}

// A floating Adobe panel window. Observed in Illustrator 31.1: the Color panel,
// auto-opened while floating, is an AdobeOwlUIWindow at NSFloatingWindowLevel.
// Pop-up dropdowns (e.g. DVAMacDialog swatch pop-ups, level 8) do not match.
bool isPanelWindow(NSWindow *w) {
    return [NSStringFromClass(w.class) containsString:@"Owl"] && w.level == NSFloatingWindowLevel;
}

NSDictionary *describeWindow(NSWindow *w) {
    NSMutableArray *subs = [NSMutableArray array];
    for (NSView *v in w.contentView.subviews) {
        if (subs.count >= 8) break;
        [subs addObject:NSStringFromClass(v.class)];
    }
    NSMutableDictionary *d = [@{@"cls": NSStringFromClass(w.class), @"level": @(w.level),
                                @"frame": NSStringFromRect(w.frame), @"panel": @(isPanelWindow(w)),
                                @"content": NSStringFromClass(w.contentView.class) ?: @"",
                                @"subviews": subs} mutableCopy];
    if (w.identifier) d[@"id"] = w.identifier;
    if (g.diagVerbose) d[@"title"] = w.title ?: @"";
    return d;
}

// Windows that became visible since this gesture's mouse-down.
NSArray<NSWindow *> *windowsSinceDown() {
    NSMutableArray *out = [NSMutableArray array];
    if (!g.windowsAtDown) return out;
    for (NSWindow *w in NSApp.windows)
        if (w.isVisible && ![g.windowsAtDown containsObject:@(w.windowNumber)]) [out addObject:w];
    return out;
}

// Informational only: the Window > Color checkmark is not live (docs/HOW-IT-WORKS.md).
NSString *menuChecked() {
    if (!g.menu || !g.colorItem) return @"unknown";
    AIBoolean checked = 0;
    if (g.menu->IsItemChecked(g.colorItem, &checked) != kNoErr) return @"unknown";
    return checked ? @"yes" : @"no";
}

void findColorMenuItem() {
    if (!g.menu) return;
    int32_t count = 0;
    if (g.menu->CountMenuItems(&count) != kNoErr) return;
    for (int32_t i = 0; i < count; ++i) {
        AIMenuItemHandle h = nullptr;
        const char *key = nullptr;
        if (g.menu->GetNthMenuItem(i, &h) != kNoErr || !h) continue;
        if (g.menu->GetMenuItemKeyboardShortcutDictionaryKey(h, &key) != kNoErr || !key) continue;
        if (strcmp(key, kColorCommandKey) == 0) {
            g.colorItem = h;
            break;
        }
    }
    logEvent(@"colorMenuItem", @{@"found": @(g.colorItem != nullptr), @"menuItems": @(count)});
}

// ---------------------------------------------------------------- debug recorder
// Records how Adobe panel windows change on each mouse/keyboard input, using
// the accessibility description AppKit/Adobe publish for VoiceOver (in-process,
// no permission needed) plus the view tree. Used to study the docked-panel,
// "<" key and Appearance paths. Never records which key was pressed or any
// artwork; panel labels (e.g. tab names, possibly layer names) are recorded.
static const char *const kExtraNotifiers[] = {
    "AI Update PathStyle Notifier", "AI Tool Selected Notifier", "AI Effective Tool Changed Notifier",
    "AI Doc Swatches Selection Changed Notifier", "AI Swatch List Changed Notifier",
};
// Fired (with no Fill/Stroke notifier) when "<" or the Appearance panel opens
// Color (guided test 4); used as early checkpoints for the generic path.
static const char *const kWatchNotifiers[] = {
    "AI Art Selection Changed Notifier", "AI Art Properties Changed Notifier", "AI Art Style Focus Changed Notifier",
};

void axWalk(id el, int depth, NSMutableArray *out) {
    if (!el || depth > 10 || out.count >= 300) return;
    NSString *role = [el respondsToSelector:@selector(accessibilityRole)] ? [el accessibilityRole] : nil;
    NSString *title = [el respondsToSelector:@selector(accessibilityTitle)] ? [el accessibilityTitle] : nil;
    NSString *label = [el respondsToSelector:@selector(accessibilityLabel)] ? [el accessibilityLabel] : nil;
    id value = [el respondsToSelector:@selector(accessibilityValue)] ? [el accessibilityValue] : nil;
    BOOL sel = [el respondsToSelector:@selector(isAccessibilitySelected)] ? [el isAccessibilitySelected] : NO;
    NSString *name = title.length ? title : label;
    if (name.length || sel || [role isEqualToString:NSAccessibilityTabGroupRole] ||
        [role isEqualToString:NSAccessibilityRadioButtonRole])
        [out addObject:[NSString stringWithFormat:@"%d|%@|%@|%@|%@", depth, role ?: @"", name ?: @"", sel ? @"sel" : @"",
                                                  [value isKindOfClass:NSNumber.class] ? value : @""]];
    NSArray *kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil;
    for (id k in kids) axWalk(k, depth + 1, out);
}

void viewWalk(NSView *v, int depth, NSMutableArray *out) {
    if (!v || depth > 6 || out.count >= 150) return;
    [out addObject:[NSString stringWithFormat:@"%d|%@|%@|%.0fx%.0f", depth, NSStringFromClass(v.class),
                                              v.isHidden ? @"hidden" : @"", v.frame.size.width, v.frame.size.height]];
    for (NSView *sub in v.subviews) viewWalk(sub, depth + 1, out);
}

NSDictionary *owlFingerprint() {
    NSMutableDictionary *fp = [NSMutableDictionary dictionary];
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible || ![NSStringFromClass(w.class) containsString:@"Owl"]) continue;
        NSMutableArray *ax = [NSMutableArray array], *views = [NSMutableArray array];
        axWalk(w, 0, ax);
        viewWalk(w.contentView, 0, views);
        fp[@(w.windowNumber)] = @{@"frame": NSStringFromRect(w.frame), @"level": @(w.level), @"ax": ax, @"views": views};
    }
    return fp;
}

NSArray *setDiff(NSArray *a, NSArray *b) {  // lines in a that are not in b (capped)
    NSMutableOrderedSet *s = [NSMutableOrderedSet orderedSetWithArray:a ?: @[]];
    [s minusSet:[NSSet setWithArray:b ?: @[]]];
    NSArray *r = s.array;
    return r.count > 60 ? [r subarrayWithRange:NSMakeRange(0, 60)] : r;
}

void debugTurnEnded() {
    if (!g.inputThisTurn) return;
    g.inputThisTurn = false;
    NSDictionary *before = g.baseline, *after = owlFingerprint();
    NSMutableArray *changes = [NSMutableArray array];
    NSMutableSet *keys = [NSMutableSet setWithArray:before.allKeys];
    [keys addObjectsFromArray:after.allKeys];
    for (NSNumber *n in keys) {
        NSDictionary *b = before[n], *a = after[n];
        if (!b || !a) {
            [changes addObject:@{@"window": n, @"change": b ? @"hidden" : @"shown", @"frame": (a ?: b)[@"frame"],
                                 @"level": (a ?: b)[@"level"], @"ax": (a ?: b)[@"ax"]}];
            continue;
        }
        NSArray *axAdd = setDiff(a[@"ax"], b[@"ax"]), *axDel = setDiff(b[@"ax"], a[@"ax"]);
        NSArray *vAdd = setDiff(a[@"views"], b[@"views"]), *vDel = setDiff(b[@"views"], a[@"views"]);
        bool moved = ![a[@"frame"] isEqual:b[@"frame"]];
        if (axAdd.count || axDel.count || vAdd.count || vDel.count || moved)
            [changes addObject:@{@"window": n, @"change": @"changed", @"frameBefore": b[@"frame"], @"frame": a[@"frame"],
                                 @"level": a[@"level"], @"axAdded": axAdd, @"axRemoved": axDel,
                                 @"viewsAdded": vAdd, @"viewsRemoved": vDel}];
    }
    if (changes.count || g.turnNotifiers.count)
        logEvent(@"panelChange", @{@"input": g.baselineEvent ?: @"", @"notifiers": g.turnNotifiers ?: @[],
                                   @"changes": changes});
}

// Full snapshot of every Adobe panel window (debug only), shortly after `why`
// so the layout has settled. Used to study docked groups and icon docks.
void dumpPanelsSoon(NSString *why) {
    if (!g.debug) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSMutableArray *wins = [NSMutableArray array];
        NSDictionary *fp = owlFingerprint();
        for (NSNumber *n in fp) {
            NSMutableDictionary *d = [fp[n] mutableCopy];
            d[@"window"] = n;
            [wins addObject:d];
        }
        logEvent(@"panelDump", @{@"why": why, @"windows": wins});
    });
}

void installDebugRecorder() {
    if (!g.debug || g.debugMonitor) return;
    g.debugMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                                                                   NSEventMaskKeyDown
                                                           handler:^NSEvent *(NSEvent *e) {
        if (g.inputThisTurn) debugTurnEnded();
        g.baseline = owlFingerprint();
        g.baselineEvent = e.type == NSEventTypeKeyDown ? @"key" : e.type == NSEventTypeLeftMouseDown ? @"mouseDown" : @"mouseUp";
        g.turnNotifiers = [NSMutableArray array];
        g.inputThisTurn = true;
        return e;  // observation only; which key was pressed is never recorded
    }];
    g.turnObserver = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting, true, 0,
                                                        ^(CFRunLoopObserverRef, CFRunLoopActivity) { debugTurnEnded(); });
    CFRunLoopAddObserver(CFRunLoopGetMain(), g.turnObserver, kCFRunLoopCommonModes);
    logEvent(@"debugRecorder", @{@"on": @YES, @"panelWindows": @(owlFingerprint().count)});
    dumpPanelsSoon(@"ready");
}

void removeDebugRecorder() {
    if (g.debugMonitor) [NSEvent removeMonitor:g.debugMonitor];
    g.debugMonitor = nil;
    if (g.turnObserver) {
        CFRunLoopObserverInvalidate(g.turnObserver);
        CFRelease(g.turnObserver);
        g.turnObserver = nullptr;
    }
}

// ---------------------------------------------------------------- Color panel identification
// The Color panel is recognised from the description Adobe publishes for it
// (the one VoiceOver reads): a "Color" tab and/or a color spectrum area. A
// floating panel window has a Close button; an icon-dock drawer has
// "Expand Panels" and no Close button (guided test 4). Labels are English for
// now (localisation is an open item).
static NSArray *const kColorTabTitles = @[@"Color"];

struct ColorInfo {
    bool color = false, floating = false, drawer = false;
};

ColorInfo colorInfo(NSWindow *w) {
    ColorInfo ci;
    NSMutableArray *ax = [NSMutableArray array];
    axWalk(w, 0, ax);
    bool close = false, expand = false;
    for (NSString *line in ax) {
        NSArray *p = [line componentsSeparatedByString:@"|"];
        if (p.count < 3) continue;
        NSString *role = p[1], *name = p[2];
        if ([role isEqualToString:NSAccessibilityTabGroupRole] && [kColorTabTitles containsObject:name]) ci.color = true;
        if ([role isEqualToString:@"AXLayoutArea"] && ([name hasSuffix:@"Spectrum"] || [name hasSuffix:@"Ramp"])) ci.color = true;
        if ([role isEqualToString:NSAccessibilityButtonRole] && [name isEqualToString:@"Close"]) close = true;
        if ([role isEqualToString:NSAccessibilityButtonRole] && [name isEqualToString:@"Expand Panels"]) expand = true;
    }
    ci.floating = ci.color && close;
    ci.drawer = ci.color && !close && expand;
    return ci;
}

// ---------------------------------------------------------------- core
void reverseActivation(NSWindow *panel, CGFloat alpha, uint64_t gesture, double tNotify);

// Close the panel properly in this run-loop iteration, outside whatever
// Illustrator handler we are inside. The window must already be concealed.
void scheduleReverse(NSWindow *panel, CGFloat alpha, double t) {
    [g.evaluated addObject:@(panel.windowNumber)];
    uint64_t gesture = g.gesture;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ reverseActivation(panel, alpha, gesture, t); });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

// EXPERIMENTAL: put away an icon-dock drawer that a color change popped out.
// There is no supported way to collapse it, so the drawer window itself is
// ordered out (Illustrator's Color panel state is never touched). Its look is
// always restored; if Illustrator brings it back, drawer handling stops for the
// session instead of fighting it.
void hideDrawer(NSWindow *drawer, CGFloat alpha) {
    drawer.alphaValue = 0;  // may already be 0 (Fill/Stroke path conceals first)
    [g.evaluated addObject:@(drawer.windowNumber)];
    uint64_t gesture = g.gesture;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if (drawer.isVisible) [drawer orderOut:nil];
        drawer.alphaValue = alpha;
        logEvent(@"drawerHidden", @{@"gesture": @(gesture), @"visibleAfter": @(drawer.isVisible)});
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    for (double delay : {0.3, 1.5}) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (g.gesture != gesture) return;  // you clicked/typed since: any reopening is yours, not Illustrator's
            bool back = drawer.isVisible;
            logEvent(@"drawerCheck", @{@"gesture": @(gesture), @"afterSec": @(delay), @"visible": @(back),
                                       @"alpha": @(drawer.alphaValue)});
            if (back && !g.model.drawerDisabled()) {
                drawer.alphaValue = alpha;
                g.model.disableDrawerForSession();
                logEvent(@"drawerHandlingStopped", @{@"reason": @"Illustrator showed the drawer again"});
            }
        });
    }
}

// Hide the window this instant (transparent), then close the panel.
void concealAndReverse(NSWindow *panel, double t) {
    CGFloat alpha = panel.alphaValue;
    panel.alphaValue = 0;
    scheduleReverse(panel, alpha, t);
}

// Generic path: a window identified as the Color panel became visible during
// the current click or key press. Called from Illustrator notifiers that fire
// on those paths and, as a fallback, at the end of each run-loop turn.
void checkColorAppeared(NSString *source) {
    if (g.model.mode() == pc::Mode::Off || !g.windowsAtDown) return;
    bool during = now() - g.inputAt < 0.75;
    if (!during) return;
    NSMutableArray<NSWindow *> *floating = [NSMutableArray array];
    NSMutableArray<NSWindow *> *drawerWins = [NSMutableArray array];
    int drawers = 0;
    NSMutableArray *desc = [NSMutableArray array];
    for (NSWindow *w in windowsSinceDown()) {
        NSNumber *n = @(w.windowNumber);
        if (!isPanelWindow(w) || [g.evaluated containsObject:n]) continue;
        [g.evaluated addObject:n];
        ColorInfo ci = colorInfo(w);
        if (ci.floating) [floating addObject:w];
        else if (ci.drawer) {
            ++drawers;
            [drawerWins addObject:w];
            dumpPanelsSoon(@"drawer");
        }
        NSMutableDictionary *d = [describeWindow(w) mutableCopy];
        d[@"color"] = @(ci.color);
        d[@"floating"] = @(ci.floating);
        d[@"drawer"] = @(ci.drawer);
        [desc addObject:d];
    }
    if (!desc.count) return;
    acquirePaint();
    readPrefs(false);
    pc::Decision would = {false, ""};
    if (g.model.mode() == pc::Mode::Diagnose) {
        pc::IntentModel probe = g.model;
        probe.setMode(pc::Mode::Enforce);
        would = probe.onColorWindowAppeared(during, (int)floating.count, drawers);
    }
    pc::Decision d = g.model.onColorWindowAppeared(during, (int)floating.count, drawers);
    NSMutableDictionary *f = [@{@"gesture": @(g.gesture), @"source": source, @"currentEvent": eventTypeName(NSApp.currentEvent),
                                @"newWindows": desc, @"decision": @(d.hide), @"reason": @(d.reason)} mutableCopy];
    if (g.model.mode() == pc::Mode::Diagnose) {
        f[@"enforceWouldReverse"] = @(would.hide);
        f[@"enforceReason"] = @(would.reason);
    }
    logEvent(@"colorAppeared", f);
    if (d.hide) concealAndReverse(floating.firstObject, now());
    for (NSWindow *dw in drawerWins) {
        pc::Decision dd = g.model.onDrawerAppeared(during, g.colorChangeGesture == g.gesture);
        logEvent(@"drawerAppeared", @{@"gesture": @(g.gesture), @"source": source, @"decision": @(dd.hide),
                                      @"reason": @(dd.reason)});
        if (dd.hide) hideDrawer(dw, dw.alphaValue);
    }
}

void installMonitor() {
    if (g.monitor) return;
    // In-process local monitor: sees only Illustrator's own left-mouse-downs and
    // key-downs, needs no Accessibility permission, and never consumes or alters
    // the event. It only notes *that* an input started; which key was pressed is
    // never read or recorded.
    g.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskKeyDown
                                                      handler:^NSEvent *(NSEvent *e) {
        if (g.model.mode() == pc::Mode::Off) return e;
        g.model.onInputStart(++g.gesture);
        g.windowsAtDown = visibleWindowNumbers();
        g.inputAt = now();
        g.evaluated = [NSMutableSet set];
        if (g.model.mode() == pc::Mode::Diagnose)
            logEvent(@"inputStart", @{@"gesture": @(g.gesture), @"kind": e.type == NSEventTypeKeyDown ? @"key" : @"click",
                                      @"visibleWindows": @(g.windowsAtDown.count)});
        return e;
    }];
    // Menu use (mouse or keyboard shortcut) is always an explicit command.
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    g.menuBegin = [nc addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil
                              usingBlock:^(NSNotification *) { g.model.onMenuAction(); }];
    g.menuAction = [nc addObserverForName:NSMenuWillSendActionNotification object:nil queue:nil
                               usingBlock:^(NSNotification *) { g.model.onMenuAction(); }];
    // Fallback checkpoint at the end of every run-loop turn (cheap unless an
    // input started in the last 750 ms).
    g.checkObserver = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting, true, 1,
                                                         ^(CFRunLoopObserverRef, CFRunLoopActivity) { checkColorAppeared(@"turnEnd"); });
    CFRunLoopAddObserver(CFRunLoopGetMain(), g.checkObserver, kCFRunLoopCommonModes);
}

void removeMonitor() {
    if (g.monitor) [NSEvent removeMonitor:g.monitor];
    g.monitor = nil;
    if (g.menuBegin) [NSNotificationCenter.defaultCenter removeObserver:g.menuBegin];
    if (g.menuAction) [NSNotificationCenter.defaultCenter removeObserver:g.menuAction];
    g.menuBegin = g.menuAction = nil;
    if (g.checkObserver) {
        CFRunLoopObserverInvalidate(g.checkObserver);
        CFRelease(g.checkObserver);
        g.checkObserver = nullptr;
    }
}

// Closes the auto-opened panel and checks that its window actually went away.
// The window was made transparent when the click was detected (see
// onFillStrokeChanged); its original transparency is always restored here, so a
// panel can never be left open but invisible.
void reverseActivation(NSWindow *panel, CGFloat alpha, uint64_t gesture, double tNotify) {
    if (!panel.isVisible) {  // already gone: never toggle a hidden panel open
        panel.alphaValue = alpha;
        logEvent(@"reversalSkipped", @{@"gesture": @(gesture), @"reason": @"window no longer visible"});
        return;
    }
    ASErr err;
    {
        pc::IntentModel::Reentry guard(g.model);
        err = g.paint->ToggleColorDialog();
    }
    bool gone = !panel.isVisible;
    panel.alphaValue = alpha;
    if (!gone) {  // our reading of this build is wrong: show the native panel, stop acting
        g.model.disableForSession();
        logEvent(@"sessionDisabled", @{@"reason": @"Color panel window still visible after ToggleColorDialog"});
    }
    logEvent(@"reversed", @{@"gesture": @(gesture), @"err": @(err), @"windowGone": @(gone),
                            @"latencyMs": @((now() - tNotify) * 1000.0)});
    // Record when the next display commit point is reached, relative to the click's notifier.
    CFRunLoopObserverRef obs = CFRunLoopObserverCreateWithHandler(
        nullptr, kCFRunLoopBeforeWaiting, false, 0, ^(CFRunLoopObserverRef o, CFRunLoopActivity) {
            logEvent(@"runloopBeforeWaiting", @{@"gesture": @(gesture), @"sinceNotifyMs": @((now() - tNotify) * 1000.0),
                                                @"windowVisible": @(panel.isVisible)});
            CFRunLoopObserverInvalidate(o);
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    CFRelease(obs);
    // Verify a moment later. If the window is still there, our reading of this
    // build is wrong: stop acting for the rest of the session (no retry loops).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        bool stillVisible = panel.isVisible;
        logEvent(@"reversalVerified", @{@"gesture": @(gesture), @"windowVisible": @(stillVisible),
                                        @"alpha": @(panel.alphaValue)});
        if (stillVisible && !g.model.sessionDisabled()) {
            g.model.disableForSession();
            logEvent(@"sessionDisabled", @{@"reason": @"Color panel window reappeared after ToggleColorDialog"});
        }
    });
}

void onFillStrokeChanged() {
    acquirePaint();
    readPrefs(false);
    NSEvent *cur = NSApp.currentEvent;
    bool pointer = isPointerEvent(cur);
    NSArray<NSWindow *> *appeared = windowsSinceDown();
    NSMutableArray<NSWindow *> *panels = [NSMutableArray array];
    for (NSWindow *w in appeared)
        if (isPanelWindow(w) && ![g.evaluated containsObject:@(w.windowNumber)]) [panels addObject:w];
    double t = now();
    // Time matters on this path (Illustrator already put the window on screen):
    // with exactly one candidate, hide it *before* the slower identification
    // below, so it can never be seen even for a frame (regression in v0.5).
    NSWindow *candidate = panels.count == 1 ? panels.firstObject : nil;
    CGFloat candidateAlpha = candidate.alphaValue;
    bool concealed = candidate && pointer && g.model.mode() == pc::Mode::Enforce;
    if (concealed) candidate.alphaValue = 0;
    // Icon-dock drawers are never closed: that would remove the icon from the dock.
    g.colorChangeGesture = g.gesture;
    bool drawer = candidate && colorInfo(candidate).drawer;
    if (drawer) {
        dumpPanelsSoon(@"drawer");
        pc::Decision dd = g.model.onDrawerAppeared(pointer, true);
        logEvent(@"drawerAppeared", @{@"gesture": @(g.gesture), @"source": @"fillStroke", @"decision": @(dd.hide),
                                      @"reason": @(dd.reason)});
        if (dd.hide) hideDrawer(candidate, candidateAlpha);
        else if (concealed) candidate.alphaValue = candidateAlpha;
        concealed = false;
        [panels removeObject:candidate];
        [g.evaluated addObject:@(candidate.windowNumber)];
    }

    // In diagnose mode, also evaluate what enforce mode would do, on a copy so
    // the real model is untouched.
    pc::Decision would = {false, ""};
    if (g.model.mode() == pc::Mode::Diagnose) {
        pc::IntentModel probe = g.model;
        probe.setMode(pc::Mode::Enforce);
        would = probe.onFillStrokeChanged(pointer, (int)panels.count);
    }
    pc::Decision d = g.model.onFillStrokeChanged(pointer, (int)panels.count);
    if (g.model.mode() != pc::Mode::Off && (pointer || g.diagVerbose)) {
        NSMutableArray *desc = [NSMutableArray array];
        for (NSWindow *w in appeared) [desc addObject:describeWindow(w)];
        NSMutableDictionary *f = [@{@"gesture": @(g.gesture), @"currentEvent": eventTypeName(cur),
                                    @"newWindows": desc, @"decision": @(d.hide), @"reason": @(d.reason),
                                    @"menuChecked": menuChecked()} mutableCopy];
        if (g.model.mode() == pc::Mode::Diagnose) {
            f[@"enforceWouldReverse"] = @(would.hide);
            f[@"enforceReason"] = @(would.reason);
        }
        logEvent(@"fillStrokeChanged", f);
    }
    if (!d.hide) {
        if (concealed) candidate.alphaValue = candidateAlpha;  // not ours to close after all
        return;
    }
    // Illustrator ordered the window on screen microseconds ago, inside this same
    // click, and finishes the rest of the click (12-70 ms in Illustrator 31.1)
    // before a reversal could run; it was concealed above.
    if (concealed) scheduleReverse(candidate, candidateAlpha, t);
    else concealAndReverse(panels.firstObject, t);
}

ASErr startup(SPMessageData *msg) {
    g.basic = msg->basic;
    g.self = msg->self;

    // Keep our image mapped even if the host unloads the plug-in: the event
    // monitor block and run-loop blocks reference code in this image.
    Dl_info info;
    if (dladdr((const void *)&startup, &info) && info.dli_fname) dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);

    NSBundle *mb = NSBundle.mainBundle;
    snprintf(g.build, sizeof g.build, "%s/%s", mb.bundleIdentifier.UTF8String ?: "?",
             [[mb objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "?");
    for (const char *b : kVerifiedBuilds)
        if (strcmp(b, g.build) == 0) g.buildVerified = true;

    // Quiet by default: a log is written only when logging (or the debug
    // recorder) is switched on for troubleshooting.
    NSNumber *logging = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("logging"), (__bridge CFStringRef)domain()));
    NSNumber *debugAtStart = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("debugLog"), (__bridge CFStringRef)domain()));
    if ([logging boolValue] || [debugAtStart boolValue]) openLog();
    const void *s = nullptr;
    if (g.basic->AcquireSuite(kAINotifierSuite, kAINotifierSuiteVersion5, &s) == kNoErr) g.notifierVersion = 5;
    else if (g.basic->AcquireSuite(kAINotifierSuite, kAINotifierSuiteVersion4, &s) == kNoErr) g.notifierVersion = 4;
    g.notifier = (const AINotifierSuite *)s;
    s = nullptr;
    if (g.basic->AcquireSuite(kAIMenuSuite, kAIMenuSuiteVersion11, &s) == kNoErr) g.menu = (const AIMenuSuite *)s;
    acquirePaint();

    logEvent(@"startup", @{@"version": @PC_VERSION, @"build": @(g.build), @"buildVerified": @(g.buildVerified),
                           @"pid": @(getpid()), @"notifierSuite": @(g.notifierVersion),
                           @"menuSuite": @(g.menu != nullptr), @"paintStyleSuite": @(g.paint != nullptr)});
    if (!g.notifier) return kNoErr;  // nothing we can do; stay inert

    g.notifier->AddNotifier(g.self, kPluginName, kAIPaintStyleFillStrokeChangedNotifier, &g.nFillStroke);
    g.notifier->AddNotifier(g.self, kPluginName, kAIAdobeColorPaletteCommandPreNotifierStr, &g.nColorPre);
    g.notifier->AddNotifier(g.self, kPluginName, kAIAdobeColorPaletteCommandPostNotifierStr, &g.nColorPost);
    g.notifier->AddNotifier(g.self, kPluginName, kAIAllPluginStartedNotifier, &g.nAllStarted);
    g.notifier->AddNotifier(g.self, kPluginName, kAIApplicationShutdownNotifier, &g.nShutdown);
    g.notifier->AddNotifier(g.self, kPluginName, kAIWorkspaceRestoreFinishNotifier, &g.nWorkspace);
    for (size_t i = 0; i < sizeof kWatchNotifiers / sizeof *kWatchNotifiers; ++i)
        g.notifier->AddNotifier(g.self, kPluginName, kWatchNotifiers[i], &g.nWatch[i]);
    NSNumber *debugLog = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("debugLog"), (__bridge CFStringRef)domain()));
    if ([debugLog boolValue])
        for (size_t i = 0; i < sizeof kExtraNotifiers / sizeof *kExtraNotifiers; ++i)
            g.notifier->AddNotifier(g.self, kPluginName, kExtraNotifiers[i], &g.nExtra[i]);
    g.started = true;
    return kNoErr;
}

void shutdown() {
    removeMonitor();
    removeDebugRecorder();
    logEvent(@"shutdown", @{@"sessionDisabled": @(g.model.sessionDisabled())});
    if (g.log) fclose(g.log);
    g.log = nullptr;
    if (g.basic) {
        if (g.paint) g.basic->ReleaseSuite(kAIPaintStyleSuite, kAIPaintStyleSuiteVersion10);
        if (g.menu) g.basic->ReleaseSuite(kAIMenuSuite, kAIMenuSuiteVersion11);
        if (g.notifier)
            g.basic->ReleaseSuite(kAINotifierSuite, g.notifierVersion == 5 ? kAINotifierSuiteVersion5 : kAINotifierSuiteVersion4);
    }
    g.paint = nullptr;
    g.menu = nullptr;
    g.notifier = nullptr;
    g.started = false;
}

ASErr notify(AINotifierMessage *m) {
    // Only act on the serial, main-thread delivery. (Parallel dispatch is opt-in
    // via AddNotifierEx; we never request it, but never touch AppKit off-main.)
    if (m->isParallelDispatch || !NSThread.isMainThread) return kNoErr;
    @autoreleasepool {
        if (g.debug && g.inputThisTurn && m->type) [g.turnNotifiers addObject:@(m->type)];
        if (m->notifier == g.nFillStroke) {
            onFillStrokeChanged();
        } else if (m->notifier == g.nColorPre) {
            g.model.onExplicitCommandBegin();
            logEvent(@"colorCommandBefore", @{@"gesture": @(g.gesture), @"currentEvent": eventTypeName(NSApp.currentEvent)});
        } else if (m->notifier == g.nColorPost) {
            g.model.onExplicitCommandEnd();
            logEvent(@"colorCommandAfter", @{@"gesture": @(g.gesture)});
        } else if (m->notifier == g.nAllStarted) {
            acquirePaint();
            findColorMenuItem();
            readPrefs(true);
            installMonitor();
            installDebugRecorder();
            logEvent(@"ready", @{@"mode": @((int)g.model.mode()), @"paintStyleSuite": @(g.paint != nullptr)});
        } else if (m->notifier == g.nWorkspace) {
            g.model.onWorkspaceChanged();
            dumpPanelsSoon(@"workspace");
            logEvent(@"workspaceRestored", @{@"gesture": @(g.gesture)});
        } else if (m->notifier && (m->notifier == g.nWatch[0] || m->notifier == g.nWatch[1] || m->notifier == g.nWatch[2])) {
            if (m->notifier == g.nWatch[1]) g.colorChangeGesture = g.gesture;  // Art Properties Changed
            checkColorAppeared(@"notifier");
        } else if (m->notifier == g.nShutdown) {
            shutdown();
        }
    }
    return kNoErr;
}

}  // namespace

extern "C" __attribute__((visibility("default"))) ASErr PluginMain(char *caller, char *selector, void *message) {
    @autoreleasepool {
        @try {
            if (strcmp(caller, kSPInterfaceCaller) == 0) {
                if (strcmp(selector, kSPInterfaceStartupSelector) == 0) return startup((SPMessageData *)message);
                if (strcmp(selector, kSPInterfaceShutdownSelector) == 0) { if (g.started) shutdown(); return kNoErr; }
            } else if (strcmp(caller, kCallerAINotify) == 0 && strcmp(selector, kSelectorAINotify) == 0) {
                return g.started ? notify((AINotifierMessage *)message) : kNoErr;
            } else if (strcmp(caller, kSPAccessCaller) == 0) {
                // Unload/Reload: our image stays mapped (see startup), state persists.
                logEvent(@"access", @{@"selector": @(selector)});
                return kNoErr;
            }
        } @catch (NSException *ex) {
            os_log_error(OS_LOG_DEFAULT, "ColorWindowNuke exception: %{public}@", ex.reason);
        }
    }
    return kNoErr;
}
