// mockhost.mm — headless integration test for the compiled ColorWindowNuke.aip.
//
// Loads the real plug-in binary into a background process (activation policy
// "prohibited": no Dock icon, never takes focus) and plays Illustrator's part,
// using the behaviour observed in Illustrator 2026/2027 (docs/HOW-IT-WORKS.md):
//   proxy click on the inactive proxy -> Color panel window becomes visible
//     -> Set{Fill,Stroke}Active() -> Notify(FillStrokeChanged), on the click
//   Window > Color / F6 -> Notify(Before) -> toggle -> Notify(After), no Fill/Stroke notifier
//   keyboard X -> swap -> Notify(FillStrokeChanged), never shows the panel
//   swatch pop-up (DVAMacDialog, level 8) may appear during a Fill/Stroke change
// The "panel" and "pop-up" are real NSWindows so the plug-in's window evidence is
// exercised, but they sit far off-screen, fully transparent and ignore the mouse:
// nothing is ever drawn on the user's displays. Events go only to this process.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <map>
#include <string>
#ifdef PC_OFFICIAL_SDK
#include "PCOfficialSDK.h"  // official Adobe Illustrator SDK (obtained from Adobe, not bundled)
#else
#include "PCShim.h"         // private dev stand-in, not published
#endif

@interface MockOwlPanelWindow : NSPanel  // class name contains "Owl" like AdobeOwlUIWindow
@end
@implementation MockOwlPanelWindow
@end
@interface MockDVAMacDialog : NSPanel
@end
@implementation MockDVAMacDialog
@end
static bool gStickyDrawer = false;  // simulates Illustrator re-showing a drawer we put away
@interface MockOwlDrawerWindow : NSPanel
@end
@implementation MockOwlDrawerWindow
- (void)orderOut:(id)sender {
    [super orderOut:sender];
    if (gStickyDrawer)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self orderFront:nil]; });
}
@end

typedef ASErr (*PluginMainFn)(char *, char *, void *);
static PluginMainFn gMain;
static std::map<std::string, AINotifierHandle> gNotifiers;
static NSWindow *gColor, *gPopup, *gGradient, *gDrawer;
static bool gFillActive = true, gToggleBroken = false;
static int gToggles = 0, gFailures = 0, gPasses = 0;
static NSInteger gVisibleAtCommit = -1;  // Color visibility at first BeforeWaiting after a click
static CGFloat gAlphaAtNotify = -1;      // panel transparency right after the Fill/Stroke notifier returns
static const CGFloat kAlpha = 0.5;       // mock panel's normal alpha (windows are off-screen regardless)

static bool colorVisible() { return gColor.isVisible; }
static void showColor() { if (!colorVisible()) [gColor orderFront:nil]; }
static void hideColor() { [gColor orderOut:nil]; }

static void notify(const char *type) {
    auto it = gNotifiers.find(type);
    if (it == gNotifiers.end()) return;
    AINotifierMessage m = {};
    m.notifier = it->second;
    m.type = type;
    gMain((char *)kCallerAINotify, (char *)kSelectorAINotify, &m);
}

// ---- fake suites -----------------------------------------------------------
static AIErr fAddNotifier(SPPluginRef, const char *, const char *type, AINotifierHandle *h) {
    *h = (AINotifierHandle)(uintptr_t)(gNotifiers.size() + 1);
    gNotifiers[type] = *h;
    return kNoErr;
}
static AINotifierSuite sNotifier = {fAddNotifier};

static AIMenuItemHandle const kColorItem = (AIMenuItemHandle)0xC010;
static AIErr fCount(int32_t *c) { *c = 1; return kNoErr; }
static AIErr fNth(int32_t, AIMenuItemHandle *h) { *h = kColorItem; return kNoErr; }
static AIErr fKey(AIMenuItemHandle, const char **k) { *k = "Adobe Color Palette"; return kNoErr; }
static AIErr fChecked(AIMenuItemHandle, AIBoolean *b) { *b = 0; return kNoErr; }  // stale, as observed
static AIMenuSuite sMenu;

static void fSetStroke() { gFillActive = false; notify(kAIPaintStyleFillStrokeChangedNotifier); }
static void fSetFill() { gFillActive = true; notify(kAIPaintStyleFillStrokeChangedNotifier); }
static ASErr fToggle() {
    ++gToggles;
    if (gToggleBroken) return kNoErr;  // simulates a build where our reading is wrong
    if (colorVisible()) hideColor(); else showColor();
    return kNoErr;
}
static AIPaintStyleSuite sPaint;

static SPErr fAcquire(const char *name, int32_t version, const void **s) {
    std::string n = name;
    if (n == kAINotifierSuite && version == 1005) { *s = &sNotifier; return kNoErr; }
    if (n == kAIMenuSuite && version == 1011) { *s = &sMenu; return kNoErr; }
    if (n == kAIPaintStyleSuite && version == 1010) { *s = &sPaint; return kNoErr; }
    return 'S!Fd';
}
static SPErr fRelease(const char *, int32_t) { return kNoErr; }
static SPBasicSuite sBasic = {fAcquire, fRelease};

// ---- Illustrator's behaviour, emulated --------------------------------------
enum : short { kProxyClick = 1, kSwapKey = 2, kPopupClick = 3, kProxyDrawerClick = 4, kWorkspaceClick = 5, kMenuClick = 6,
               kIconClick = 7 };
static const char *const kArtProps = "AI Art Properties Changed Notifier";

@interface HostApp : NSApplication
@end
@implementation HostApp
- (void)sendEvent:(NSEvent *)e {
    [super sendEvent:e];  // local monitors run here, before the "control" handles the event
    if (e.type == NSEventTypeLeftMouseDown && e.subtype == kProxyClick) {
        gVisibleAtCommit = -1;
        showColor();                                // Illustrator shows the Color panel first
        if (gFillActive) fSetStroke(); else fSetFill();
        gAlphaAtNotify = gColor.isVisible ? gColor.alphaValue : -1;
        usleep(25000);                              // Illustrator finishes the click (~25 ms observed)
    } else if (e.type == NSEventTypeLeftMouseDown && e.subtype == kPopupClick) {
        gVisibleAtCommit = -1;
        [gPopup orderFront:nil];                    // swatch pop-up, not the Color panel
        fSetFill();
    } else if (e.type == NSEventTypeLeftMouseDown && e.subtype == kProxyDrawerClick) {
        gVisibleAtCommit = -1;
        [gDrawer orderFront:nil];                   // Color pops out of an icon dock
        if (gFillActive) fSetStroke(); else fSetFill();
    } else if (e.type == NSEventTypeLeftMouseDown && e.subtype == kIconClick) {
        [gDrawer orderFront:nil];                   // user clicks the Color icon: drawer, no color change
    } else if (e.type == NSEventTypeLeftMouseDown && e.subtype == kWorkspaceClick) {
        showColor();                                // workspace restores a visible Color panel
        notify(kAIWorkspaceRestoreFinishNotifier);
    } else if (e.type == NSEventTypeLeftMouseDown && e.subtype == kMenuClick) {
        [NSNotificationCenter.defaultCenter postNotificationName:NSMenuWillSendActionNotification object:nil];
        showColor();                                // e.g. a menu command that shows Color
        notify(kArtProps);
    } else if (e.type == NSEventTypeKeyDown) {
        NSString *c = e.charactersIgnoringModifiers;
        if ([c isEqualToString:@"<"]) { showColor(); notify(kArtProps); }        // "<": Color, with art-properties notifier
        else if ([c isEqualToString:@">"]) { [gGradient orderFront:nil]; notify(kArtProps); }  // ">": Gradient panel
        else if ([c isEqualToString:@"c"]) { showColor(); }                      // Color with no notifier at all
        else if ([c isEqualToString:@"d"]) { [gDrawer orderFront:nil]; notify(kArtProps); }    // Color drawer
    } else if (e.type == NSEventTypeApplicationDefined && e.subtype == kSwapKey) {
        gFillActive = !gFillActive;                 // X: swap, no Show
        notify(kAIPaintStyleFillStrokeChangedNotifier);
    }
}
@end

static void pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [NSApp sendEvent:e];
    }
}

static void mouse(short subtype) {
    NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(5, 5)
                               modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                 eventNumber:0 clickCount:1 pressure:1];
    CGEventRef cg = CGEventCreateCopy(e.CGEvent);
    CGEventSetIntegerValueField(cg, kCGMouseEventSubtype, subtype);
    [NSApp postEvent:[NSEvent eventWithCGEvent:cg] atStart:NO];
    CFRelease(cg);
    pump(0.25);  // > the plug-in's 150 ms verification
}
static void click() { mouse(kProxyClick); }
static void key(NSString *c) {
    [NSApp postEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                  windowNumber:0 context:nil characters:c charactersIgnoringModifiers:c isARepeat:NO keyCode:0]
             atStart:NO];
    pump(0.25);
}
static void swapKey() {
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                       timestamp:0 windowNumber:0 context:nil subtype:kSwapKey data1:0 data2:0]
             atStart:NO];
    pump(0.1);
}
static void windowColorCommand() {  // Window > Color or its shortcut: toggles, no Fill/Stroke notifier
    notify(kAIAdobeColorPaletteCommandPreNotifierStr);
    if (colorVisible()) hideColor(); else showColor();
    notify(kAIAdobeColorPaletteCommandPostNotifierStr);
    pump(0.05);
}

static NSString *gDomain;
static void pump(double seconds);
static void setPref(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, (__bridge CFStringRef)gDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)gDomain);
    // One unreproduced flake (2026-11-09) looked like a settings write not yet visible
    // to the plug-in's re-read; give the preferences daemon a moment.
    pump(0.05);
    notify(kAIAllPluginStartedNotifier);  // forces the plug-in to re-read settings
}

// Describe a mock window the way Adobe's panels describe themselves to VoiceOver.
static void addAX(NSWindow *w, NSAccessibilityRole role, NSString *title) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    v.accessibilityElement = YES;
    v.accessibilityRole = role;
    v.accessibilityTitle = title;
    [w.contentView addSubview:v];
}

static NSWindow *offscreen(Class cls, NSWindowLevel level) {
    NSWindow *w = [[cls alloc] initWithContentRect:NSMakeRect(-30000, -30000, 260, 173)
                                         styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    w.level = level;
    w.alphaValue = kAlpha;
    w.ignoresMouseEvents = YES;
    w.releasedWhenClosed = NO;
    return w;
}

#define EXPECT(cond, name)                                                       \
    do { if (cond) { ++gPasses; printf("  ok   %s\n", name); }                     \
         else { ++gFailures; printf("  FAIL %s (visible=%d toggles=%d commit=%ld)\n", name, \
                                    colorVisible(), gToggles, (long)gVisibleAtCommit); } } while (0)

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: mockhost ColorWindowNuke.aip\n"); return 2; }
        // Settings and logs live in a private temp folder; CFPreferences accepts an
        // absolute path as the application ID, so nothing is written to ~/Library.
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                    [NSString stringWithFormat:@"cwn-test.%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
        gDomain = [tmp stringByAppendingPathComponent:@"settings"];
        setenv("CWN_DEFAULTS_DOMAIN", gDomain.UTF8String, 1);
        NSString *logDir = [tmp stringByAppendingPathComponent:@"logs"];
        setenv("CWN_LOG_DIR", logDir.fileSystemRepresentation, 1);

        sMenu.GetMenuItemKeyboardShortcutDictionaryKey = fKey;
        sMenu.CountMenuItems = fCount;
        sMenu.GetNthMenuItem = fNth;
        sMenu.IsItemChecked = fChecked;
        sPaint.SetStrokeActive = fSetStroke;
        sPaint.SetFillActive = fSetFill;
        sPaint.ToggleColorDialog = fToggle;

        [HostApp sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];  // never takes focus
        gColor = offscreen(MockOwlPanelWindow.class, NSFloatingWindowLevel);
        gPopup = offscreen(MockDVAMacDialog.class, 8);
        gGradient = offscreen(MockOwlPanelWindow.class, NSFloatingWindowLevel);
        gDrawer = offscreen(MockOwlDrawerWindow.class, NSFloatingWindowLevel);
        addAX(gColor, NSAccessibilityTabGroupRole, @"Color");        // floating Color panel (guided test 4)
        addAX(gColor, NSAccessibilityButtonRole, @"Close");
        addAX(gGradient, NSAccessibilityTabGroupRole, @"Gradient");  // floating Gradient panel
        addAX(gGradient, NSAccessibilityButtonRole, @"Close");
        addAX(gDrawer, NSAccessibilityTabGroupRole, @"Color");       // icon-dock drawer: no Close button
        addAX(gDrawer, NSAccessibilityButtonRole, @"Expand Panels");

        CFRunLoopObserverRef obs = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting, true, INT_MAX,
            ^(CFRunLoopObserverRef, CFRunLoopActivity) { if (gVisibleAtCommit < 0) gVisibleAtCommit = colorVisible(); });
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);

        // Logging is off in release builds; switch it on so the test can be inspected
        // (except in the quiet run, which checks that nothing is written by default).
        bool quietRun = getenv("CWN_MOCK_QUIET") != nullptr;
        if (!quietRun) CFPreferencesSetAppValue(CFSTR("logging"), kCFBooleanTrue, (__bridge CFStringRef)gDomain);
        bool debugRun = getenv("CWN_MOCK_DEBUG") != nullptr;
        if (debugRun) {  // recorder must be enabled before Startup (extra notifiers register there)
            CFPreferencesSetAppValue(CFSTR("debugLog"), kCFBooleanTrue, (__bridge CFStringRef)gDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)gDomain);
            printf("(debug recorder ON)\n");
        }
        NSString *exe = [@(argv[1]) stringByAppendingPathComponent:@"Contents/MacOS/ColorWindowNuke"];
        void *h = dlopen(exe.fileSystemRepresentation, RTLD_NOW);
        if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
        gMain = (PluginMainFn)dlsym(h, "PluginMain");
        SPMessageData d = {'SPCk', (SPPluginRef)0x5E1F, nullptr, &sBasic};
        if (!gMain || gMain((char *)kSPInterfaceCaller, (char *)kSPInterfaceStartupSelector, &d) != kNoErr) return 2;

        // sanity: off-screen windows still count as visible to AppKit
        showColor();
        bool canSee = colorVisible();
        hideColor();
        if (!canSee) { fprintf(stderr, "mock windows never become visible; cannot run\n"); return 2; }

        setPref(@"allowUnverifiedBuild", @YES);  // mock host is not a verified Illustrator build
        printf("release default (no settings)\n");
        gToggles = 0; click();
        EXPECT(!colorVisible() && gToggles == 1, "the fix is on by default");

        printf("diagnose mode\n");
        setPref(@"mode", @"diagnose");
        gToggles = 0; click();
        EXPECT(colorVisible() && gToggles == 0, "diagnose: native behaviour, nothing changed");
        hideColor();

        printf("enforce mode\n");
        setPref(@"mode", @"enforce");
        gToggles = 0; click();
        EXPECT(!colorVisible() && gToggles == 1, "closed panel auto-opened by a proxy click is closed once");
        EXPECT(gVisibleAtCommit == 0, "closed before the first display commit point (BeforeWaiting)");
        EXPECT(gAlphaAtNotify == 0, "window made transparent the moment the click is detected");
        EXPECT(gColor.alphaValue == kAlpha, "window transparency restored after closing");
        for (int i = 0; i < 5; ++i) click();
        EXPECT(!colorVisible() && gToggles == 6, "repeated Fill/Stroke switching stays closed, one toggle per click");

        printf("explicit opening is respected\n");
        gToggles = 0;
        windowColorCommand();
        EXPECT(colorVisible() && gToggles == 0, "Window > Color opens the panel");
        for (int i = 0; i < 3; ++i) click();
        EXPECT(colorVisible() && gToggles == 0, "user-opened panel stays open and is never toggled");
        EXPECT(gColor.alphaValue == kAlpha, "user-opened panel is never made transparent");
        windowColorCommand();
        EXPECT(!colorVisible(), "Window > Color closes the panel");
        click();
        EXPECT(!colorVisible() && gToggles == 1, "after closing it, a proxy click no longer opens it");

        printf("other windows and inputs\n");
        gToggles = 0; mouse(kPopupClick);
        EXPECT(!colorVisible() && gToggles == 0, "swatch pop-up window during a Fill/Stroke change is ignored");
        [gPopup orderOut:nil];
        swapKey();
        EXPECT(!colorVisible() && gToggles == 0, "X swap: nothing to undo");

        printf("other ways Color opens (drawer hiding switched off here)\n");
        setPref(@"experimentalDrawer", @NO);
        gToggles = 0; key(@"<");
        EXPECT(!colorVisible() && gToggles == 1 && gColor.alphaValue == kAlpha, "\"<\" key: Color closed instantly, look restored");
        gToggles = 0; key(@"c");
        EXPECT(!colorVisible() && gToggles == 1, "Color appearing with no Illustrator event is still caught (end of turn)");
        gToggles = 0; key(@">");
        EXPECT(gGradient.isVisible && gToggles == 0, "\">\" key: Gradient panel is never touched");
        [gGradient orderOut:nil];
        gToggles = 0; key(@"d");
        EXPECT(gDrawer.isVisible && gToggles == 0, "Color popping out of an icon dock is left alone (would remove the icon)");
        [gDrawer orderOut:nil];
        gToggles = 0; mouse(kProxyDrawerClick);
        EXPECT(gDrawer.isVisible && gToggles == 0, "Fill/Stroke click that pops out a drawer is left alone");
        EXPECT(gDrawer.alphaValue == kAlpha, "drawer is fully visible again (briefly hidden while identified)");
        [gDrawer orderOut:nil];
        gToggles = 0; mouse(kWorkspaceClick);
        EXPECT(colorVisible() && gToggles == 0, "workspace switch that shows Color is respected");
        hideColor();
        gToggles = 0; mouse(kMenuClick);
        EXPECT(colorVisible() && gToggles == 0, "menu action that shows Color is respected");
        hideColor();

        printf("icon-dock drawer hiding (on by default)\n");
        setPref(@"experimentalDrawer", nil);
        gToggles = 0; mouse(kProxyDrawerClick);
        EXPECT(!gDrawer.isVisible && gToggles == 0 && gDrawer.alphaValue == kAlpha,
               "Fill/Stroke drawer is put away, Color panel state untouched, look restored");
        gToggles = 0; key(@"d");
        EXPECT(!gDrawer.isVisible && gToggles == 0, "\"<\"-style drawer (art properties changed) is put away");
        mouse(kIconClick);
        EXPECT(gDrawer.isVisible && gDrawer.alphaValue == kAlpha, "drawer you open by clicking the Color icon is left alone");
        [gDrawer orderOut:nil];
        mouse(kProxyDrawerClick);
        mouse(kIconClick);  // reopened by you right after we put one away: not mistaken for Illustrator fighting back
        pump(1.6);
        EXPECT(gDrawer.isVisible, "your reopening within 1.5 s is respected");
        [gDrawer orderOut:nil];
        mouse(kProxyDrawerClick);
        EXPECT(!gDrawer.isVisible, "drawer handling still active after your reopening");
        gStickyDrawer = true;
        mouse(kProxyDrawerClick);
        pump(1.6);
        gStickyDrawer = false;
        EXPECT(gDrawer.isVisible && gDrawer.alphaValue == kAlpha, "if Illustrator shows the drawer again, it stays visible");
        [gDrawer orderOut:nil];
        mouse(kProxyDrawerClick);
        EXPECT(gDrawer.isVisible, "drawer handling stops for the session after that (no fighting)");
        [gDrawer orderOut:nil];
        gToggles = 0; click();
        EXPECT(!colorVisible() && gToggles == 1, "floating fix keeps working after the drawer stop");
        setPref(@"experimentalDrawer", @NO);
        gToggles = 0;

        printf("pause / off\n");
        setPref(@"paused", @YES);
        click();
        EXPECT(colorVisible() && gToggles == 0, "paused: native behaviour");
        hideColor();
        setPref(@"paused", @NO);
        setPref(@"mode", @"off");
        click();
        EXPECT(colorVisible() && gToggles == 0, "off: native behaviour");
        hideColor();
        setPref(@"mode", @"enforce");

        printf("safety stop\n");
        gToggleBroken = true; gToggles = 0; click();
        EXPECT(gToggles == 1, "one attempt when the reversal has no effect");
        EXPECT(colorVisible() && gColor.alphaValue == kAlpha, "failed reversal leaves a visible, opaque panel (never invisible)");
        hideColor();
        gToggleBroken = false; gToggles = 0; click();
        EXPECT(colorVisible() && gToggles == 0, "after an ineffective reversal the fix stops for the session");

        gMain((char *)kSPInterfaceCaller, (char *)kSPInterfaceShutdownSelector, &d);
        if (debugRun) {
            NSString *log = nil;
            for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:logDir error:nil])
                log = [NSString stringWithContentsOfFile:[logDir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
            EXPECT([log containsString:@"\"panelChange\""] && [log containsString:@"\"change\":\"shown\""],
                   "debug recorder logs the panel window appearing");
        }
        if (quietRun)
            EXPECT([[NSFileManager defaultManager] contentsOfDirectoryAtPath:logDir error:nil].count == 0,
                   "release default writes no log files");
        printf("%d passed, %d failed\n", gPasses, gFailures);
        if (!getenv("CWN_KEEP_TEST_FILES")) [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return gFailures ? 1 : 0;
    }
}
