// SohIosShell — grafts the iOS app shell onto SDL's UIWindow.
// v1: ensure landscape (insurance — the app is already landscape via the plist
// + SDL orientation hint; this nudges the scene if it ever starts portrait).
// The on-screen touch-control overlay is added in a later revision. Compiled
// into the soh target (ARC on). LUS calls SohIos_OnWindowCreated after
// SDL_CreateWindow.
//
// NOTE: on the iOS Simulator the device *bezel window* may display the app
// rotated (a cosmetic simulator quirk); `xcrun simctl io <udid> screenshot`
// captures the true landscape framebuffer and is the verification source.
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import "SohIosShell.h"
#include <objc/runtime.h> // iOS 27 scene-config hook grafted onto SDL's app delegate

#include <arpa/inet.h>
#include <execinfo.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma mark - Instrumentation helpers

// Thermal state for the perf probe (overlay 0008): 0 nominal, 1 fair,
// 2 serious, 3 critical (NSProcessInfoThermalState).
int SohIos_ThermalState(void) {
    return (int)NSProcessInfo.processInfo.thermalState;
}

// D24 (overlay 0041's SOH_PACE line; = Shipwright D-084): power state beside
// thermal, because Low Power Mode caps the panel at 60 Hz and charging heats
// the phone before thermalState moves. Bits: 1 = Low Power Mode, 2 =
// charging, 4 = full (plugged in), 8 = battery state unknown. Game thread.
int SohIos_PowerState(void) {
    int bits = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0;
#if !TARGET_OS_VISION
    UIDevice* dev = UIDevice.currentDevice;
    if (!dev.batteryMonitoringEnabled) {
        dev.batteryMonitoringEnabled = YES;
    }
    switch (dev.batteryState) {
        case UIDeviceBatteryStateCharging: bits |= 2; break;
        case UIDeviceBatteryStateFull: bits |= 4; break;
        case UIDeviceBatteryStateUnknown: bits |= 8; break;
        default: break;
    }
#endif
    return bits;
}

// SOH_IOS (overlay 0024, SYNC WAVE 2): true GPU frame time (ms), written by
// gfx_metal's screen-CB completed handler and read by the perf probe (0017
// rev3) + the `drawable` bridge command. volatile is enough — one GPU-thread
// writer, readers tolerate a frame of staleness. C linkage (extern'd from
// gfx_metal.cpp at file scope).
volatile float gSohIosGpuMs = 0;

// --- visionOS 3D bridge globals (defined HERE so the __IOS__ stereo overlay
// resolves them on iOS too, where they stay inert; the visionOS-only UIKit
// machinery lives in SohVision3D.m). gSoh3DMode stays 0 on iPhone. -----------
volatile int gSoh3DMode = 0;                       // 1 while the immersive space is open
void* volatile gSoh3DEyeTexture[2] = { NULL, NULL }; // published MTLTexture per eye
volatile int gSoh3DEyeFrames[2] = { 0, 0 };        // per-eye rendered-frame counters
volatile int gSoh3DMenuToggleReq = 0;              // ornament Menu -> engine consumes in 3D
volatile int gSohAudioAnchorStatus = 0;            // 1 ok / 2 threw (Swift audio anchor)
volatile int gSoh3DDbg2DW = 0, gSoh3DDbg2DH = 0;   // engine 2D dims (restore verify)
volatile float gSoh3DCamDist = 0;                  // camera-to-focus (stereo convergence)
volatile float gSoh3DCamP00 = 1.0f;                // projection [0][0] (focal term)
volatile float gSoh3DCamRight[3] = { 1, 0, 0 };    // camera basis (0035 exports these)
volatile float gSoh3DCamFwd[3] = { 0, 0, -1 };
volatile float gSoh3DCamEye[3] = { 0, 0, 0 };
// Stereo engine (overlay 0034) state + telemetry, defined here so the __IOS__
// engine code links on iPhone too (all inert while gSoh3DMode == 0).
volatile int gSoh3DEyeW = 0, gSoh3DEyeH = 0;       // eye render size (0 -> engine default 3840x2160)
volatile int gSoh3DPaused = 0, gSoh3DInPlay = 0;   // comfort flags (0035 exports)
volatile int gSoh3DAiming = 0;                     // first-person aim (unused on SF64 v1)
volatile int gSoh3DCinematic = 0;                  // cutscene/transition (0035 exports; round 2)
volatile int gSoh3DDbgObjSep = 0;                  // Arwing sentinel hit counter (round-2 verify)
volatile int gSoh3DDbgObjFold = 0;                 // folds run with reduced ship mul (round-3, now inert)
volatile int gSoh3DDbgGameState = -1;              // SF64 gGameState (round-4: verify map/menu go flat)
volatile int gSoh3DDbgInterpGuard = 0;             // FrameInterpolation root-pop guard hits (0039 crash fix)
volatile float gSoh3DDbgConv = 0, gSoh3DDbgSep = 0; // adaptive convergence readout (bridge 3d)
volatile int gSoh3DDbgCurW = 0, gSoh3DDbgCurH = 0;  // interpreter mCurDimensions (bridge)
volatile int gSoh3DDbgMenuVis = 0, gSoh3DDbgMenuBuilds = 0, gSoh3DDbgMenuVtx = 0, gSoh3DDbgMenuDraws = 0;

// The 3D perf-HUD text is visionOS-only (defined in SohVision3D.m, compiled
// only under SOH_VISIONOS). But LUS Gui.cpp (overlay 0037 Soh3DBuildMenuFrame)
// references SohIos_PerfHud3DText under __IOS__, which is defined on the iPhone
// target too — so the iOS link needs the symbol even though the 3D menu path
// is dead there (gSoh3DMode is always 0). Provide an iPhone-only stub;
// TARGET_OS_VISION excludes it so there's no duplicate with the real one.
#if !TARGET_OS_VISION
int SohIos_PerfHud3DText(char* buf, int cap) {
    (void)cap;
    if (buf != NULL) {
        buf[0] = 0;
    }
    return -1; // HUD off — no 3D mode on iPhone
}
#endif

void SohIos_SetAudioAnchorStatus(int s) {
    gSohAudioAnchorStatus = s;
}

// Menu visibility, exported by overlay 0013 (OTRGlobals.cpp) — drives the
// touch overlay's auto-hide.
extern int SohIos_IsMenuOpen(void);

// Backgrounded flag, read by the Metal backend (overlay 0016) to stop
// rendering while suspended: nextDrawable in the background is the classic
// cause of post-resume slowdowns and watchdog kills. volatile is enough —
// one writer (main thread), reader tolerates staleness of a frame.
static volatile int gSohIosBackgrounded = 0;
void SohIos_SetBackgrounded(int backgrounded) {
    if (gSohIosBackgrounded != backgrounded) {
        NSLog(@"[SohIosShell] backgrounded=%d", backgrounded);
    }
    gSohIosBackgrounded = backgrounded;
}
int SohIos_IsBackgrounded(void) {
    return gSohIosBackgrounded;
}

// Park tick for overlay 0016. On iOS the game loop RUNS ON THE MAIN
// THREAD (SDL_main), so a sleeping park loop would block the run loop and
// deadlock: the very notifications/timers that clear the backgrounded
// flag are delivered by that run loop (root cause of the black-screen-
// with-audio resume, reproduced on sim 2026-07-12). Instead, service the
// run loop while parked — lifecycle events keep flowing and the flag
// clears the moment the scene foregrounds.
void SohIos_ParkTick(void) {
    if (NSThread.isMainThread) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    } else {
        struct timespec nap = { 0, 50 * 1000 * 1000 };
        nanosleep(&nap, NULL);
    }
}

// Device feedback 2026-07-12: resume sometimes came back to a black screen
// with audio and dead input — the signature of the 0016 park never
// releasing because the scene delegate's foreground callbacks didn't fire.
// Three independent clears now: scene-delegate methods, scene
// notifications (always post), and a 1 s main-thread reconciler — timers
// are frozen while suspended and resume with the run loop, so even if
// every callback path fails, the flag clears within a second of the app
// actually being active again.
static void SohIos_InstallBackgroundReconciler(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneDidEnterBackground");
                                                    SohIos_SetBackgrounded(1);
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillEnterForegroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneWillEnterForeground");
                                                    SohIos_SetBackgrounded(0);
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneDidActivate");
                                                    SohIos_SetBackgrounded(0);
                                                }];
    NSTimer* reconciler = [NSTimer timerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer* t) {
                                                       static int ticks = 0;
                                                       if (gSohIosBackgrounded && (++ticks % 5 == 0)) {
                                                           NSLog(@"[SohIosShell] reconciler: flag=1 appState=%ld",
                                                                 (long)UIApplication.sharedApplication.applicationState);
                                                       }
                                                       if (gSohIosBackgrounded &&
                                                           UIApplication.sharedApplication.applicationState !=
                                                               UIApplicationStateBackground) {
                                                           NSLog(@"[SohIosShell] background flag reconciled (missed foreground callback)");
                                                           SohIos_SetBackgrounded(0);
                                                       }
                                                   }];
    // NSRunLoopCommonModes: SDL's run-loop servicing can starve the default
    // mode; common modes ride every turn (suspected reason the first
    // reconciler never fired).
    [NSRunLoop.mainRunLoop addTimer:reconciler forMode:NSRunLoopCommonModes];
    NSLog(@"[SohIosShell] background reconciler installed");
}

// LUS console-variable flush (extern "C", API_EXPORT). iOS swipe-kill is
// SIGKILL — desktop SoH's write-on-quit never runs, so CVar/enhancement/bind
// changes made in the menu would be lost. Flush on resign-active (fires
// before background and before any kill). In-game .sav files are already
// written synchronously by SaveManager at save time; this covers config.
extern void CVarSave(void);
extern int32_t CVarGetInteger(const char* name, int32_t defaultValue);
extern void CVarSetInteger(const char* name, int32_t value);
extern float CVarGetFloat(const char* name, float defaultValue);
extern void CVarSetFloat(const char* name, float value);
extern void CVarClearBlock(const char* name);

// Game pause state, exported by overlay 0013 — drives the ≡ button policy
// when a physical controller is active.
extern int SohIos_IsGamePaused(void);

// Title/intro/file-select context (overlay 0013) — the ≡ button stays
// visible there so users can tune settings at the start.
extern int SohIos_IsTitleOrDemo(void);

// Menu touch-scroll queue (overlay 0013/0018): mouse-free scrolling.
extern void SohIos_QueueMenuScroll(float x, float dy);

// Rolling 1s fps from the perf probe (overlay 0008 rev4) for the HUD.
extern void SohIos_HudStats(float* fps);

// Active BGM/fanfare sequence ids (overlay 0013) — wrong-music diagnostics.
extern uint32_t SohIos_ActiveSeqIds(void);

// Any ImGui popup open (overlay 0013): overlay yields all input to it.
extern int SohIos_IsPopupOpen(void);

// First-run fidelity defaults for this device (user feedback 2026-07-10):
// pace to the display's refresh (120 on ProMotion) and render at 200%
// internal resolution. Versioned so later builds can seed more without
// clobbering user changes; only ever runs when the marker is absent.
static void SohIos_SeedDefaultsOnce(void) {
    int version = CVarGetInteger("gSohIos.DefaultsVersion", 0);
    if (version >= 2) {
        return;
    }
    if (version < 1) {
        CVarSetInteger("gMatchRefreshRate", 1); // Starship name (SoH: gSettings.MatchRefreshRate)
    }
    // Starship never seeds gInternalResolution (boot-inert here; see
    // SHELL-DIVERGENCES #4) — v2 exists only to keep the version marker in
    // step with the Ship of Harkinian port shell.
    CVarSetInteger("gSohIos.DefaultsVersion", 2);
    CVarSave();
    NSLog(@"[SohIosShell] defaults seeded v2 (MatchRefreshRate=1)");
}

// SOH_IOS (SYNC WAVE 2 trap 4): clamp the index-keyed combobox CVars into
// range every boot. Starship's CVarCombobox is index-keyed (value == array
// index), so unlike the Ship of Harkinian port value-keyed MaxFps {60,90,120} map (which
// aborted on comboMap.at() with a stale index), an out-of-range value here
// only risks an OOB span read in one label-position path. Nothing writes an
// out-of-range value today; this is belt-and-braces against a future keying
// change, and the generalized form of the Ship of Harkinian port boot migration.
static void SohIos_MigrateComboCVars(void) {
    struct { const char* cvar; int lo; int hi; int dflt; } knobs[] = {
        { "gSohIos.MaxFps", 0, 1, 1 },      // {60 fps, 120 fps}
        { "gSohIos.Haptics", 0, 2, 1 },     // {Off, Light, Strong}
        { "gSohIos.StickCurve", 0, 1, 0 },  // {Linear, Precise}
    };
    for (size_t i = 0; i < sizeof(knobs) / sizeof(knobs[0]); i++) {
        int v = CVarGetInteger(knobs[i].cvar, knobs[i].dflt);
        if (v < knobs[i].lo || v > knobs[i].hi) {
            NSLog(@"[SohIosShell] migrating %s: %d out of [%d,%d] -> %d", knobs[i].cvar, v, knobs[i].lo,
                  knobs[i].hi, knobs[i].dflt);
            CVarSetInteger(knobs[i].cvar, knobs[i].dflt);
        }
    }
}

void SohIos_FlushConfig(const char* why) {
    CVarSave(); // ~13 KB JSON; cheap, safe to repeat
    NSLog(@"[SohIosShell] config flushed (%s)", why ? why : "?");
}

static void SohIos_InstallConfigPersist(void) {
    static BOOL installed = NO;
    if (installed) {
        return;
    }
    installed = YES;
    // Under a scene session UIKit posts UISceneWillDeactivate, NOT the app-
    // level UIApplicationWillResignActive (same scene-vs-app-delegate split
    // that broke URL delivery). Observe both notification names so the flush
    // fires whichever lifecycle the runtime uses; the scene delegate below
    // also calls SohIos_FlushConfig directly as a third path.
    void (^flush)(NSNotification*) = ^(NSNotification* note) { SohIos_FlushConfig("notif"); };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
}

// Crash backtraces persisted to Documents/crash.txt — springboard sessions
// are otherwise invisible (predecessor pattern).
static void SohIos_CrashHandler(int sig) {
    void* frames[64];
    int n = backtrace(frames, 64);
    char path[1024];
    const char* home = getenv("HOME");
    snprintf(path, sizeof(path), "%s/Documents/crash.txt", home ? home : "/tmp");
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        dprintf(fd, "signal %d\n", sig);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void SohIos_InstallCrashHandler(void) {
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        signal(sigs[i], SohIos_CrashHandler);
    }
}

#pragma mark - Input trace (Documents/input-trace.txt)

// A user on iPadOS 26.5 reported that a controller's B button opened and
// closed the SoH menu on every press, on top of acting as the in-game B —
// and that unbinding EVERY controller button in SoH did not stop it. It
// could not: the toggle arrives as a keyboard Escape, not as a controller
// button, so it never passes through SoH's binding system at all. iPadOS
// forges UIKit "cancel" input from a game controller and SDL's UIKit
// backend converted it into SDL_SCANCODE_ESCAPE.
//
// Remote users have no console bridge, so the evidence has to travel by
// itself: Documents/input-trace.txt is reachable from the Files app
// (UIFileSharingEnabled) and can simply be sent back.
//
// It is written LAZILY. On a healthy device nothing is ever forged, so
// creating the file at every launch would put a mystery file in every
// user's Files folder for nothing. Instead lines accumulate in a small
// in-memory ring, and the file only materializes the first time a forged
// key is actually dropped — at which point the buffered environment
// (device, iOS version, keyboard, pads) is flushed ahead of it, so the
// evidence arrives with its context. The file existing at all is itself
// the signal that something is still forging input.
#define SOHIOS_TRACE_MAX_LINES 300
#define SOHIOS_TRACE_RING 60
static void SohIos_Trace(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SohIos_TraceArm(void); // first drop: start writing, flush the ring
static volatile int32_t sSohIosTraceLines; // read unlocked: a race just costs a line
static volatile int32_t sSohIosTraceArmed;

static dispatch_queue_t SohIos_TraceQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("soh.ios.trace", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Queue-confined state — only ever touched inside SohIos_TraceQueue().
static NSMutableArray<NSString*>* sSohIosTraceRing;
static int sSohIosTraceWritten;

static void SohIos_TraceWriteLocked(NSString* line) {
    static NSString* path;
    if (path == nil) {
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"input-trace.txt"];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void SohIos_Trace(NSString* fmt, ...) {
    // Hard stop once full — a forged key can arrive on EVERY button press, so
    // this must cost nothing at all after the cap, not just skip the write.
    if (sSohIosTraceLines >= SOHIOS_TRACE_MAX_LINES) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SohIosInput] %@", msg);
    double t = CACurrentMediaTime();
    dispatch_async(SohIos_TraceQueue(), ^{
        NSString* line = [NSString stringWithFormat:@"%8.2f  %@\n", t, msg];
        if (!sSohIosTraceArmed) {
            if (sSohIosTraceRing == nil) {
                sSohIosTraceRing = [NSMutableArray array];
            }
            [sSohIosTraceRing addObject:line];
            if (sSohIosTraceRing.count > SOHIOS_TRACE_RING) {
                [sSohIosTraceRing removeObjectAtIndex:0];
            }
            return;
        }
        if (sSohIosTraceWritten >= SOHIOS_TRACE_MAX_LINES) {
            return;
        }
        sSohIosTraceLines = ++sSohIosTraceWritten;
        SohIos_TraceWriteLocked(sSohIosTraceWritten == SOHIOS_TRACE_MAX_LINES
                                    ? [line stringByAppendingString:@"[trace full]\n"]
                                    : line);
    });
}

// Called the first time a forged key is dropped. Everything buffered so far
// becomes the header of the file, then tracing goes live.
static void SohIos_TraceArm(void) {
    if (sSohIosTraceArmed) {
        return;
    }
    dispatch_async(SohIos_TraceQueue(), ^{
        if (sSohIosTraceArmed) {
            return;
        }
        sSohIosTraceArmed = 1;
        SohIos_TraceWriteLocked(@"# input-trace: forged input was detected on this device.\n"
                                @"# Lines above the marker are the buffered lead-up.\n");
        for (NSString* buffered in sSohIosTraceRing) {
            SohIos_TraceWriteLocked(buffered);
            sSohIosTraceWritten++;
        }
        sSohIosTraceRing = nil;
        SohIos_TraceWriteLocked(@"# --- live from here ---\n");
        sSohIosTraceLines = sSohIosTraceWritten;
    });
}

// Stamped into SDL_Keysym's otherwise-unused field so the event filter can
// tell the shell's own menu keystrokes (≡ button, restore dot, soh://menu,
// the bridge) apart from anything the system forged.
#define SOHIOS_KEY_MAGIC 0x5348494Fu // 'SHIO'

#pragma mark - Virtual game controller (input backend)

// An SDL virtual game controller: LUS's SDL controller stack sees it as a
// normal pad (auto-mapped by SDL), so the touch overlay drives the game
// through the same path a physical controller would.
static SDL_Joystick* gVirtualPad = NULL;
static SDL_Window* gSdlWindow = NULL;

// SOH_IOS (overlay 0026, SYNC WAVE 2 addendum D): supersampling hooks read by
// the Fast3D interpreter's StartFrame. Without this the game rendered
// SUB-NATIVE (mCurDimensions came from ImGui POINTS, then ImGui::Image
// upscaled to the native-pixel drawable). SsaaFactor scales the offscreen
// render target to (native px * factor); 1.0 = exactly native, up to 2.0 =
// true supersampling. DrawablePixelWidth is the native drawable width.
float SohIos_SsaaFactor(void) {
#if TARGET_OS_VISION
    // §1.4a: the 3840 drawable already renders ~2x the panel's angular
    // resolution, so SSAA above native is pure GPU spend with no visible gain
    // (and 2.0 would push a 7680 render, clamped). Ship exactly native.
    return 1.0f;
#endif
    float f = CVarGetFloat("gSohIos.Supersample", 2.0f); // D12/user: 2.0 is the default (SF64 is light)
    if (f < 1.0f) {
        f = 1.0f;
    }
    if (f > 2.0f) {
        f = 2.0f;
    }
    return f;
}
// SOH_IOS (D12a): what the PANEL can actually do, straight from UIKit. The
// engine's own GetCurrentRefreshRate() goes through SDL's cached display
// mode, which can disagree with the hardware (and is the remaining suspect
// for "Starship maxes at 60 while the siblings hit 120"). Overlay 0020 rev3
// paces off this instead, so the iOS frame-rate knob depends on nothing but
// the screen. Returns 0 if UIKit gives something implausible.
uint32_t SohIos_PanelMaxFps(void) {
#if TARGET_OS_VISION
    return 0; // no UIScreen on visionOS; the compositor paces, caller falls back
#else
    NSInteger hz = UIScreen.mainScreen.maximumFramesPerSecond;
    if (hz < 30 || hz > 240) {
        return 0; // implausible: let the caller fall back
    }
    return (uint32_t)hz;
#endif
}

uint32_t SohIos_DrawablePixelWidth(void) {
    if (gSdlWindow == NULL) {
        return 0;
    }
    int w = 0, h = 0;
    SDL_Metal_GetDrawableSize(gSdlWindow, &w, &h);
    return w > 0 ? (uint32_t)w : 0;
}

// Inject a left-click at window point (x, y) via SDL's thread-safe event
// queue — ImGui consumes SDL mouse events, so this can activate ImGui
// buttons (e.g. the extractor's "Yes") on the simulator where real taps
// are unavailable.
static void SohIos_InjectMouseMotion(int x, int y) {
    if (gSdlWindow == NULL) {
        return;
    }
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEMOTION;
    e.motion.windowID = SDL_GetWindowID(gSdlWindow);
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
}

static void SohIos_InjectMouseButton(int x, int y, BOOL down) {
    if (gSdlWindow == NULL) {
        return;
    }
    SDL_Event e;
    SDL_zero(e);
    e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    e.button.windowID = SDL_GetWindowID(gSdlWindow);
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
}

static void SohIos_InjectClick(int x, int y) {
    if (gSdlWindow == NULL) {
        return;
    }
    Uint32 windowID = SDL_GetWindowID(gSdlWindow);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEMOTION;
    e.motion.windowID = windowID;
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
    SDL_zero(e);
    e.type = SDL_MOUSEBUTTONDOWN;
    e.button.windowID = windowID;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = SDL_PRESSED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    SDL_zero(e);
    e.type = SDL_MOUSEBUTTONUP;
    e.button.windowID = windowID;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = SDL_RELEASED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    NSLog(@"[SohIosShell] injected click at (%d,%d)", x, y);
}

static void SohIos_PadAxis(SDL_GameControllerAxis axis, Sint16 value);

static void SohIos_AttachVirtualPad(void) {
    if (gVirtualPad != NULL) {
        return;
    }
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) != 0) {
        NSLog(@"[SohIosShell] SDL_InitSubSystem(GAMECONTROLLER) failed: %s", SDL_GetError());
        return;
    }
    SDL_VirtualJoystickDesc desc;
    SDL_zero(desc);
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = SDL_CONTROLLER_AXIS_MAX;
    desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    desc.name = "SoH Touch Controls";
    int deviceIndex = SDL_JoystickAttachVirtualEx(&desc);
    if (deviceIndex < 0) {
        NSLog(@"[SohIosShell] AttachVirtualEx failed: %s", SDL_GetError());
        return;
    }
    gVirtualPad = SDL_JoystickOpen(deviceIndex);
    // Triggers idle at raw 0 = half-pressed in trigger space (see
    // SohIos_PadAxis below) — drive them to truly-released immediately.
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT, 0);
    NSLog(@"[SohIosShell] virtual pad attached (index %d, isGameController=%d)", deviceIndex,
          SDL_IsGameController(deviceIndex));
}

// Inject a key press+release via SDL's thread-safe event queue.
// Mouse-wheel injection: vertical pans over the open menu scroll it (device
// feedback: swipe-to-scroll; sliders stay horizontal drags).
static void SohIos_InjectWheel(float dy) {
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEWHEEL;
    e.wheel.y = (Sint32)dy;
    e.wheel.preciseY = dy;
    e.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
    SDL_PushEvent(&e);
}

static void SohIos_InjectKey(SDL_Keycode sym, SDL_Scancode scancode) {
    if (gSdlWindow == NULL) {
        return;
    }
    Uint32 windowID = SDL_GetWindowID(gSdlWindow);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_KEYDOWN;
    e.key.windowID = windowID;
    e.key.state = SDL_PRESSED;
    e.key.keysym.sym = sym;
    e.key.keysym.scancode = scancode;
    e.key.keysym.unused = SOHIOS_KEY_MAGIC; // survives the Escape guard below
    SDL_PushEvent(&e);
    e.type = SDL_KEYUP;
    e.key.state = SDL_RELEASED;
    SDL_PushEvent(&e);
    NSLog(@"[SohIosShell] injected key %d", (int)sym);
}

// 3D menu toggle (Swift ornament / bridge): a DIRECT request the engine
// consumes in 3D (esc-key injection dies on device in 3D — the immersive space
// steals SDL's input focus, §2.7). In 2D it injects the normal menu key (ESC —
// Starship's toggle post-0029, matching the modern menu).
void SohIos_ToggleMenuKey(void) {
    if (gSoh3DMode != 0) {
        gSoh3DMenuToggleReq = 1;
    } else {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
    }
}

// Identity mapping: virtual joystick axis/button N == SDL_CONTROLLER_*_N.
static void SohIos_PadAxis(SDL_GameControllerAxis axis, Sint16 value) {
    if (gVirtualPad == NULL) {
        return;
    }
    // THE Z ROOT CAUSE (device feedback 2026-07-12, found via the `pads`
    // dump): SDL translates full-range raw axes to trigger space as
    // (raw+32768)/2, so raw 0 reads as HALF-PRESSED (16383) — above LUS's
    // press threshold. The virtual pad was therefore holding Z forever:
    // touch-Z "stuck" after one tap, and gamepad Z looked dead because the
    // bit was already set so real presses produced no new edge. Triggers
    // take raw -32768 for released, +32767 for pressed.
    if (axis == SDL_CONTROLLER_AXIS_TRIGGERLEFT || axis == SDL_CONTROLLER_AXIS_TRIGGERRIGHT) {
        value = (value <= 0) ? SDL_JOYSTICK_AXIS_MIN : SDL_JOYSTICK_AXIS_MAX;
    }
    SDL_JoystickSetVirtualAxis(gVirtualPad, axis, value);
}

static void SohIos_PadButton(SDL_GameControllerButton button, BOOL down) {
    if (gVirtualPad) {
        SDL_JoystickSetVirtualButton(gVirtualPad, button, down ? SDL_PRESSED : SDL_RELEASED);
    }
}

// Self-test (env SOH_SELFTEST): repeated button presses so flows can be
// driven on the simulator, where scripted taps are unavailable.
//   SOH_SELFTEST=1|START → START presses T+15s..T+33s (title → file select)
//   SOH_SELFTEST=A       → A presses T+10s..T+28s (confirm ImGui popups,
//                          e.g. the extractor's "Use this rom?"; needs
//                          gSettings.ControlNav=1 for ImGui gamepad nav)
static void SohIos_ScheduleSelfTest(void) {
    const char* mode = getenv("SOH_SELFTEST");
    if (mode == NULL) {
        return;
    }
    // SOH_SELFTEST=CLICK:x1,y1[;x2,y2…] → inject left-clicks cycling through
    // the given window points, T+8s onward (drives ImGui buttons across a
    // multi-popup flow like the extractor's).
    if (strncmp(mode, "CLICK:", 6) == 0) {
        static int pts[8][2];
        int n = 0;
        const char* p = mode + 6;
        while (n < 8 && sscanf(p, "%d,%d", &pts[n][0], &pts[n][1]) == 2) {
            n++;
            p = strchr(p, ';');
            if (p == NULL) {
                break;
            }
            p++;
        }
        if (n > 0) {
            const int rounds = 12;
            NSLog(@"[SohIosShell] SELFTEST armed: %d click point(s), %d rounds from T+8s", n, rounds);
            const int nPts = n;
            for (int i = 0; i < rounds; i++) {
                double at = 8.0 + 2.0 * i;
                int idx = i % nPts;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                               dispatch_get_main_queue(),
                               ^{ SohIos_InjectClick(pts[idx][0], pts[idx][1]); });
            }
        }
        return;
    }
    // SOH_SELFTEST=KEY:esc → inject one Escape key press at T+12s (opens the
    // SoH menu; on-phone this will be a gesture/HUD button later).
    if (strcmp(mode, "KEY:esc") == 0) {
        NSLog(@"[SohIosShell] SELFTEST armed: Escape at T+12s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); });
        return;
    }
    SDL_GameControllerButton btn = SDL_CONTROLLER_BUTTON_START;
    double firstAt = 15.0;
    if (strcmp(mode, "A") == 0) {
        btn = SDL_CONTROLLER_BUTTON_A;
        firstAt = 10.0;
    }
    NSLog(@"[SohIosShell] SELFTEST armed: 8x button %d from T+%.0fs", btn, firstAt);
    for (int i = 0; i < 8; i++) {
        double at = firstAt + 2.5 * i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[SohIosShell] SELFTEST press #%d (btn %d)", i, btn);
            SohIos_PadButton(btn, YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ SohIos_PadButton(btn, NO); });
        });
    }
}

#pragma mark - ROM onboarding (document picker)

static NSString* SohIos_DocumentsPath(void) {
    const char* home = getenv("HOME");
    return [NSString stringWithFormat:@"%s/Documents", home ? home : "/tmp"];
}

static BOOL SohIos_DocumentsHasExt(NSArray<NSString*>* exts) {
    NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:SohIos_DocumentsPath() error:nil];
    for (NSString* f in files) {
        if ([exts containsObject:f.pathExtension.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

// BLOCKING native ROM picker, called by the game (overlay 0015 rev2) from
// GameExtractor::SelectGameFromUI when the Documents scan finds no supported
// .z64. Starship's whole extraction flow runs PRE-SDL-WINDOW, so this picker
// spins its own runloop. The window comes from SohIos_MakeOnboardingWindow
// (scene-attached, fitted) — a UIScreen-bounds window with no scene is
// invisible after the iOS 27 scene adoption (D31). Returns 1 if a .z64 was
// copied into Documents (original filename, NSFileProtectionNone + 0644).
static UIWindow* SohIos_MakeOnboardingWindow(void);
static void SohIos_FitModalWindow(UIWindow* window, const char* why);
@interface SohIosRomPickDelegate : NSObject <UIDocumentPickerDelegate>
@property(nonatomic) BOOL done;
@property(nonatomic) BOOL picked;
@end

@implementation SohIosRomPickDelegate
- (void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count > 0) {
        NSURL* src = urls.firstObject; // asCopy:YES => already a local temp copy
        NSString* dst = [SohIos_DocumentsPath() stringByAppendingPathComponent:src.lastPathComponent];
        NSError* err = nil;
        [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
        BOOL ok = [NSFileManager.defaultManager moveItemAtPath:src.path toPath:dst error:&err];
        if (ok) {
            [NSFileManager.defaultManager setAttributes:@{
                NSFileProtectionKey : NSFileProtectionNone,
                NSFilePosixPermissions : @0644
            } ofItemAtPath:dst error:nil];
        }
        NSLog(@"[SohIosShell] ROM import (blocking picker) %@ -> %@ (%@)", ok ? @"OK" : @"FAILED", dst, err);
        self.picked = ok;
    }
    self.done = YES;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)c {
    NSLog(@"[SohIosShell] ROM picker cancelled");
    self.done = YES;
}
@end

int SohIos_PickRomBlocking(void) {
    NSCAssert(NSThread.isMainThread, @"SohIos_PickRomBlocking must run on the main thread");
    SohIosRomPickDelegate* d = [SohIosRomPickDelegate new];
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    UTType* z64 = [UTType typeWithFilenameExtension:@"z64"];
    if (z64 != nil) {
        [types addObject:z64];
    } else {
        [types addObject:UTTypeData];
    }
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = d;

#if TARGET_OS_VISION
    (void)picker; // unused on visionOS — a UIKit modal can't composite from an
                  // engine-thread nested runloop here (black-screen trap). Drive
                  // a SwiftUI .fileImporter instead and poll Documents for the
                  // copied ROM (the importer runs while we pump the runloop).
    (void)d;
    extern void Soh_RequestRomImport(void); // SohVisionApp.swift (@_cdecl)
    Soh_RequestRomImport();
    NSString* docs = SohIos_DocumentsPath();
    NSFileManager* fm = NSFileManager.defaultManager;
    // ~5 min budget; return as soon as a .z64/.o2r lands (user picked one, or
    // dropped one via Files).
    for (int sohTick = 0; sohTick < 3000; sohTick++) {
        for (NSString* f in [fm contentsOfDirectoryAtPath:docs error:nil]) {
            NSString* ext = f.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"z64"] || [ext isEqualToString:@"o2r"]) {
                NSLog(@"[SohIosShell] visionOS ROM appeared: %@", f);
                return 1;
            }
        }
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    NSLog(@"[SohIosShell] visionOS ROM import timed out");
    return 0;
#else
    UIWindow* w = SohIos_MakeOnboardingWindow();
    [w.rootViewController presentViewController:picker animated:YES completion:nil];
    while (!d.done) {
        SohIos_FitModalWindow(w, "picker");
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    w.hidden = YES;
    return d.picked ? 1 : 0;
#endif
}

// Native first-run flow: if there's no ROM and no extracted archive yet,
// offer a document picker (Files/iCloud) and copy the chosen ROM into
// Documents with sane protection/permissions . The in-engine
// extractor popups then find it and do the rest.
@interface SohIosOnboarding : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

static SohIosOnboarding* gOnboarding = nil;

@implementation SohIosOnboarding

+ (void)maybePresentIn:(UIWindow*)window {
    if (SohIos_DocumentsHasExt(@[ @"z64" ]) || SohIos_DocumentsHasExt(@[ @"o2r" ])) {
        return; // already has a ROM or is already extracted
    }
    gOnboarding = [SohIosOnboarding new];
    gOnboarding.window = window;
    UIAlertController* a =
        [UIAlertController alertControllerWithTitle:@"Star Fox 64 ROM needed"
                                            message:@"Pick your legally-owned Star Fox 64 (US 1.0 or 1.1) ROM (.z64). It will "
                                                    @"be copied into this app's Documents folder, then the game will "
                                                    @"offer to extract it."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Choose ROM…"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* _) { [gOnboarding presentPicker]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later (drop it in via Files)"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [window.rootViewController presentViewController:a animated:YES completion:nil];
}

- (void)presentPicker {
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    for (NSString* e in @[ @"z64" ]) {
        UTType* t = [UTType typeWithFilenameExtension:e];
        if (t != nil) {
            [types addObject:t];
        }
    }
    if (types.count == 0) {
        [types addObject:UTTypeData];
    }
    UIDocumentPickerViewController* p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                                                    asCopy:YES];
    p.delegate = self;
    [self.window.rootViewController presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count == 0) {
        return;
    }
    NSURL* src = urls.firstObject; // asCopy:YES => already a local temp copy
    NSString* dst = [SohIos_DocumentsPath() stringByAppendingPathComponent:src.lastPathComponent];
    NSError* err = nil;
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:src.path toPath:dst error:&err];
    if (ok) {
        // user-imported data gets NSFileProtectionNone + sane modes.
        [NSFileManager.defaultManager setAttributes:@{
            NSFileProtectionKey : NSFileProtectionNone,
            NSFilePosixPermissions : @0644
        } ofItemAtPath:dst error:nil];
    }
    NSLog(@"[SohIosShell] ROM import %@ -> %@ (%@)", ok ? @"OK" : @"FAILED", dst, err);
    UIAlertController* a = [UIAlertController
        alertControllerWithTitle:ok ? @"ROM added" : @"Import failed"
                         message:ok ? @"Now answer the game's prompts (Yes) to extract and play."
                                    : err.localizedDescription
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - Remote console bridge (launch-gated TCP)

// SOH_CONSOLE=1 → listen on TCP 8765 and accept newline-delimited commands.
// Converts "needs hands" into "scriptable" for remote testing .
// Protocol (one command per line, replies "ok"/"err …"):
//   ping                 liveness
//   btn NAME [ms]        press virtual pad button (A B START L R) for ms (default 200)
//   z [ms]               press Z (left trigger axis) for ms
//   stick X Y [ms]       deflect stick, floats -1..1, for ms (default 500)
//   click X Y            SDL mouse click at window point
//   key esc              Escape (toggles the SoH menu)
//   thermal              current thermal state
#ifndef SOH_REMOTE_CONSOLE
#define SOH_REMOTE_CONSOLE 0
#endif

#if SOH_REMOTE_CONSOLE
static NSString* SohIos_HandleConsoleLine(NSString* line) {
    NSArray<NSString*>* tok = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@" "];
    if (tok.count == 0 || tok[0].length == 0) {
        return @"err empty";
    }
    NSString* cmd = tok[0].lowercaseString;
    if ([cmd isEqualToString:@"ping"]) {
        return @"ok";
    }
    if ([cmd isEqualToString:@"thermal"]) {
        return [NSString stringWithFormat:@"ok thermal=%d", SohIos_ThermalState()];
    }
#if TARGET_OS_VISION
    // Window/scene/view geometry snapshot (the "too big for the window" debug):
    // marshal to main (UIKit) via async + poll, never dispatch_sync (§2.11).
    if ([cmd isEqualToString:@"geom"]) {
        extern int SohIos_GeomReport(char* buf, int cap);
        char* gbuf = (char*)calloc(1, 512); // heap: a C array can't be __block-captured
        __block int done = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            SohIos_GeomReport(gbuf, 512);
            done = 1;
        });
        for (int i = 0; i < 200 && !done; i++) {
            usleep(10 * 1000);
        }
        NSString* r = [NSString stringWithFormat:@"ok %s", gbuf];
        free(gbuf);
        return r;
    }
    // 3D telemetry + enter/exit (§2.11). `3d` reports the loop; `3d on|off`
    // drives Soh_Enter3D (marshals to main; SDL's event pump drains the queue).
    if ([cmd isEqualToString:@"3d"]) {
        extern void Soh_Enter3D(bool on);
        extern volatile int gSoh3DRunning;
        extern volatile int gSoh3DDrainTicks;
        if (tok.count >= 2) {
            BOOL on = [tok[1] isEqualToString:@"on"];
            Soh_Enter3D(on);
            return [NSString stringWithFormat:@"ok 3d %@", on ? @"on" : @"off"];
        }
        extern volatile int gSoh3DDbgMenuVis, gSoh3DDbgMenuBuilds, gSoh3DDbgMenuVtx, gSoh3DDbgMenuDraws;
        extern volatile int gSoh3DCinematic, gSoh3DDbgGameState, gSoh3DDbgInterpGuard;
        return [NSString
            stringWithFormat:@"ok mode=%d running=%d eyeL=%d eyeR=%d camDist=%.0f conv=%.0f sep=%.2f drain=%d "
                             @"cur=%dx%d paused=%d inplay=%d menuBuilds=%d menuVis=%d menuVtx=%d menuDraws=%d "
                             @"cine=%d gameState=%d interpGuard=%d",
                             gSoh3DMode, gSoh3DRunning, gSoh3DEyeFrames[0], gSoh3DEyeFrames[1], gSoh3DCamDist,
                             gSoh3DDbgConv, gSoh3DDbgSep, gSoh3DDrainTicks, gSoh3DDbgCurW, gSoh3DDbgCurH,
                             gSoh3DPaused, gSoh3DInPlay, gSoh3DDbgMenuBuilds, gSoh3DDbgMenuVis, gSoh3DDbgMenuVtx,
                             gSoh3DDbgMenuDraws, gSoh3DCinematic, gSoh3DDbgGameState, gSoh3DDbgInterpGuard];
    }
    // Sim harness: exercise the 3D ornament Menu button (sets gSoh3DMenuToggleReq,
    // consumed by the Fast3dWindow loop -> GetMenu()->ToggleVisibility()).
    if ([cmd isEqualToString:@"togglemenu"]) {
        SohIos_ToggleMenuKey();
        return @"ok togglemenu";
    }
#endif
    if ([cmd isEqualToString:@"hideprobe"]) {
        // Customizer hide/show gate (list / select KEY / chiptap / tapedit X Y
        // / save). SohIos_LayoutHideProbe hops to the main thread.
        extern NSString* SohIos_LayoutHideProbe(NSArray<NSString*>* args);
        NSArray<NSString*>* args =
            tok.count >= 2 ? [tok subarrayWithRange:NSMakeRange(1, tok.count - 1)] : @[];
        return SohIos_LayoutHideProbe(args);
    }
    // Perf round 2026-10-09 instruments (= SoH D-088's): `stickspin CX CY R
    // SECS [RPS]` (synthetic finger circling the floating stick at 120 Hz),
    // `zpress MS` (hold the touch Z), `overlayshot NAME` (the overlay alone as
    // a transparent Documents/NAME.png, for pixel diffs across builds).
    if ([cmd isEqualToString:@"stickspin"] || [cmd isEqualToString:@"zpress"] ||
        [cmd isEqualToString:@"overlayshot"]) {
        extern NSString* SohIos_OverlayPerfProbe(NSArray<NSString*>* args);
        NSString* sub = [cmd isEqualToString:@"stickspin"] ? @"spin"
                        : [cmd isEqualToString:@"zpress"]  ? @"zpress"
                                                           : @"shot";
        NSMutableArray<NSString*>* args = [NSMutableArray arrayWithObject:sub];
        if (tok.count >= 2) {
            [args addObjectsFromArray:[tok subarrayWithRange:NSMakeRange(1, tok.count - 1)]];
        }
        return SohIos_OverlayPerfProbe(args);
    }
    // SOH_IOS (SYNC WAVE 2): on-demand GPU frame time + drawable size. Reads
    // the cached gSohIosGpuMs — never blocks on the GPU (reference trap).
    if ([cmd isEqualToString:@"drawable"]) {
        CGSize ds = CGSizeZero;
        if (gSdlWindow != NULL) {
            int w = 0, h = 0;
            SDL_Metal_GetDrawableSize(gSdlWindow, &w, &h);
            ds = CGSizeMake(w, h);
        }
        // hz = what the PANEL can actually do (UIScreen, independent of SDL);
        // the rest are the CVars feeding GetInterpolationFPS (overlay 0020),
        // so a "why am I capped at 60" report is answerable over the bridge.
#if TARGET_OS_VISION
        NSInteger sohIosHz = 0; // no UIScreen on visionOS (compositor-paced)
#else
        NSInteger sohIosHz = UIScreen.mainScreen.maximumFramesPerSecond;
#endif
        // sdlhz = what SDL's display mode reports, i.e. exactly what LUS's
        // GetCurrentRefreshRate() feeds the engine. If hz and sdlhz disagree,
        // THAT is the frame-rate bug — the panel does 120 but the engine
        // believes otherwise.
        int sohIosSdlHz = -1;
        if (gSdlWindow != NULL) {
            SDL_DisplayMode dm;
            if (SDL_GetWindowDisplayMode(gSdlWindow, &dm) == 0) {
                sohIosSdlHz = dm.refresh_rate;
            }
        }
        return [NSString
            stringWithFormat:@"ok drawable=%.0fx%.0f gpu_ms=%.2f msaa=%d ssaa=%.2f hz=%ld sdlhz=%d maxfps=%d "
                             @"interp=%d match=%d vsync=%d thermal=%d",
                             ds.width, ds.height, gSohIosGpuMs, CVarGetInteger("gMSAAValue", 1),
                             SohIos_SsaaFactor(), (long)sohIosHz, sohIosSdlHz,
                             CVarGetInteger("gSohIos.MaxFps", 1), CVarGetInteger("gInterpolationFPS", 60),
                             CVarGetInteger("gMatchRefreshRate", 0), CVarGetInteger("gVsyncEnabled", 1),
                             SohIos_ThermalState()];
    }
    // SOH_IOS (SYNC WAVE 2): live CVar get/set for A/B tuning over the bridge.
    //   cvar NAME            -> reports int + float views
    //   cvar NAME VALUE      -> sets float if VALUE has a '.', else int
    // Used for Supersample and AsyncShaders A/B without rebuilding.
    if ([cmd isEqualToString:@"cvar"] && tok.count >= 2) {
        const char* name = tok[1].UTF8String;
        if (tok.count >= 3) {
            NSString* v = tok[2];
            if ([v containsString:@"."]) {
                CVarSetFloat(name, v.floatValue);
            } else {
                CVarSetInteger(name, v.intValue);
            }
            CVarSave();
            return [NSString stringWithFormat:@"ok set %s = %@", name, v];
        }
        return [NSString stringWithFormat:@"ok %s int=%d float=%.3f", name, CVarGetInteger(name, 0),
                                          CVarGetFloat(name, 0.0f)];
    }
    // SOH_IOS (SYNC WAVE 2 addendum A): wipe Library/Caches + tmp (Documents /
    // game data untouched) so the NEXT LAUNCH recompiles Metal shaders COLD —
    // the repeatable async-shader A/B. Relaunch after running this.
    if ([cmd isEqualToString:@"shaderclear"]) {
        NSFileManager* fm = NSFileManager.defaultManager;
        int removed = 0;
        NSArray<NSString*>* dirs = @[
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"",
            NSTemporaryDirectory() ?: @""
        ];
        for (NSString* dir in dirs) {
            if (dir.length == 0) {
                continue;
            }
            for (NSString* entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([fm removeItemAtPath:[dir stringByAppendingPathComponent:entry] error:nil]) {
                    removed++;
                }
            }
        }
        return [NSString stringWithFormat:@"ok cleared %d entries (relaunch to recompile cold)", removed];
    }
    if ([cmd isEqualToString:@"crashlog"]) {
        NSString* path = [NSString stringWithFormat:@"%s/Documents/crash.txt", getenv("HOME")];
        NSString* content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        return content.length ? [@"ok\n" stringByAppendingString:content] : @"ok (no crash.txt)";
    }
    if ([cmd isEqualToString:@"logtail"]) {
        int lines = tok.count >= 2 ? MAX(10, MIN(400, tok[1].intValue)) : 80;
        NSString* dir = [NSString stringWithFormat:@"%s/Documents/logs", getenv("HOME")];
        NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
        for (NSString* f in files) {
            if ([f hasSuffix:@".log"]) {
                NSString* content =
                    [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
                NSArray* all = [content componentsSeparatedByString:@"\n"];
                NSUInteger start = all.count > (NSUInteger)lines ? all.count - lines : 0;
                return [@"ok\n" stringByAppendingString:
                            [[all subarrayWithRange:NSMakeRange(start, all.count - start)]
                                componentsJoinedByString:@"\n"]];
            }
        }
        return @"ok (no log files)";
    }
    if ([cmd isEqualToString:@"bg"]) {
        return [NSString stringWithFormat:@"ok backgrounded=%d", SohIos_IsBackgrounded()];
    }
    if ([cmd isEqualToString:@"pads"]) {
        // Controller diagnostics: name, mapping, live axes — the Z-dead-on-
        // gamepad investigation reads this on sim AND on device.
        NSMutableString* out = [NSMutableString stringWithString:@"ok "];
        for (int i = 0; i < SDL_NumJoysticks(); i++) {
            if (!SDL_IsGameController(i)) {
                [out appendFormat:@"[j%d %s notGC] ", i, SDL_JoystickNameForIndex(i) ?: "?"];
                continue;
            }
            SDL_GameController* gc = SDL_GameControllerOpen(i); // refcounted; close below only releases our ref
            if (gc == NULL) {
                continue;
            }
            char* map = SDL_GameControllerMapping(gc);
            NSString* mapStr = map ? [NSString stringWithUTF8String:map] : @"none";
            if (map != NULL) {
                SDL_free(map);
            }
            if (mapStr.length > 260) {
                mapStr = [[mapStr substringToIndex:260] stringByAppendingString:@"..."];
            }
            [out appendFormat:@"[gc%d %s axes=%d,%d,%d,%d,%d,%d map=%@] ", i, SDL_GameControllerName(gc) ?: "?",
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTX),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTY),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_RIGHTX),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_RIGHTY),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_TRIGGERLEFT),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_TRIGGERRIGHT), mapStr];
            SDL_GameControllerClose(gc);
        }
        return out;
    }
    if ([cmd isEqualToString:@"seq"]) {
        uint32_t ids = SohIos_ActiveSeqIds();
        return [NSString stringWithFormat:@"ok bgm=0x%04x fanfare=0x%04x", ids & 0xFFFF, (ids >> 16) & 0xFFFF];
    }
    // Starship's menubar toggle is F1 (LUS Gui TOGGLE_BTN); accept both tokens.
    if ([cmd isEqualToString:@"key"] && tok.count >= 2 &&
        ([tok[1] isEqualToString:@"esc"] || [tok[1] isEqualToString:@"f1"])) {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        return @"ok";
    }
    if ([cmd isEqualToString:@"click"] && tok.count >= 3) {
        SohIos_InjectClick(tok[1].intValue, tok[2].intValue);
        return @"ok";
    }
    if ([cmd isEqualToString:@"z"]) {
        int ms = tok.count >= 2 ? tok[1].intValue : 200;
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, YES); // Starship: BTN_Z <- SDL LB
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, NO); });
        return @"ok";
    }
    if ([cmd isEqualToString:@"stick"] && tok.count >= 3) {
        float x = tok[1].floatValue, y = tok[2].floatValue;
        int ms = tok.count >= 4 ? tok[3].intValue : 500;
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, (Sint16)(MAX(-1.f, MIN(1.f, x)) * 32767));
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, (Sint16)(MAX(-1.f, MIN(1.f, y)) * 32767));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
        });
        return @"ok";
    }
    if ([cmd isEqualToString:@"btn"] && tok.count >= 2) {
        static NSDictionary<NSString*, NSNumber*>* map = nil;
        if (map == nil) {
            map = @{
                @"a" : @(SDL_CONTROLLER_BUTTON_A),
                @"b" : @(SDL_CONTROLLER_BUTTON_X), // Starship: BTN_B <- SDL X
                @"start" : @(SDL_CONTROLLER_BUTTON_START),
                @"cl" : @(SDL_CONTROLLER_BUTTON_Y), // Starship: BTN_CLEFT <- SDL Y
                @"cd" : @(SDL_CONTROLLER_BUTTON_B), // Starship: BTN_CDOWN <- SDL B
                @"r" : @(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER),
            };
        }
        NSNumber* b = map[tok[1].lowercaseString];
        if (b == nil) {
            return @"err unknown button";
        }
        int ms = tok.count >= 3 ? tok[2].intValue : 200;
        SDL_GameControllerButton btn = (SDL_GameControllerButton)b.intValue;
        SohIos_PadButton(btn, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PadButton(btn, NO); });
        return @"ok";
    }
    return @"err unknown command";
}

static void SohIos_StartConsoleBridge(BOOL force) {
    // Gated three ways: SOH_CONSOLE env (tool launches: simctl/devicectl), a
    // `console_enabled` file in Documents — creatable/deletable in the Files
    // app, so user-launched builds (OTA/TestFlight) can opt in without a
    // computer — or force=YES (soh://console deep link on a running app).
    static BOOL started = NO; // all callers are on the main thread
    if (started) {
        return;
    }
    BOOL fileGate = NO;
    const char* home = getenv("HOME");
    if (home != NULL) {
        // Accept a .txt suffix too — iOS Files can't create extensionless
        // files without a rename dance.
        NSString* docs = [NSString stringWithFormat:@"%s/Documents", home];
        fileGate = [NSFileManager.defaultManager
                       fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled"]] ||
                   [NSFileManager.defaultManager
                       fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled.txt"]];
    }
    const char* consoleEnv = getenv("SOH_CONSOLE");
    if (!force && consoleEnv == NULL && !fileGate) {
        return; // launch-gated: no listener unless explicitly requested
    }
    // Starship's bridge is ALWAYS 8767 by default (soh=8765, 2ship=8766;
    // simulators share the Mac's localhost). A numeric SOH_CONSOLE overrides.
    int consolePort = 8767;
    if (consoleEnv != NULL) {
        int envPort = atoi(consoleEnv);
        if (envPort > 1024 && envPort <= 65535) {
            consolePort = envPort;
        }
    }
    started = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) {
            NSLog(@"[SohIosShell] bridge socket failed: %d", errno);
            return;
        }
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(consolePort);
        BOOL bound = NO;
        for (int i = 0; i < 10 && !bound; i++) { // bind retry (predecessor pattern)
            bound = bind(srv, (struct sockaddr*)&addr, sizeof(addr)) == 0;
            if (!bound) {
                usleep(500 * 1000);
            }
        }
        if (!bound || listen(srv, 1) != 0) {
            NSLog(@"[SohIosShell] bridge bind/listen failed: %d", errno);
            close(srv);
            return;
        }
        NSLog(@"[SohIosShell] console bridge listening on :%d", consolePort);
        for (;;) {
            int cli = accept(srv, NULL, NULL);
            if (cli < 0) {
                continue;
            }
            NSLog(@"[SohIosShell] bridge client connected");
            // A client that hangs up before the reply (port probe, nc -z,
            // dropped tailnet) must get EPIPE, not SIGPIPE: the default action
            // killed the app silently on the 2026-10-08 sim round (exit
            // signal SIGPIPE right after "bridge client connected"). Same fix
            // as Shipwright/SpaghettiKart (docs/SHELL-SIGPIPE-ADVISORY.md).
            int nosig = 1;
            setsockopt(cli, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
            FILE* f = fdopen(cli, "r");
            char line[512];
            while (f != NULL && fgets(line, sizeof(line), f) != NULL) {
                NSString* resp = SohIos_HandleConsoleLine([NSString stringWithUTF8String:line] ?: @"");
                dprintf(cli, "%s\n", resp.UTF8String);
            }
            if (f != NULL) {
                fclose(f);
            }
            NSLog(@"[SohIosShell] bridge client disconnected");
        }
    });
}

#else // !SOH_REMOTE_CONSOLE — public build: no listener exists at all.
static void SohIos_StartConsoleBridge(BOOL force) {
    (void)force;
}
#endif

#pragma mark - Deep links (soh:// URL scheme)

static void SohIos_HandleDeepLink(NSString* url) {
    NSLog(@"[SohIosShell] deep link: %@", url);
    if ([url hasPrefix:@"starship://console"]) {
        SohIos_StartConsoleBridge(YES); // one-tap remote debugging opt-in
    } else if ([url hasPrefix:@"starship://menu"]) {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
    } else {
        NSLog(@"[SohIosShell] unknown deep link ignored: %@", url);
    }
}

// SDL2's UIKit app delegate delivers incoming custom-scheme URLs as
// SDL_DROPFILE events (application:openURL: -> SDL_SendDropFile). A filter
// (not a watch) can consume them before LUS's FileDropMgr mistakes the URL
// for a file path. NOTE (verified by lldb breakpoints on this runtime):
// iOS 26-era UIKit never calls the legacy application:openURL: on this app
// at all — it runs a scene session (nil delegate) and delivers URL opens
// only via scene:openURLContexts:. The SohIosSceneDelegate below is the
// path that actually fires; this filter stays as belt-and-braces for
// runtimes that still use the legacy delegate.
static int SohIos_EventFilter(void* userdata, SDL_Event* event) {
    if (event->type == SDL_DROPFILE && event->drop.file != NULL &&
        strncmp(event->drop.file, "starship://", 11) == 0) {
        NSString* url = [NSString stringWithUTF8String:event->drop.file];
        SDL_free(event->drop.file);
        event->drop.file = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ SohIos_HandleDeepLink(url); });
        return 0; // consumed
    }
    // Stray-Escape guard. LUS toggles the menu on Escape (Gui.cpp), and on
    // iOS the ONLY legitimate sources of Escape are this shell's own
    // injections — the ≡ button, the restore dot, the deep link, the bridge.
    // Anything else is forged: iPadOS turns a game controller's B into a
    // UIKit "cancel", which SDL's UIKit backend used to hand over as a
    // keyboard Escape, so B opened/closed the menu on every press. The SDL
    // dependency patch closes both forgery routes at the source; this is
    // the backstop that holds no matter what synthesizes the key.
    if ((event->type == SDL_KEYDOWN || event->type == SDL_KEYUP) &&
        event->key.keysym.scancode == SDL_SCANCODE_ESCAPE && event->key.keysym.unused != SOHIOS_KEY_MAGIC) {
        // Arm first: both hop the same serial queue, so the buffered context
        // is flushed ahead of this line rather than racing it.
        SohIos_TraceArm();
        SohIos_Trace(@"DROPPED forged escape (%@) — a controller or the system sent Escape",
                     event->type == SDL_KEYDOWN ? @"down" : @"up");
        return 0; // consumed: the menu does not move
    }
    if (event->type == SDL_KEYDOWN) {
        SohIos_Trace(@"key down scancode=%d sym=%d%@", (int)event->key.keysym.scancode, (int)event->key.keysym.sym,
                     event->key.keysym.unused == SOHIOS_KEY_MAGIC ? @" (shell)" : @"");
    }
    // First few physical-pad presses only: enough to prove the pad's normal
    // path works, without tracing a whole play session.
    if (event->type == SDL_CONTROLLERBUTTONDOWN) {
        static int seen;
        if (seen++ < 24) {
            SohIos_Trace(@"pad button %d down (joystick %d)", (int)event->cbutton.button, (int)event->cbutton.which);
        }
    }
    if (event->type == SDL_CONTROLLERDEVICEADDED) {
        SohIos_Trace(@"pad added: index %d", (int)event->cdevice.which);
    }
    return 1;
}

// The app's scene delegate. As of the iOS 27 SDK (D22, Shipwright c8de40b)
// it is NAMED IN THE Info.plist scene manifest (overlay 0012) and UIKit
// instantiates it itself; +load below grafts the matching configuration hook
// onto SDL's app delegate, which is the other half the runtime insists on.
// SohIos_InstallSceneDelegate() still attaches it to any scene that arrived
// with delegate == nil, so a build against an older SDK behaves as before.
//
// Lifecycle: the scene callbacks below already carry all shell lifecycle work
// (config flush, background gate) and forward to SDL's app delegate (fwd:).
// SDL itself listens on NSNotificationCenter (SDL_uikitevents.m), and the
// UIApplication notifications still post under a scene life cycle, so nothing
// SDL needs is lost and nothing fires twice (SDLUIKitDelegate implements none
// of the application activation callbacks).
@interface SohIosSceneDelegate : NSObject <UIWindowSceneDelegate>
@end

// The scene UIKit connected us to, remembered the moment it arrives (before
// SDL_main has created any window).
static UIWindowScene* gSohConnectedScene = nil;

@implementation SohIosSceneDelegate
#if !TARGET_OS_VISION
// iOS 27 SDK gate: UIKit kills a UIKit app built against this SDK at launch
// (SIGTRAP in ___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption)
// unless it adopts scenes, and it checks the APP DELEGATE for the scene-
// configuration hook -- the manifest alone is not enough. The app delegate is
// SDL2's SDLUIKitDelegate (fetched by LUS, not ours to fork), so graft the one
// method onto it at +load, long before UIApplicationMain. class_addMethod (not
// a category) keeps zero link dependency on SDL's class.
static UISceneConfiguration* SohIos_SceneConfigForSession(id self, SEL _cmd, UIApplication* application,
                                                          UISceneSession* connectingSceneSession,
                                                          UISceneConnectionOptions* options) {
    UISceneConfiguration* cfg = [UISceneConfiguration configurationWithName:@"Default"
                                                               sessionRole:connectingSceneSession.role];
    cfg.delegateClass = SohIosSceneDelegate.class;
    cfg.sceneClass = UIWindowScene.class;
    return cfg;
}

+ (void)load {
    Class sdlDelegate = NSClassFromString(@"SDLUIKitDelegate");
    if (sdlDelegate == Nil) {
        NSLog(@"[SohIosShell] SDLUIKitDelegate not found; scene-config hook NOT installed");
        return;
    }
    SEL sel = @selector(application:configurationForConnectingSceneSession:options:);
    if ([sdlDelegate instancesRespondToSelector:sel]) {
        return; // SDL grew one; leave it alone
    }
    BOOL ok = class_addMethod(sdlDelegate, sel, (IMP)SohIos_SceneConfigForSession, "@@:@@@");
    NSLog(@"[SohIosShell] scene-config hook on SDLUIKitDelegate: %@", ok ? @"installed" : @"FAILED");
}
#endif

// First shell code that runs with a live scene. SDL's game window does not
// exist yet (SDL_main runs on a later run-loop turn), so remember the scene,
// attach any window that already exists (SDL's launch-screen window), and
// hand launch-time starship:// URLs over once the engine is up.
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session
      options:(UISceneConnectionOptions*)connectionOptions {
    if ([scene isKindOfClass:UIWindowScene.class]) {
        UIWindowScene* ws = (UIWindowScene*)scene;
        gSohConnectedScene = ws;
        for (UIWindow* w in UIApplication.sharedApplication.windows) {
            if (w.windowScene == nil) {
                w.windowScene = ws;
            }
        }
        NSLog(@"[SohIosShell] scene connected (%@ windows adopted)", @(UIApplication.sharedApplication.windows.count));
    }
    for (UIOpenURLContext* ctx in connectionOptions.URLContexts) {
        NSString* u = ctx.URL.absoluteString;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_HandleDeepLink(u); });
    }
}
- (void)sceneDidDisconnect:(UIScene*)scene {
    if ((UIScene*)gSohConnectedScene == scene) {
        gSohConnectedScene = nil;
    }
}
- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
    for (UIOpenURLContext* ctx in URLContexts) {
        SohIos_HandleDeepLink(ctx.URL.absoluteString);
    }
}
- (void)fwd:(SEL)sel {
    id<UIApplicationDelegate> app = UIApplication.sharedApplication.delegate;
    if ([app respondsToSelector:sel]) {
        void (*imp)(id, SEL, UIApplication*) = (void*)[(id)app methodForSelector:sel];
        imp(app, sel, UIApplication.sharedApplication);
    }
}
- (void)sceneWillResignActive:(UIScene*)scene {
    SohIos_FlushConfig("sceneWillResignActive"); // swipe-kill safety
    [self fwd:@selector(applicationWillResignActive:)];
}
- (void)sceneDidEnterBackground:(UIScene*)scene {
    SohIos_FlushConfig("sceneDidEnterBackground");
    SohIos_SetBackgrounded(1); // gate Metal rendering (overlay 0016)
    [self fwd:@selector(applicationDidEnterBackground:)];
}
- (void)sceneWillEnterForeground:(UIScene*)scene {
    SohIos_SetBackgrounded(0);
    [self fwd:@selector(applicationWillEnterForeground:)];
}
- (void)sceneDidBecomeActive:(UIScene*)scene {
    SohIos_SetBackgrounded(0); // belt-and-braces on every activation path
    [self fwd:@selector(applicationDidBecomeActive:)];
}
- (NSUserActivity*)stateRestorationActivityForScene:(UIScene*)scene {
    return nil; // engine re-boots fresh each launch (predecessor lesson)
}
@end

static void SohIos_InstallSceneDelegate(void) {
    static SohIosSceneDelegate* gSceneDelegate = nil;
    if (gSceneDelegate == nil) {
        gSceneDelegate = [SohIosSceneDelegate new];
    }
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.delegate == nil) {
            scene.delegate = gSceneDelegate;
            NSLog(@"[SohIosShell] scene delegate installed on %@", scene);
        }
    }
}

#pragma mark - Touch control overlay (visual v1)

// A translucent overlay drawn over SDL's Metal layer showing the N64 control
// layout: a floating left analog stick and the right-hand button cluster
// (A, B, C-up/down/left/right, Z, R, Start). v1 renders the layout and logs
// touches; input injection (SDL virtual controller) lands in the next revision.
@interface SohIosTouchOverlay : UIView
// Perf round 2026-10-09 (D28 = SoH D-088): drawing entry for the overlay's
// canvases (role 0: everything except the stick and Z; role 1: Z only).
- (void)sohDrawCanvasRole:(int)role inView:(UIView*)view;
@end

// D28 (= Shipwright D-088): the overlay no longer draws itself. Its content is
// split so the frequent changes stop repainting a full-screen bitmap on the
// CPU inside the game thread's SDL event pump (LUS's
// SDLAddRemoveDeviceEventHandler pumps the main run loop from inside the
// ImGui frame, every frame):
//   _stickView  the floating stick's ring + knob as two CAShapeLayers, moved
//               by `position` (no redraw at all while the finger moves)
//   _canvas     full-size, everything else (buttons, customizer, restore dot)
//               -- redrawn only on layout / visibility / mode changes
//   _zCanvas    just the Z button, so Z held/locked repaints a ~70 pt view
// All three are non-interactive subviews; touches still hit the overlay.
@interface SohIosOverlayCanvas : UIView
@property(nonatomic, weak) SohIosTouchOverlay* owner;
@property(nonatomic) int role;
@end

@implementation SohIosOverlayCanvas
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    [self.owner sohDrawCanvasRole:self.role inView:self];
}
@end

typedef struct {
    CGPoint center;   // in this view's points
    CGFloat radius;
    UIColor* color;
    NSString* label;
} SohButton;

// CVar-safe key for a (possibly glyph) button label. Defined with the layout
// customizer below; forward-declared here for the hidden-button helpers.
static NSString* SohIos_LayoutKey(NSString* label);

@implementation SohIosTouchOverlay {
    CGPoint _stickBase;   // set where the finger lands (floating stick)
    CGFloat _stickBaseR;  // full-deflection travel (v2: 54 = old 90 * 0.6)
    CGFloat _stickKnobR;  // knob radius (v2: 34 = old 42 * 0.8)
    CGPoint _stickKnob;   // current knob position
    BOOL _stickActive;
    UITouch* __unsafe_unretained _stickTouch;         // identity only, never dereferenced after end
    NSMutableDictionary<NSValue*, NSNumber*>* _touchButtons; // UITouch ptr -> button index
    BOOL _controlsHidden; // while the SoH menu is open: only the restore dot is active
    BOOL _zHeld;
    BOOL _cLeftHeld;      // Starship: C-left is an SDL BUTTON (Y), edge-tracked
    BOOL _cDownHeld;      // Starship: C-down is an SDL BUTTON (B), edge-tracked          // finger currently on Z (momentary hold)
    BOOL _zLocked;        // lock engaged (stays held, bright visual)
    CFTimeInterval _zLastTapTime; // for the double-tap window
    unsigned _zLockSeq;   // cancels a pending hold-to-lock when the finger lifts early
    Sint16 _lastSentLX, _lastSentLY; // stick-axis coalescing (audio-hitch fix)
    BOOL _controllerMode; // physical controller connected: touch controls hidden
    BOOL _popupOpen;      // any ImGui popup: overlay invisible + fully pass-through
    BOOL _lastMenuBtnVisible; // repaint trigger for pause/title transitions
    UILabel* _perfHud;        // optional fps/thermal readout (gSohIos.PerfHud)
    // Menu touch-router (menu open: overlay owns ALL touches and forwards
    // synthesized mouse events — device feedback: raw drags read as hover +
    // no scrolling): 0=undecided 1=scroll 2=drag 3=hover
    UITouch* __unsafe_unretained _routerTouch;
    int _routerMode;
    CGPoint _routerStart, _routerLast;
    // Layout customizer
    BOOL _editMode;
    NSMutableDictionary<NSString*, NSValue*>* _layoutOverrides; // label -> normalized center
    NSMutableSet<NSString*>* _layoutHidden; // layout keys the user hid from the touch layer
    CGFloat _layoutScale;
    CGPoint _stickHome;   // normalized; CGPointZero = default
    NSString* _editDrag;  // label being dragged, @"__stick", @"__slider", or nil
    NSString* _editSelected; // layout key of the last-touched button: the ONLY
                             // one showing an eye chip in the customizer (nil = none)
    // D28: layered drawing (see SohIosOverlayCanvas).
    UIView* _stickView;
    CAShapeLayer* _ringLayer;
    CAShapeLayer* _knobLayer;
    CGFloat _ringLayerR, _knobLayerR;
    SohIosOverlayCanvas* _canvas;
    SohIosOverlayCanvas* _zCanvas;
}

- (CGPoint)restoreDotCenter {
    // Top-center, matching the ≡ button's home (START owns bottom-center now).
    return CGPointMake(CGRectGetMidX(self.bounds), self.bounds.origin.y + 55);
}

// The ≡ menu button shows only where menu access makes sense: intro/title/
// file-select (users tune settings at the start) and the game's pause menu.
// Hidden during normal gameplay for BOTH touch and controller input.
// "Always Show Menu Button" (gSohIos.MenuAlwaysVisible, PortMenu Settings ->
// iOS; D21, ported from SoH D-083) keeps the ≡ button up during gameplay too.
// Every draw/hit-test path goes through here and syncWithMenuState repaints
// on a change, so the toggle is live with no other edit.
- (BOOL)menuButtonVisible {
    if (CVarGetInteger("gSohIos.MenuAlwaysVisible", 0)) {
        return YES;
    }
    return SohIos_IsGamePaused() || SohIos_IsTitleOrDemo();
}

// A user-hidden button never draws, never intercepts a touch, and never gates
// the floating stick (see hitButton/drawRect/pointInStickRegion). The ≡ menu
// button is EXEMPT — it's the only touch path into the Starship menu for a
// controller-less user, so it can never be hidden (a stale MENU.hidden CVar is
// ignored here rather than trusted).
- (BOOL)isButtonHidden:(NSString*)label {
    if ([label isEqualToString:@"≡"]) {
        return NO;
    }
    return [_layoutHidden containsObject:SohIos_LayoutKey(label)];
}

// Toggle from the customizer's per-button eye badge. Returns the new hidden
// state. ≡ can't be hidden. Live: takes effect the moment the customizer exits
// (drawRect/hitButton read _layoutHidden directly); persisted on save.
- (BOOL)toggleHiddenForLabel:(NSString*)label {
    if ([label isEqualToString:@"≡"]) {
        return NO;
    }
    NSString* key = SohIos_LayoutKey(label);
    BOOL nowHidden = ![_layoutHidden containsObject:key];
    if (nowHidden) {
        [_layoutHidden addObject:key];
    } else {
        [_layoutHidden removeObject:key];
    }
    [self setNeedsDisplay];
    return nowHidden;
}

- (CGPoint)zButtonCenter {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"Z"]) {
            return btns[i].center;
        }
    }
    return CGPointMake(-1000, -1000);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        _stickBaseR = 54.0; // -40% travel vs v1 (device feel feedback)
        _stickKnobR = 34.0; // -20% knob vs v1
        _touchButtons = [NSMutableDictionary dictionary];
        _layoutOverrides = [NSMutableDictionary dictionary];
        _layoutHidden = [NSMutableSet set];
        _layoutScale = 1.0;
        _stickHome = CGPointZero; // zero = default position
        // D28: stick layers below the button canvas (buttons drew over the
        // stick in the old single drawRect), Z canvas on top.
        _stickView = [[UIView alloc] initWithFrame:self.bounds];
        _stickView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _stickView.userInteractionEnabled = NO;
        _stickView.backgroundColor = UIColor.clearColor;
        _ringLayer = [CAShapeLayer layer];
        _ringLayer.fillColor = nil;
        _ringLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        _ringLayer.lineWidth = 4;
        _ringLayer.hidden = YES;
        _knobLayer = [CAShapeLayer layer];
        _knobLayer.fillColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        _knobLayer.strokeColor = nil;
        _knobLayer.hidden = YES;
        [_stickView.layer addSublayer:_ringLayer];
        [_stickView.layer addSublayer:_knobLayer];
        [self addSubview:_stickView];
        _canvas = [[SohIosOverlayCanvas alloc] initWithFrame:self.bounds];
        _canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _canvas.owner = self;
        _canvas.role = 0;
        [self addSubview:_canvas];
        _zCanvas = [[SohIosOverlayCanvas alloc] initWithFrame:CGRectZero];
        _zCanvas.owner = self;
        _zCanvas.role = 1;
        [self addSubview:_zCanvas];
        [self loadLayoutFromCVars];
        // EditLayout is a transient trigger, not a setting: a stale persisted
        // 1 (e.g. saved by a config flush mid-edit) must never relaunch the
        // app straight into the customizer.
        CVarSetInteger("gSohIos.EditLayout", 0);
        // The game's menu state (overlay 0013) is authoritative for hiding:
        // it catches every way the menu opens/closes (esc key, deep link,
        // the menu's own X button), not just this overlay's ≡ button.
        __weak SohIosTouchOverlay* weakSelf = self;
        [NSTimer scheduledTimerWithTimeInterval:0.25
                                        repeats:YES
                                          block:^(NSTimer* t) { [weakSelf syncWithMenuState]; }];
    }
    return self;
}

// Physical controller (Backbone etc.) present -> touch controls yield.
// SDL creates no GCController for the virtual touch pad (verified: this
// SDL2 has no GCVirtualController path), but the SIMULATOR synthesizes a
// generic keyboard-passthrough pad named exactly "Gamepad" — real hardware
// reports its brand ("Backbone One", "DualSense", ...). Filter the generic
// name; connects are logged so device runs self-document any mismatch.
static BOOL SohIos_PhysicalControllerPresent(void) {
    for (GCController* c in GCController.controllers) {
        if (![(c.vendorName ?: @"") isEqualToString:@"Gamepad"]) {
            return YES;
        }
    }
    return NO;
}

// Haptic feedback on touch buttons (gSohIos.Haptics: 0 off, 1 light, 2 strong)
- (void)hapticTap {
    int mode = CVarGetInteger("gSohIos.Haptics", 1);
    if (mode <= 0) {
        return;
    }
#if !TARGET_OS_VISION
    UIImpactFeedbackStyle style = (mode >= 2) ? UIImpactFeedbackStyleMedium : UIImpactFeedbackStyleLight;
    UIImpactFeedbackGenerator* gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen impactOccurred];
#endif // visionOS has no haptics
}

- (void)syncWithMenuState {
    // Customizer entry: the ImGui button (0017) sets this CVar; we consume
    // it, close the menu, and enter edit mode (even with a gamepad).
    if (CVarGetInteger("gSohIos.EditLayout", 0)) {
        CVarSetInteger("gSohIos.EditLayout", 0);
        if (SohIos_IsMenuOpen()) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        }
        _editMode = YES;
        _editSelected = nil; // no eye chips until the user touches a button
        _controlsHidden = NO;
        [self releaseAllControls];
        [self setNeedsDisplay];
        NSLog(@"[SohIosShell] layout customizer entered");
        return;
    }
    if (_editMode) {
        return; // customizer owns the screen; skip hide/show logic
    }
    BOOL open = SohIos_IsMenuOpen() != 0;
    BOOL controller = SohIos_PhysicalControllerPresent();
    BOOL popup = SohIos_IsPopupOpen() != 0;
    BOOL changed = NO;
    // ≡ visibility follows pause/title state (device bug: the button was
    // hit-testable before it was drawn, and lingered after unpause, because
    // nothing repainted on those transitions).
    BOOL menuBtn = [self menuButtonVisible];
    if (menuBtn != _lastMenuBtnVisible) {
        _lastMenuBtnVisible = menuBtn;
        changed = YES;
    }
    if (popup != _popupOpen) {
        _popupOpen = popup;
        if (popup) {
            [self releaseAllControls];
        }
        changed = YES;
    }
    if (controller != _controllerMode) {
        _controllerMode = controller;
        [self releaseAllControls];
        changed = YES;
        NSLog(@"[SohIosShell] controller mode %@ (controllers: %@)",
              controller ? @"ON (touch hidden)" : @"OFF (touch active)",
              [[GCController.controllers valueForKey:@"vendorName"] componentsJoinedByString:@", "]);
    }
    if (open != _controlsHidden) {
        _controlsHidden = open;
        if (open) {
            [self releaseAllControls]; // no stuck buttons/stick while hidden
        }
        changed = YES;
    }
    if (changed) {
        // D28: controller mode used to repaint the full screen every tick so
        // ≡ could follow pause; _lastMenuBtnVisible (above) now flags exactly
        // that change, in both modes.
        [self setNeedsDisplay];
    }
    // Touch-control opacity (edit mode and open menu stay fully opaque).
    CGFloat opacity = CVarGetFloat("gSohIos.TouchOpacity", 1.0f);
    self.alpha = (_editMode || _controlsHidden) ? 1.0 : MAX(0.25, MIN(1.0, opacity));
    // Remote console toggle: start the bridge on demand (idempotent).
    if (CVarGetInteger("gSohIos.RemoteConsole", 0)) {
        SohIos_StartConsoleBridge(YES);
    }
    // Perf HUD (fps + thermal from the 0008 probe).
    if (CVarGetInteger("gSohIos.PerfHud", 0)) {
        if (_perfHud == nil) {
            // Inset from the corner: the rounded bezel + landscape safe area
            // clipped the thermal suffix ("• warm/HOT") at the old x.
            _perfHud = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 190, 10, 150, 16)];
            _perfHud.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
            _perfHud.textColor = [UIColor colorWithWhite:1 alpha:0.85];
            _perfHud.textAlignment = NSTextAlignmentRight;
            _perfHud.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [self addSubview:_perfHud];
        }
        _perfHud.hidden = NO;
        float fps = 0;
        SohIos_HudStats(&fps);
        // Just the number (user feedback); thermal only when it matters.
        int th = SohIos_ThermalState();
        if (th >= 2) {
            _perfHud.text = [NSString stringWithFormat:@"%.0f \u2022 HOT", fps];
            _perfHud.textColor = [UIColor colorWithRed:1 green:0.4 blue:0.3 alpha:0.95];
        } else if (th == 1) {
            _perfHud.text = [NSString stringWithFormat:@"%.0f \u2022 warm", fps];
            _perfHud.textColor = [UIColor colorWithRed:1 green:0.8 blue:0.4 alpha:0.9];
        } else {
            _perfHud.text = [NSString stringWithFormat:@"%.0f", fps];
            _perfHud.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        }
    } else if (_perfHud != nil) {
        _perfHud.hidden = YES;
    }
}

// Send up-events for everything currently held and recentre the stick.
- (void)releaseAllControls {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (NSNumber* idx in _touchButtons.allValues) {
        NSString* l = btns[idx.intValue].label;
        if (![l isEqualToString:@"≡"] && ![l hasPrefix:@"C"]) {
            [self applyButton:l down:NO];
        }
    }
    [_touchButtons removeAllObjects];
    [self recomputeCAxes]; // dict now empty -> C axes recentre
    _stickActive = NO;
    _stickTouch = nil;
    [self syncStickLayers]; // D28
    _zHeld = NO;
    _zLocked = NO;
    _zLockSeq++; // cancel a pending hold-to-lock (the _zHeld guard also covers
                 // it, but a menu/background release must not leave one armed)
    _lastSentLX = _lastSentLY = 0;
    SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, NO); // Starship Z
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
}

// Button labels -> virtual pad actions, per STARSHIP's default SDL mappings:
// A=SDL A, B=SDL X, Z=SDL LB (momentary; optional double-tap lock),
// R=SDL RB, C↑/C→=right stick, C←/C↓=SDL Y/B. No N64 L exists in SF64.
- (void)applyButton:(NSString*)label down:(BOOL)down {
    if ([label isEqualToString:@"≡"]) {
        if (down) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); // open the modern menu (LUS: Escape toggles GetMenu(), F1 the menubar)
            _controlsHidden = YES; // get out of the menu's way (restore dot remains)
            [self setNeedsDisplay];
        }
        return;
    }
    if ([label isEqualToString:@"A"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_A, down);
    } else if ([label isEqualToString:@"B"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_X, down); // Starship: BTN_B <- SDL X
    } else if ([label isEqualToString:@"START"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_START, down);
    } else if ([label isEqualToString:@"R"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, down);
    } else if ([label isEqualToString:@"Z"]) {
        // Touchscreen Z: MOMENTARY by default — held exactly while the finger
        // is down. Two optional LOCK gestures keep it held hands-free:
        //   * HOLD >= 0.60 s (gSohIos.HoldToLock, default ON) — the
        //     SpaghettiKart gesture, ported verbatim (0.60 s + haptic confirm
        //     + seq cancel). A tap while locked releases.
        //   * DOUBLE-TAP within 0.35 s (gSohIos.ZDoubleTap, default OFF) —
        //     kept from D8; harmless alongside hold, since a double-tap's
        //     first press is far shorter than the hold threshold.
        // SF64 note: Z is the BRAKE, so an ACCIDENTAL lock mid-run is a real
        // hazard (D8). The 0.60 s threshold is what makes hold-to-lock safe
        // here — a braking tap never reaches it — and the haptic tells you
        // the moment it engages. Lock state is unmistakable in drawRect.
        if (down) {
            CFTimeInterval now = CACurrentMediaTime();
            if (_zLocked) {
                _zLocked = NO; // any tap while locked unlocks (finger still holds)
            } else if (CVarGetInteger("gSohIos.ZDoubleTap", 0) && now - _zLastTapTime < 0.35) {
                _zLocked = YES;
            } else if (CVarGetInteger("gSohIos.HoldToLock", 1)) {
                unsigned seq = ++_zLockSeq;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   if (self->_zHeld && seq == self->_zLockSeq) {
                                       self->_zLocked = YES;
                                       [self hapticTap];
                                       [self->_zCanvas setNeedsDisplay]; // D28: only Z repaints
                                   }
                               });
            }
            _zLastTapTime = now;
            _zHeld = YES;
            SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, YES); // Starship: BTN_Z <- SDL LB
        } else {
            _zHeld = NO;
            _zLockSeq++; // cancel any pending hold-to-lock
            if (!_zLocked) {
                SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, NO);
            }
        }
        [_zCanvas setNeedsDisplay]; // D28: only the Z button repaints
    } else if ([label hasPrefix:@"C"]) {
        [self recomputeCAxes];
    }
}

// C-buttons combine on the right-stick axes; recompute from all held touches.
- (void)recomputeCAxes {
    // Starship: C↑/C→ ride the right stick (the only right-stick directions
    // Starship binds); C←/C↓ are SDL BUTTONS (Y / B), edge-tracked.
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    Sint32 rx = 0, ry = 0;
    BOOL cLeft = NO, cDown = NO;
    for (NSNumber* idx in _touchButtons.allValues) {
        NSString* l = btns[idx.intValue].label;
        if ([l isEqualToString:@"C←"]) {
            cLeft = YES;
        } else if ([l isEqualToString:@"C→"]) {
            rx += 32767;
        } else if ([l isEqualToString:@"C↑"]) {
            ry -= 32767;
        } else if ([l isEqualToString:@"C↓"]) {
            cDown = YES;
        }
    }
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTX, (Sint16)MAX(-32767, MIN(32767, rx)));
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTY, (Sint16)MAX(-32767, MIN(32767, ry)));
    if (cLeft != _cLeftHeld) {
        _cLeftHeld = cLeft;
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_Y, cLeft); // Starship: BTN_CLEFT <- SDL Y
    }
    if (cDown != _cDownHeld) {
        _cDownHeld = cDown;
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_B, cDown); // Starship: BTN_CDOWN <- SDL B
    }
}

- (int)hitButton:(CGPoint)p {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    BOOL menuBtnVisible = [self menuButtonVisible];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"≡"] && !menuBtnVisible) {
            continue; // hidden during normal gameplay: not tappable either
        }
        if ([self isButtonHidden:btns[i].label]) {
            continue; // user-hidden: not drawn, not tappable
        }
        if (hypot(p.x - btns[i].center.x, p.y - btns[i].center.y) <= btns[i].radius * 1.35) {
            return i;
        }
    }
    return -1;
}

// LUS applies Port1.LeftStick.DeadzonePercentage (default 20) to all stick
// input — right for physical sticks, wrong for touch (the touch layer has
// zero mechanical noise; spec wants zero effective deadzone). Precompensate:
// any deflection starts past the deadzone, and the remaining travel maps
// linearly, so walk/run gradation is preserved. Physical pads are untouched.
static const CGFloat kLusDeadzone = 0.20;
static Sint16 SohIos_StickValue(CGFloat n) {
    if (n == 0) {
        return 0;
    }
    CGFloat m = MIN(1.0, fabs(n));
    // gSohIos.StickCurve: 0 linear, 1 expo (finer control near center)
    if (CVarGetInteger("gSohIos.StickCurve", 0) == 1) {
        m = m * m;
    }
    CGFloat v = kLusDeadzone + m * (1.0 - kLusDeadzone);
    return (Sint16)((n < 0 ? -v : v) * 32767);
}

- (void)updateStickAxesFromKnob {
    CGFloat nx = (_stickKnob.x - _stickBase.x) / _stickBaseR;
    CGFloat ny = (_stickKnob.y - _stickBase.y) / _stickBaseR;
    Sint16 lx = SohIos_StickValue(MAX(-1.0, MIN(1.0, nx)));
    Sint16 ly = SohIos_StickValue(MAX(-1.0, MIN(1.0, ny)));
    // Coalesce (device feedback: audio hitched every ~2 s while the touch
    // stick was held): touchesMoved arrives at up to 120 Hz and every
    // SDL_JoystickSetVirtualAxis takes SDL's joystick lock, contending with
    // the game thread's event pump — enough to starve the audio ring.
    // Only forward meaningful changes (~1% of range, and every zero
    // crossing so release is always exact).
    BOOL lxChanged = abs(lx - _lastSentLX) > 300 || ((lx == 0) != (_lastSentLX == 0));
    BOOL lyChanged = abs(ly - _lastSentLY) > 300 || ((ly == 0) != (_lastSentLY == 0));
    if (lxChanged) {
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, lx);
        _lastSentLX = lx;
    }
    if (lyChanged) {
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, ly);
        _lastSentLY = ly;
    }
}

// --- Layout customizer ----------------------------------------------------
static NSString* SohIos_LayoutKey(NSString* label) {
    // CVar-safe keys for glyph labels
    if ([label isEqualToString:@"C\u2191"]) return @"CU";
    if ([label isEqualToString:@"C\u2193"]) return @"CD";
    if ([label isEqualToString:@"C\u2190"]) return @"CL";
    if ([label isEqualToString:@"C\u2192"]) return @"CR";
    if ([label isEqualToString:@"\u2261"])  return @"MENU";
    return label;
}

// Canonical layout reference: ALWAYS landscape-shaped (w = long side),
// regardless of the view's momentary orientation — early-boot portrait
// bounds scrambled normalized coords on device (feedback 2026-07-12).
- (CGSize)layoutRefSize {
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    return CGSizeMake(MAX(w, h), MIN(w, h));
}

- (void)loadLayoutFromCVars {
    if (!CVarGetInteger("gSohIos.Layout.Set", 0)) {
        return;
    }
    _layoutScale = CVarGetFloat("gSohIos.Layout.Scale", 1.0f);
    for (NSString* key in @[ @"A", @"B", @"CU", @"CD", @"CL", @"CR", @"Z", @"L", @"R", @"START", @"MENU" ]) {
        float x = CVarGetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.x", key].UTF8String, -1.0f);
        float y = CVarGetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.y", key].UTF8String, -1.0f);
        if (x >= 0 && y >= 0) {
            _layoutOverrides[key] = [NSValue valueWithCGPoint:CGPointMake(x, y)];
        }
        // MENU (≡) is never hideable (isButtonHidden exempts it), so a stale
        // MENU.hidden is simply not read back into the set.
        if (![key isEqualToString:@"MENU"] &&
            CVarGetInteger([NSString stringWithFormat:@"gSohIos.Layout.%@.hidden", key].UTF8String, 0)) {
            [_layoutHidden addObject:key];
        }
    }
    float sx = CVarGetFloat("gSohIos.Layout.Stick.x", -1.0f);
    float sy = CVarGetFloat("gSohIos.Layout.Stick.y", -1.0f);
    if (sx >= 0 && sy >= 0) {
        _stickHome = CGPointMake(sx, sy);
    }
}

- (void)saveLayoutToCVars {
    // Clear EVERYTHING first: stale per-button keys from earlier saves were
    // resurrecting on the next launch (device bug: deterministic jumble).
    CVarClearBlock("gSohIos.Layout");
    CVarSetInteger("gSohIos.Layout.Set", 1);
    CVarSetFloat("gSohIos.Layout.Scale", (float)_layoutScale);
    for (NSString* key in _layoutOverrides) {
        CGPoint n = [_layoutOverrides[key] CGPointValue];
        CVarSetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.x", key].UTF8String, (float)n.x);
        CVarSetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.y", key].UTF8String, (float)n.y);
    }
    // Hidden buttons are stored independently of position overrides — a user
    // can hide a button without ever dragging anything (positions stay default).
    for (NSString* key in _layoutHidden) {
        CVarSetInteger([NSString stringWithFormat:@"gSohIos.Layout.%@.hidden", key].UTF8String, 1);
    }
    if (!CGPointEqualToPoint(_stickHome, CGPointZero)) {
        CVarSetFloat("gSohIos.Layout.Stick.x", (float)_stickHome.x);
        CVarSetFloat("gSohIos.Layout.Stick.y", (float)_stickHome.y);
    }
    CVarSave();
}

- (CGPoint)stickHomePoint {
    CGRect b = self.bounds;
    if (CGPointEqualToPoint(_stickHome, CGPointZero)) {
        CGPoint def = CGPointMake(b.origin.x + 150, CGRectGetMaxY(b) - 170);
        return [self applyLefty:def];
    }
    CGSize ref = [self layoutRefSize];
    return [self applyLefty:CGPointMake(_stickHome.x * ref.width, _stickHome.y * ref.height)];
}

// Left-handed mirror (gSohIos.LeftyFlip): flips every X around the canonical
// width. Applied AFTER overrides so customized layouts mirror too.
- (CGPoint)applyLefty:(CGPoint)c {
    if (!CVarGetInteger("gSohIos.LeftyFlip", 0)) {
        return c;
    }
    return CGPointMake([self layoutRefSize].width - c.x, c.y);
}

#define kStickHaloR 150.0

- (CGRect)editChromeRect {
    // Bottom-LEFT per user preference (overlapping the stick halo is fine —
    // the chrome is hit-tested first, and the left side is the least
    // crowded place for customized buttons).
    CGRect b = self.bounds;
    return CGRectMake(b.origin.x + 16, CGRectGetMaxY(b) - 50, 330, 44);
}
- (CGPoint)editResetCenter {
    CGRect c = [self editChromeRect];
    return CGPointMake(CGRectGetMinX(c) + 26, CGRectGetMidY(c));
}
- (CGPoint)editSaveCenter {
    CGRect c = [self editChromeRect];
    return CGPointMake(CGRectGetMaxX(c) - 26, CGRectGetMidY(c));
}
- (CGRect)editSliderRect {
    CGRect c = [self editChromeRect];
    return CGRectMake(CGRectGetMinX(c) + 58, CGRectGetMidY(c) - 4, CGRectGetWidth(c) - 116, 8);
}

- (int)hitButtonForEdit:(CGPoint)pnt {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if (hypot(pnt.x - btns[i].center.x, pnt.y - btns[i].center.y) <= MAX(btns[i].radius * 1.35, 30)) {
            return i;
        }
    }
    return -1;
}

// --- Per-button hide/show badge (customizer only) --------------------------
// A small eye chip sits just OUTSIDE the button rim so the whole button body
// stays a drag handle (user constraint: the badge must not block moving a
// button around). It points away from the local cluster and is clamped
// on-screen, so edge buttons (R top-right, ≡ top-center) never push it off-
// screen. eye.slash = "tap to hide" on a visible button; eye = "tap to show"
// on a hidden one.
#define kHideBadgeR 14.0
- (CGPoint)hideBadgeCenterForCenter:(CGPoint)c radius:(CGFloat)r {
    CGRect b = self.bounds;
    // Direction: point the badge AWAY from the local cluster centroid so a
    // tight group (the C diamond) spreads its badges radially outward instead
    // of piling up on neighbors; for an isolated button (R/START) there's no
    // local cluster, so point toward screen interior. Clamped on-screen either
    // way, so edge buttons never push their badge off-screen.
    SohButton all[16];
    int an = 0;
    [self buttonRects:all count:&an];
    CGFloat sx = 0, sy = 0;
    int cnt = 0;
    for (int i = 0; i < an; i++) {
        CGFloat d = hypot(all[i].center.x - c.x, all[i].center.y - c.y);
        if (d > 1.0 && d < 150.0) {
            sx += all[i].center.x;
            sy += all[i].center.y;
            cnt++;
        }
    }
    CGFloat dirX, dirY;
    if (cnt > 0) {
        dirX = c.x - sx / cnt;
        dirY = c.y - sy / cnt;
        CGFloat nrm = hypot(dirX, dirY);
        if (nrm < 1.0) { // sits on the centroid: default up
            dirX = 0;
            dirY = -1;
        } else {
            dirX /= nrm;
            dirY /= nrm;
        }
    } else {
        dirX = (c.x > CGRectGetMidX(b)) ? -0.7071 : 0.7071;
        dirY = (c.y > CGRectGetMidY(b)) ? -0.7071 : 0.7071;
    }
    CGFloat off = r + kHideBadgeR - 2.0; // badge inner edge ~tangent to the rim
    CGPoint badge = CGPointMake(c.x + dirX * off, c.y + dirY * off);
    CGFloat m = kHideBadgeR + 4.0;
    badge.x = MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, badge.x));
    badge.y = MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, badge.y));
    return badge;
}

// Index of the button carrying a given layout key (-1 = none).
- (int)indexForLayoutKey:(NSString*)key {
    if (key == nil) {
        return -1;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([SohIos_LayoutKey(btns[i].label) isEqualToString:key]) {
            return i;
        }
    }
    return -1;
}

// The eye chip lives ONLY on the currently-selected button. Returns YES and
// (optionally) its center if the selected button has a chip pnt falls in.
- (BOOL)pointHitsSelectedChip:(CGPoint)pnt center:(CGPoint*)outChip {
    int i = [self indexForLayoutKey:_editSelected];
    if (i < 0) {
        return NO;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    if ([btns[i].label isEqualToString:@"≡"]) {
        return NO; // menu button has no chip (never hideable)
    }
    CGPoint chip = [self hideBadgeCenterForCenter:btns[i].center radius:btns[i].radius];
    if (outChip != NULL) {
        *outChip = chip;
    }
    return hypot(pnt.x - chip.x, pnt.y - chip.y) <= kHideBadgeR + 4.0;
}

- (void)drawHideBadgeAt:(CGPoint)c hidden:(BOOL)hidden {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect ring = CGRectMake(c.x - kHideBadgeR, c.y - kHideBadgeR, kHideBadgeR * 2, kHideBadgeR * 2);
    [[UIColor colorWithWhite:0.10 alpha:0.92] setFill];
    CGContextFillEllipseInRect(ctx, ring);
    [[UIColor colorWithWhite:1.0 alpha:0.85] setStroke];
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, ring);
    UIImageSymbolConfiguration* cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImage* img = [[UIImage systemImageNamed:(hidden ? @"eye.fill" : @"eye.slash.fill") withConfiguration:cfg]
        imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (img != nil) {
        [img drawInRect:CGRectMake(c.x - img.size.width / 2, c.y - img.size.height / 2, img.size.width,
                                   img.size.height)];
    } else {
        // Font fallback if SF Symbols is unavailable (should not happen on iOS 15+).
        [self drawGlyph:(hidden ? @"o" : @"x") at:c size:16 alpha:1.0];
    }
}

// Bridge gate probe (idb taps are unreliable on the sim — traps list). MAIN
// THREAD ONLY. Selection model: the eye chip shows ONLY on the last-touched
// (selected) button. Subcommands:
//   list          -> "edit=E sel=KEY|none <KEY:h<hidden>:hit<hitself>> ...
//                     selchip=x,y|none" (hitself must be 0 for a hidden button)
//   select KEY    -> drives the REAL editBegan at KEY's button center =
//                    touch-to-select; its chip appears, any prior one clears
//   chiptap       -> drives the REAL editBegan at the SELECTED button's chip;
//                    toggles hide, keeps selection, starts no drag
//   tapedit X Y   -> real editBegan at an arbitrary point (gates ↺/✓ chrome)
//   menutap       -> hitButton + applyButton at the ≡ center (touch route)
//   save          -> saveLayoutToCVars (what ✓ does)
- (NSString*)hideProbe:(NSArray<NSString*>*)a {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    NSString* sub = a.count >= 1 ? a[0].lowercaseString : @"list";
    // menutap: the touchesBegan route for a tap on the ≡ button's center --
    // hitButton (which applies the menuButtonVisible / Always-Show gate) then
    // applyButton down+up. "hit=none" means a real tap there would miss (D21
    // verification; idb ui tap is dead on the iOS 27 sim runtime).
    if ([sub isEqualToString:@"menutap"]) {
        for (int k = 0; k < n; k++) {
            if (![btns[k].label isEqualToString:@"≡"]) {
                continue;
            }
            int hit = [self hitButton:btns[k].center];
            if (hit < 0 || ![btns[hit].label isEqualToString:@"≡"]) {
                return @"ok hit=none";
            }
            [self applyButton:btns[hit].label down:YES];
            [self applyButton:btns[hit].label down:NO];
            return @"ok hit=menu";
        }
        return @"err no menu button";
    }
    if ([sub isEqualToString:@"select"] && a.count >= 2) {
        int i = [self indexForLayoutKey:a[1].uppercaseString];
        if (i < 0) {
            return @"err no such button";
        }
        [self editBegan:btns[i].center]; // real touch-to-select on the body
        NSString* dragWas = _editDrag ?: @"nil";
        [self editEnded];
        return [NSString stringWithFormat:@"ok sel=%@ editDragWas=%@", _editSelected ?: @"none", dragWas];
    }
    if ([sub isEqualToString:@"chiptap"]) {
        int i = [self indexForLayoutKey:_editSelected];
        if (i < 0) {
            return @"err nothing selected";
        }
        CGPoint chip = CGPointZero;
        BOOL onChip = [self pointHitsSelectedChip:btns[i].center center:&chip]; // center just to fetch chip
        (void)onChip;
        BOOL was = [self isButtonHidden:btns[i].label];
        NSString* selBefore = _editSelected;
        [self editBegan:chip]; // real chip tap
        NSString* dragAfter = _editDrag ?: @"nil"; // must be nil: a chip tap starts no drag
        BOOL now = [self isButtonHidden:btns[i].label];
        [self editEnded];
        return [NSString stringWithFormat:@"ok chiptap %@ %d->%d sel=%@ editDrag=%@",
                                          SohIos_LayoutKey(btns[i].label), was, now, _editSelected ?: @"none",
                                          [selBefore isEqualToString:_editSelected ?: @""] ? dragAfter
                                                                                           : @"SELCHANGED"];
    }
    if ([sub isEqualToString:@"save"]) {
        [self saveLayoutToCVars]; // exactly what the customizer's checkmark does
        return @"ok saved";
    }
    if ([sub isEqualToString:@"tapedit"] && a.count >= 3) {
        // Drive the REAL customizer touch entry at an arbitrary point — gates
        // the ↺ reset and ✓ save chrome (which live in editBegan) without
        // guessing at idb HID taps.
        [self editBegan:CGPointMake(a[1].floatValue, a[2].floatValue)];
        NSString* drag = _editDrag ?: @"nil";
        [self editEnded];
        return [NSString stringWithFormat:@"ok tapedit editMode=%d editDrag=%@", _editMode, drag];
    }
    int seli = [self indexForLayoutKey:_editSelected];
    NSMutableString* s = [NSMutableString stringWithFormat:@"ok edit=%d sel=%@", _editMode, _editSelected ?: @"none"];
    for (int i = 0; i < n; i++) {
        [s appendFormat:@" %@:h%d:hit%d", SohIos_LayoutKey(btns[i].label), [self isButtonHidden:btns[i].label],
                        [self hitButton:btns[i].center] == i];
    }
    if (seli >= 0 && ![btns[seli].label isEqualToString:@"≡"]) {
        CGPoint chip = [self hideBadgeCenterForCenter:btns[seli].center radius:btns[seli].radius];
        [s appendFormat:@" selchip=%.0f,%.0f", chip.x, chip.y];
    } else {
        [s appendString:@" selchip=none"];
    }
    return s;
}

- (void)editBegan:(CGPoint)pnt {
    CGPoint reset = [self editResetCenter], save = [self editSaveCenter];
    CGRect slider = CGRectInset([self editSliderRect], -12, -18);
    if (hypot(pnt.x - reset.x, pnt.y - reset.y) <= 26) {
        [_layoutOverrides removeAllObjects];
        [_layoutHidden removeAllObjects]; // reset restores every button to visible
        _layoutScale = 1.0;
        _stickHome = CGPointZero;
        [self setNeedsDisplay];
        return;
    }
    if (hypot(pnt.x - save.x, pnt.y - save.y) <= 26) {
        [self saveLayoutToCVars];
        _editMode = NO;
        _editDrag = nil;
        [self setNeedsDisplay];
        return;
    }
    if (CGRectContainsPoint(slider, pnt)) {
        _editDrag = @"__slider";
        [self editMoved:pnt];
        return;
    }
    // Eye chip (only on the selected button) is checked BEFORE the button-body
    // drag: tapping it toggles visibility, keeps the selection, and never
    // starts a drag. The chip sits outside the rim, so the body stays a drag
    // handle.
    if ([self pointHitsSelectedChip:pnt center:NULL]) {
        int i = [self indexForLayoutKey:_editSelected];
        SohButton bb[16];
        int bn = 0;
        [self buttonRects:bb count:&bn];
        if (i >= 0) {
            [self toggleHiddenForLabel:bb[i].label];
        }
        return;
    }
    // Touching a button SELECTS it (its eye chip appears; any prior selection's
    // chip disappears) and begins a drag.
    int idx = [self hitButtonForEdit:pnt];
    if (idx >= 0) {
        SohButton btns[16];
        int n = 0;
        [self buttonRects:btns count:&n];
        _editSelected = SohIos_LayoutKey(btns[idx].label);
        _editDrag = _editSelected;
        [self setNeedsDisplay];
        return;
    }
    CGPoint home = [self stickHomePoint];
    if (hypot(pnt.x - home.x, pnt.y - home.y) <= kStickHaloR) {
        _editDrag = @"__stick";
    }
}

- (void)editMoved:(CGPoint)pnt {
    CGRect b = self.bounds;
    if (_editDrag == nil) {
        return;
    }
    if ([_editDrag isEqualToString:@"__slider"]) {
        CGRect s = [self editSliderRect];
        CGFloat frac = MAX(0.0, MIN(1.0, (pnt.x - CGRectGetMinX(s)) / CGRectGetWidth(s)));
        _layoutScale = 0.7 + frac * (1.4 - 0.7);
        [self setNeedsDisplay];
        return;
    }
    CGFloat m = 30;
    CGPoint clamped = CGPointMake(MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, pnt.x)),
                                  MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, pnt.y)));
    // un-mirror before storing so lefty users edit in their own view
    clamped = [self applyLefty:clamped];
    CGSize ref = [self layoutRefSize];
    CGPoint normalized = CGPointMake(clamped.x / ref.width, clamped.y / ref.height);
    if ([_editDrag isEqualToString:@"__stick"]) {
        _stickHome = normalized;
    } else {
        _layoutOverrides[_editDrag] = [NSValue valueWithCGPoint:normalized];
    }
    [self setNeedsDisplay];
}

- (void)editEnded {
    _editDrag = nil;
}
// ----------------------------------------------------------------------------

// The stick is FLOATING: hidden until a touch lands inside its spawn halo
// (customizable home), then its base is wherever the finger came down.
- (BOOL)pointInStickRegion:(CGPoint)p {
    CGPoint home = [self stickHomePoint];
    if (hypot(p.x - home.x, p.y - home.y) > kStickHaloR) {
        return NO;
    }
    // Z protection (device feedback): a halo around Z never spawns the
    // stick — a missed Z tap is a dead tap, not a surprise stick. Skipped
    // when Z is hidden (no button there = no dead zone).
    if (![self isButtonHidden:@"Z"]) {
        CGPoint zC = [self zButtonCenter];
        if (hypot(p.x - zC.x, p.y - zC.y) <= (34 * 1.35 + 26) * _layoutScale) {
            return NO;
        }
    }
    return YES;
}

- (CGPoint)clampStickBase:(CGPoint)p {
    CGRect b = self.bounds;
    CGFloat m = _stickBaseR + 14; // keep the drawn ring on-screen
    return CGPointMake(MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, p.x)),
                       MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, p.y)));
}

- (NSArray<NSValue*>*)buttonRects:(SohButton*)outButtons count:(int*)outCount {
    CGRect b = self.bounds;
    CGFloat maxX = CGRectGetMaxX(b), maxY = CGRectGetMaxY(b);
    UIColor* cYellow = [UIColor colorWithRed:0.95 green:0.80 blue:0.15 alpha:0.55];
    UIColor* cBlue = [UIColor colorWithRed:0.20 green:0.45 blue:0.95 alpha:0.6];
    UIColor* cGreen = [UIColor colorWithRed:0.20 green:0.75 blue:0.35 alpha:0.6];
    UIColor* cGray = [UIColor colorWithWhite:0.6 alpha:0.55];
    UIColor* cRed = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:0.6];
    // A/B primary cluster, bottom-right corner (v2: -20% radii per device
    // feel; program-wide UNIFIED layout 2026-07-21 addendum C: cluster up
    // ~20pt off the very corner — Ghostship device-tuned, user wants identical
    // defaults across every HM port).
    CGFloat aX = maxX - 85, aY = maxY - 105;
    // C-button diamond, above the A/B cluster (kept fully on-screen).
    CGFloat cX = maxX - 105, cY = maxY - 235;
    SohButton btns[] = {
        { CGPointMake(aX, aY), 37, cBlue, @"A" },
        { CGPointMake(aX - 92, aY - 18), 32, cGreen, @"B" }, // a hair down toward Z (unified layout)
        { CGPointMake(cX, cY - 38), 27, cYellow, @"C↑" },
        { CGPointMake(cX, cY + 38), 27, cYellow, @"C↓" },
        { CGPointMake(cX - 40, cY), 27, cYellow, @"C←" },
        { CGPointMake(cX + 40, cY), 27, cYellow, @"C→" },
        // Z below A/B, EQUIDISTANT from both (UNIFIED layout 2026-07-21,
        // Ghostship device-tuned): aX-68, thumb-reachable beside jump/attack
        // (enables the Z→A slide long-jump class), clear of the iOS
        // edge-gesture zones that ate the old upper-left spot (stuck-Z story).
        { CGPointMake(aX - 68, maxY - 42), 34, cGray, @"Z" },
        // No L chip: SF64 binds no N64 L button (Starship default mappings).
        { CGPointMake(maxX - 80, b.origin.y + 60), 34, cGray, @"R" },
        // START and ≡ swapped per device feedback: START bottom-center,
        // menu button top-center (visible only in intro/pause contexts).
        { CGPointMake(CGRectGetMidX(b), maxY - 45), 30, cRed, @"START" },
        { CGPointMake(CGRectGetMidX(b), b.origin.y + 55), 26, cGray, @"≡" },
    };
    int n = (int)(sizeof(btns) / sizeof(btns[0]));
    for (int i = 0; i < n; i++) {
        // Customized layout: per-button normalized centers (canonical
        // landscape reference) + lefty mirror + global scale.
        NSValue* ov = _layoutOverrides[SohIos_LayoutKey(btns[i].label)];
        if (ov != nil) {
            CGPoint nrm = [ov CGPointValue];
            CGSize ref = [self layoutRefSize];
            btns[i].center = CGPointMake(nrm.x * ref.width, nrm.y * ref.height);
        }
        btns[i].center = [self applyLefty:btns[i].center];
        btns[i].radius *= _layoutScale;
        outButtons[i] = btns[i];
    }
    *outCount = n;
    return nil;
}

- (void)drawGlyph:(NSString*)glyph at:(CGPoint)c size:(CGFloat)fontSize alpha:(CGFloat)alpha {
    NSDictionary* attrs = @{
        NSFontAttributeName : [UIFont boldSystemFontOfSize:fontSize],
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1 alpha:alpha]
    };
    CGSize sz = [glyph sizeWithAttributes:attrs];
    [glyph drawAtPoint:CGPointMake(c.x - sz.width / 2, c.y - sz.height / 2) withAttributes:attrs];
}

// D28: every repaint request reaches the canvases (the old full-view
// redraw), and the stick layers follow the same state. Nothing else.
- (void)setNeedsDisplay {
    [_canvas setNeedsDisplay];
    [self sohLayoutZCanvas];
    [_zCanvas setNeedsDisplay];
    [self syncStickLayers];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self sohLayoutZCanvas];
    [self syncStickLayers];
}

// The Z canvas covers the Z button (+ stroke/AA margin) at an integral point
// origin, so its pixels land exactly where the full canvas put them.
- (void)sohLayoutZCanvas {
    if (_zCanvas == nil) {
        return;
    }
    CGRect f = CGRectZero;
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"Z"]) {
            CGFloat r = btns[i].radius + 4;
            f = CGRectIntegral(CGRectMake(btns[i].center.x - r, btns[i].center.y - r, r * 2, r * 2));
            break;
        }
    }
    if (!CGRectEqualToRect(f, _zCanvas.frame)) {
        _zCanvas.frame = f;
        [_zCanvas setNeedsDisplay];
    }
}

// Floating stick: position-only updates, no implicit animation, no redraw.
// Visible exactly when the old drawRect drew it.
- (void)syncStickLayers {
    if (_ringLayer == nil) {
        return;
    }
    BOOL show = _stickActive && !_editMode && !_popupOpen && !_controlsHidden && !_controllerMode;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _ringLayer.hidden = !show;
    _knobLayer.hidden = !show;
    if (show) {
        CGFloat scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 3.0;
        if (_ringLayer.contentsScale != scale) {
            _ringLayer.contentsScale = scale;
            _knobLayer.contentsScale = scale;
        }
        CGFloat ringR = (_stickBaseR + 8) * _layoutScale;
        if (ringR != _ringLayerR) {
            _ringLayerR = ringR;
            CGRect b = CGRectMake(0, 0, ringR * 2, ringR * 2);
            _ringLayer.bounds = b;
            CGPathRef path = CGPathCreateWithEllipseInRect(b, NULL);
            _ringLayer.path = path;
            CGPathRelease(path);
        }
        CGFloat knobR = _stickKnobR * _layoutScale;
        if (knobR != _knobLayerR) {
            _knobLayerR = knobR;
            CGRect b = CGRectMake(0, 0, knobR * 2, knobR * 2);
            _knobLayer.bounds = b;
            CGPathRef path = CGPathCreateWithEllipseInRect(b, NULL);
            _knobLayer.path = path;
            CGPathRelease(path);
        }
        _ringLayer.position = _stickBase;
        _knobLayer.position = _stickKnob;
    }
    [CATransaction commit];
}

// One gameplay-mode button, exactly as the single drawRect drew it.
- (void)sohDrawButton:(SohButton)bt ctx:(CGContextRef)ctx {
    BOOL isZ = [bt.label isEqualToString:@"Z"];
    if (isZ && _zLocked) {
        // Double-tap lock engaged: unmistakably "on".
        [[UIColor colorWithRed:0.30 green:0.60 blue:1.0 alpha:0.9] setFill];
        [[UIColor colorWithWhite:1 alpha:0.95] setStroke];
    } else if (isZ && _zHeld) {
        // Momentary hold: clearly active, dimmer than the lock.
        [[UIColor colorWithRed:0.25 green:0.45 blue:0.8 alpha:0.7] setFill];
        [[UIColor colorWithWhite:1 alpha:0.7] setStroke];
    } else {
        [bt.color setFill];
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
    }
    CGRect r = CGRectMake(bt.center.x - bt.radius, bt.center.y - bt.radius, bt.radius * 2, bt.radius * 2);
    CGContextSetLineWidth(ctx, isZ && _zLocked ? 4 : 3);
    CGContextFillEllipseInRect(ctx, r);
    CGContextStrokeEllipseInRect(ctx, r);
    BOOL labeled = isZ || [bt.label isEqualToString:@"R"] ||
                   [bt.label isEqualToString:@"≡"];
    if (labeled) {
        [self drawGlyph:bt.label at:bt.center size:20 alpha:0.95];
    }
}

- (void)sohDrawCanvasRole:(int)role inView:(UIView*)view {
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    if (role == 1) {
        // The Z button alone, in overlay coordinates (the canvas sits at an
        // integral origin). Only in plain gameplay mode; every other mode is
        // drawn whole by role 0.
        if (_editMode || _popupOpen || _controlsHidden || _controllerMode || [self isButtonHidden:@"Z"]) {
            return;
        }
        CGContextTranslateCTM(ctx, -view.frame.origin.x, -view.frame.origin.y);
        SohButton zb[16];
        int zn = 0;
        [self buttonRects:zb count:&zn];
        for (int i = 0; i < zn; i++) {
            if ([zb[i].label isEqualToString:@"Z"]) {
                [self sohDrawButton:zb[i] ctx:ctx];
            }
        }
        return;
    }

    if (_editMode) {
        // --- Customizer: everything visible and draggable ---
        // Stick spawn halo (moves with its home).
        CGPoint home = [self stickHomePoint];
        [[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.16] setFill];
        CGContextFillEllipseInRect(
            ctx, CGRectMake(home.x - kStickHaloR, home.y - kStickHaloR, kStickHaloR * 2, kStickHaloR * 2));
        [[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.5] setStroke];
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(
            ctx, CGRectMake(home.x - kStickHaloR, home.y - kStickHaloR, kStickHaloR * 2, kStickHaloR * 2));
        CGFloat ringR = (_stickBaseR + 8) * _layoutScale;
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
        CGContextSetLineWidth(ctx, 4);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(home.x - ringR, home.y - ringR, ringR * 2, ringR * 2));
        [[UIColor colorWithWhite:1 alpha:0.35] setFill];
        CGFloat knobR = _stickKnobR * _layoutScale;
        CGContextFillEllipseInRect(ctx, CGRectMake(home.x - knobR, home.y - knobR, knobR * 2, knobR * 2));

        // All buttons at their (possibly overridden) spots. Hidden buttons are
        // ghosted (low opacity) so the user still sees them to reposition or
        // un-hide. The eye chip appears on the SELECTED button ONLY (the last
        // one touched) — no chip at all until the user touches a button.
        SohButton ebtns[16];
        int en = 0;
        [self buttonRects:ebtns count:&en];
        for (int i = 0; i < en; i++) {
            SohButton bt = ebtns[i];
            BOOL hidden = [self isButtonHidden:bt.label];
            BOOL selected = (_editSelected != nil && [_editSelected isEqualToString:SohIos_LayoutKey(bt.label)]);
            CGFloat fillA = hidden ? 0.22 : 1.0, strokeA = hidden ? 0.28 : 0.7, glyphA = hidden ? 0.35 : 0.95;
            [[bt.color colorWithAlphaComponent:CGColorGetAlpha(bt.color.CGColor) * fillA] setFill];
            [[UIColor colorWithWhite:1 alpha:(selected ? 1.0 : strokeA)] setStroke];
            CGRect r = CGRectMake(bt.center.x - bt.radius, bt.center.y - bt.radius, bt.radius * 2, bt.radius * 2);
            CGContextSetLineWidth(ctx, selected ? 3 : 2); // selected button: brighter ring
            CGContextFillEllipseInRect(ctx, r);
            CGContextStrokeEllipseInRect(ctx, r);
            [self drawGlyph:bt.label at:bt.center size:16 * _layoutScale alpha:glyphA];
            if (selected && ![bt.label isEqualToString:@"≡"]) {
                [self drawHideBadgeAt:[self hideBadgeCenterForCenter:bt.center radius:bt.radius] hidden:hidden];
            }
        }

        // Chrome strip: [reset][scale slider][save]
        CGRect chrome = [self editChromeRect];
        [[UIColor colorWithWhite:0 alpha:0.55] setFill];
        UIBezierPath* rounded = [UIBezierPath bezierPathWithRoundedRect:chrome cornerRadius:14];
        [rounded fill];
        CGPoint reset = [self editResetCenter];
        [[UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.9] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(reset.x - 20, reset.y - 20, 40, 40));
        [self drawGlyph:@"\u21ba" at:reset size:22 alpha:1.0];
        CGPoint save = [self editSaveCenter];
        [[UIColor colorWithRed:0.2 green:0.7 blue:0.35 alpha:0.95] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(save.x - 20, save.y - 20, 40, 40));
        [self drawGlyph:@"\u2713" at:save size:22 alpha:1.0];
        CGRect s = [self editSliderRect];
        [[UIColor colorWithWhite:1 alpha:0.3] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:s cornerRadius:4] fill];
        CGFloat frac = (_layoutScale - 0.7) / (1.4 - 0.7);
        CGFloat thumbX = CGRectGetMinX(s) + frac * CGRectGetWidth(s);
        [[UIColor whiteColor] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(thumbX - 10, CGRectGetMidY(s) - 10, 20, 20));
        NSString* pct = [NSString stringWithFormat:@"%d%%", (int)round(_layoutScale * 100)];
        [self drawGlyph:pct at:CGPointMake(CGRectGetMidX(chrome), CGRectGetMinY(chrome) - 12) size:13 alpha:0.9];
        return;
    }

    if (_popupOpen) {
        return; // a popup owns the screen: draw nothing at all
    }

    if (_controlsHidden) {
        // Menu is open: draw only the small restore dot.
        CGPoint dot = [self restoreDotCenter];
        [[UIColor colorWithWhite:1 alpha:0.25] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(dot.x - 22, dot.y - 22, 44, 44));
        [self drawGlyph:@"≡" at:dot size:18 alpha:0.8];
        return;
    }

    if (_controllerMode) {
        // Physical controller drives the game: no touch controls. The ≡
        // button follows the same visibility policy as touch (intro/title
        // and pause only), keeping the SoH menu reachable without clutter.
        if ([self menuButtonVisible]) {
            SohButton btns[16];
            int n = 0;
            [self buttonRects:btns count:&n];
            SohButton menuBtn = btns[n - 1]; // ≡ is last
            [menuBtn.color setFill];
            CGRect r = CGRectMake(menuBtn.center.x - menuBtn.radius, menuBtn.center.y - menuBtn.radius,
                                  menuBtn.radius * 2, menuBtn.radius * 2);
            CGContextFillEllipseInRect(ctx, r);
            [self drawGlyph:@"≡" at:menuBtn.center size:20 alpha:0.95];
        }
        return;
    }

    // Floating left stick: _stickView's layers (syncStickLayers), not here.

    // Buttons. Labels only where the glyph isn't obvious (R/Z + ≡). Z is
    // drawn by its own canvas (role 1) so a press repaints only that.
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    BOOL menuBtnVisible = [self menuButtonVisible];
    for (int i = 0; i < n; i++) {
        SohButton bt = btns[i];
        if ([bt.label isEqualToString:@"Z"]) {
            continue; // role 1
        }
        if ([bt.label isEqualToString:@"≡"] && !menuBtnVisible) {
            continue; // hidden during normal gameplay
        }
        if ([self isButtonHidden:bt.label]) {
            continue; // user-hidden from the touch layer (customizer)
        }
        [self sohDrawButton:bt ctx:ctx];
    }
}

// Pass-through: only the stick zone and button circles intercept touches;
// everywhere else falls through to SDL's view (game taps, ImGui menu).
// While hidden (menu open), ONLY the restore dot intercepts.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    if (_editMode) {
        return YES; // customizer owns the screen
    }
    if (_popupOpen) {
        return NO; // popup owns all input (extractor Yes/No etc.)
    }
    if (_controlsHidden) {
        return YES; // menu open: the touch-router owns every touch
    }
    if (_controllerMode) {
        // Only the ≡ button (and only when visible per policy) is touch-active.
        if (![self menuButtonVisible]) {
            return NO;
        }
        SohButton btns[16];
        int n = 0;
        [self buttonRects:btns count:&n];
        SohButton menuBtn = btns[n - 1];
        return hypot(point.x - menuBtn.center.x, point.y - menuBtn.center.y) <= menuBtn.radius * 1.35;
    }
    if ([self hitButton:point] >= 0) {
        return YES;
    }
    return [self pointInStickRegion:point]; // floating stick spawns anywhere here
}

// --- Menu touch-router -------------------------------------------------
// While the SoH menu is open the overlay owns every touch and forwards
// SYNTHESIZED mouse events, because raw touch-as-mouse reads as hover
// (tooltips) and can never scroll. Taps click; vertical drags scroll
// (wheel); horizontal drags press-and-drag (sliders); a 450 ms hold
// hovers (tooltip), cleared on release.
- (void)routerReset {
    _routerTouch = nil;
    _routerMode = 0;
}

- (void)routerBegan:(UITouch*)t {
    if (_routerTouch != nil) {
        return; // single-touch menu interaction
    }
    _routerTouch = t;
    _routerMode = 0;
    _routerStart = _routerLast = [t locationInView:self];
    const void* captured = (__bridge const void*)t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ((__bridge const void*)self->_routerTouch == captured && self->_routerMode == 0 && self->_controlsHidden) {
            self->_routerMode = 3; // hover: tooltip appears under the held finger
            SohIos_InjectMouseMotion((int)self->_routerStart.x, (int)self->_routerStart.y);
        }
    });
}

- (void)routerMoved:(UITouch*)t {
    if (t != _routerTouch) {
        return;
    }
    CGPoint pnt = [t locationInView:self];
    if (_routerMode == 0) {
        CGFloat dx = pnt.x - _routerStart.x, dy = pnt.y - _routerStart.y;
        if (hypot(dx, dy) > 8.0) {
            if (fabs(dy) > fabs(dx) * 1.15) {
                _routerMode = 1; // scroll: mouse-free (no hover -> no tooltips/slider side-effects)
            } else {
                _routerMode = 2; // drag: real press for sliders/scrollbars
                SohIos_InjectMouseMotion((int)_routerStart.x, (int)_routerStart.y);
                SohIos_InjectMouseButton((int)_routerStart.x, (int)_routerStart.y, YES);
            }
        }
    }
    if (_routerMode == 1) {
        CGFloat dy = pnt.y - _routerLast.y;
        if (fabs(dy) >= 1.0) {
            SohIos_QueueMenuScroll((float)pnt.x, (float)dy);
            _routerLast = pnt;
        }
    } else if (_routerMode == 2) {
        SohIos_InjectMouseMotion((int)pnt.x, (int)pnt.y);
        _routerLast = pnt;
    }
}

- (void)routerEnded:(UITouch*)t cancelled:(BOOL)cancelled {
    if (t != _routerTouch) {
        return;
    }
    CGPoint pnt = [t locationInView:self];
    if (_routerMode == 2) {
        SohIos_InjectMouseButton((int)pnt.x, (int)pnt.y, NO);
    } else if (_routerMode == 3) {
        // clear the hover so the tooltip dismisses
        SohIos_InjectMouseMotion((int)self.bounds.size.width - 2, (int)self.bounds.size.height - 2);
    } else if (_routerMode == 0 && !cancelled) {
        CGPoint dot = [self restoreDotCenter];
        if (hypot(pnt.x - dot.x, pnt.y - dot.y) <= 34) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); // restore dot: close menu
            _controlsHidden = NO;
            [self setNeedsDisplay];
        } else {
            SohIos_InjectClick((int)pnt.x, (int)pnt.y);
        }
    }
    [self routerReset];
}
// ------------------------------------------------------------------------

// Floating-stick core, shared by the real touch handlers and the bridge's
// synthetic `stickspin` finger (perf round 2026-10-09 instrument, = SoH
// D-088's stickspin), so a synthetic drag exercises exactly the real path.
- (void)sohStickBeganAt:(CGPoint)p {
    _stickActive = YES;
    _stickBase = [self clampStickBase:p];
    _stickKnob = _stickBase;
    [self updateStickAxesFromKnob];
    [self syncStickLayers]; // D28: no repaint
}

- (void)sohStickMovedTo:(CGPoint)p {
    CGFloat dx = p.x - _stickBase.x, dy = p.y - _stickBase.y;
    CGFloat d = hypot(dx, dy);
    if (d > _stickBaseR) {
        dx = dx / d * _stickBaseR;
        dy = dy / d * _stickBaseR;
    }
    CGPoint knob = CGPointMake(_stickBase.x + dx, _stickBase.y + dy);
    if (hypot(knob.x - _stickKnob.x, knob.y - _stickKnob.y) < 1.0) {
        return; // sub-point jitter: no axis send, no redraw
    }
    _stickKnob = knob;
    [self updateStickAxesFromKnob];
    [self syncStickLayers]; // D28: move the knob layer; no repaint
}

- (void)sohStickEnded {
    _stickActive = NO;
    _stickTouch = nil;
    _stickKnob = _stickBase;
    _lastSentLX = _lastSentLY = 0;
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
    [self syncStickLayers]; // D28
}

// Bridge perf instruments (MAIN THREAD). Returns the reply line.
//   spin CX CY R SECS [RPS]  synthetic finger lands at (CX,CY) in the stick
//                            zone, circles at radius R points, RPS turns/s
//                            (0 = hold deflected right), moved at 120 Hz,
//                            lifted after SECS
//   zpress MS                hold the touch Z button for MS (repaint path)
//   shot NAME                the overlay ALONE (its view hierarchy, as
//                            displayed) -> Documents/NAME.png, transparent
- (NSString*)perfProbe:(NSArray<NSString*>*)a {
    NSString* sub = a.count ? a[0] : @"";
    if ([sub isEqualToString:@"spin"] && a.count >= 5) {
        if (_stickActive || _editMode || _controlsHidden || _controllerMode || _popupOpen) {
            return @"err stick busy or touch layer inactive";
        }
        CGPoint c = CGPointMake(a[1].floatValue, a[2].floatValue);
        if (c.x < 0 || c.y < 0) {
            c = [self stickHomePoint]; // CX/CY -1 = the stick's home point
        }
        CGFloat r = a[3].floatValue;
        double secs = a[4].doubleValue;
        double rps = a.count >= 6 ? a[5].doubleValue : 1.0;
        if (![self pointInStickRegion:c]) {
            return @"err not in stick region";
        }
        [self sohStickBeganAt:c];
        CFTimeInterval t0 = CACurrentMediaTime();
        __block dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_t spin = timer;
        __weak SohIosTouchOverlay* weakSelf = self;
        dispatch_source_set_timer(spin, DISPATCH_TIME_NOW, NSEC_PER_SEC / 120, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(spin, ^{
            SohIosTouchOverlay* s = weakSelf;
            double el = CACurrentMediaTime() - t0;
            if (s == nil || el >= secs || !s->_stickActive) {
                if (s != nil && s->_stickActive && s->_stickTouch == nil) {
                    [s sohStickEnded];
                }
                dispatch_source_cancel(timer);
                timer = nil; // breaks the block <-> source retain cycle
                return;
            }
            double ang = 2.0 * M_PI * rps * el;
            [s sohStickMovedTo:CGPointMake(c.x + r * cos(ang), c.y + r * sin(ang))];
        });
        dispatch_resume(spin);
        return [NSString stringWithFormat:@"ok spin base=%.0f,%.0f r=%.0f secs=%.1f rps=%.2f", _stickBase.x,
                                          _stickBase.y, r, secs, rps];
    }
    if ([sub isEqualToString:@"zpress"]) {
        int ms = a.count >= 2 ? a[1].intValue : 500;
        [self applyButton:@"Z" down:YES];
        __weak SohIosTouchOverlay* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(),
                       ^{ [weakSelf applyButton:@"Z" down:NO]; });
        return [NSString stringWithFormat:@"ok zpress %d", ms];
    }
    if ([sub isEqualToString:@"shot"] && a.count >= 2) {
        UIGraphicsImageRendererFormat* fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.opaque = NO;
        UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithSize:self.bounds.size format:fmt];
        NSData* png = [r PNGDataWithActions:^(UIGraphicsImageRendererContext* ctx) {
            [self drawViewHierarchyInRect:self.bounds afterScreenUpdates:YES];
        }];
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* path = [docs stringByAppendingPathComponent:[a[1] stringByAppendingString:@".png"]];
        return [png writeToFile:path atomically:YES]
                   ? [NSString stringWithFormat:@"ok %@ %.0fx%.0f@%.0f", path, self.bounds.size.width,
                                                self.bounds.size.height, fmt.scale]
                   : @"err write";
    }
    return @"err perf spin CX CY R SECS [RPS] | zpress MS | shot NAME";
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        for (UITouch* t in touches) {
            [self editBegan:[t locationInView:self]];
            break;
        }
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerBegan:t];
        }
        return;
    }
    if (_controllerMode) {
        // pointInside already vetted this as a paused-state ≡ tap.
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        _controlsHidden = YES;
        [self setNeedsDisplay];
        return;
    }
    for (UITouch* t in touches) {
        CGPoint p = [t locationInView:self];
        int idx = [self hitButton:p];
        if (idx >= 0) {
            _touchButtons[[NSValue valueWithPointer:(__bridge const void*)t]] = @(idx);
            SohButton btns[16];
            int n = 0;
            [self buttonRects:btns count:&n];
            [self hapticTap];
            [self applyButton:btns[idx].label down:YES];
        } else if (!_stickActive && [self pointInStickRegion:p]) {
            // Floating stick: base is where the finger landed.
            [self hapticTap];
            _stickTouch = t;
            [self sohStickBeganAt:p];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        for (UITouch* t in touches) {
            [self editMoved:[t locationInView:self]];
            break;
        }
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerMoved:t];
        }
        return;
    }
    // Button slide-across (SYNC WAVE 2 addendum C, Ghostship device-confirmed):
    // a finger that slides from one button onto a DIFFERENT one transfers the
    // press (release old, press new) — the Z→A slide long-jump / B→A dive class
    // consoles always had. Sliding through the GAP between buttons KEEPS the
    // current button held, so Z stays down until the finger reaches A. Never
    // stores -1 (empty space leaves the binding untouched); updates
    // _touchButtons BEFORE applyButton so the C-recompute sees the post state.
    if (_touchButtons.count > 0) {
        SohButton sbtns[16];
        int sn = 0;
        [self buttonRects:sbtns count:&sn];
        for (UITouch* t in touches) {
            NSValue* key = [NSValue valueWithPointer:(__bridge const void*)t];
            NSNumber* boundIdx = _touchButtons[key];
            if (boundIdx == nil) {
                continue; // stick touch — handled below
            }
            int boundI = boundIdx.intValue;
            int nowIdx = [self hitButton:[t locationInView:self]];
            if (nowIdx >= 0 && nowIdx != boundI) {
                _touchButtons[key] = @(nowIdx);
                if (boundI >= 0 && boundI < sn) {
                    [self applyButton:sbtns[boundI].label down:NO];
                }
                [self applyButton:sbtns[nowIdx].label down:YES];
            }
        }
    }
    if (!_stickActive) {
        return;
    }
    for (UITouch* t in touches) {
        if (t != _stickTouch) {
            continue;
        }
        [self sohStickMovedTo:[t locationInView:self]];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        [self editEnded];
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerEnded:t cancelled:NO];
        }
        return;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (UITouch* t in touches) {
        NSValue* key = [NSValue valueWithPointer:(__bridge const void*)t];
        NSNumber* idx = _touchButtons[key];
        if (idx != nil) {
            [_touchButtons removeObjectForKey:key];
            [self applyButton:btns[idx.intValue].label down:NO];
        }
        if (t == _stickTouch) {
            [self sohStickEnded];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        [self editEnded];
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerEnded:t cancelled:YES];
        }
        return;
    }
    [self touchesEnded:touches withEvent:event];
}
@end

static UIWindow* SohIos_GetSDLWindow(struct SDL_Window* sdlWindow) {
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(sdlWindow, &wm) || wm.subsystem != SDL_SYSWM_UIKIT) {
        return nil;
    }
    return wm.info.uikit.window;
}

static UIWindowScene* SohIos_ActiveScene(void) {
    UIWindowScene* fallback = gSohConnectedScene;
    for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        if (s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene*)s;
        }
        fallback = (UIWindowScene*)s;
    }
    return fallback;
}

// D31: the first-run O2R prompt runs before SDL has a window. SDL's message
// box builds a UIWindow from UIScreen bounds and never sets windowScene, so
// once the app adopts scenes (iOS 27 SDK, D22) that window is not on screen.
// LiveContainer makes the same miss permanent: it only auto-attaches
// scene-less windows for apps whose delegate has NOT adopted scenes, and
// this app has. Present on the connected scene, sized to the scene's bounds
// (a portrait-sized window on a landscape scene clips the alert off to the
// corner — SpaghettiKart D18). A portrait scene is asked to rotate, then we
// present into whatever bounds it actually has.
static BOOL SohIos_SceneIsLandscape(UIWindowScene* scene) {
    if (scene == nil) {
        return NO;
    }
    CGSize s = scene.coordinateSpace.bounds.size;
    return s.width > s.height + 1.0;
}

static void SohIos_FitModalWindow(UIWindow* window, const char* why) {
    if (window == nil) {
        return;
    }
    UIWindowScene* scene = window.windowScene ?: SohIos_ActiveScene();
    if (scene == nil) {
        return;
    }
    if (window.windowScene != scene) {
        window.windowScene = scene;
    }
    CGRect sb = scene.coordinateSpace.bounds;
    if (sb.size.width < 2 || sb.size.height < 2) {
        return;
    }
    UIView* root = window.rootViewController.view;
    BOOL stale = !CGRectEqualToRect(window.frame, sb) ||
                 (root != nil && !CGSizeEqualToSize(root.bounds.size, window.bounds.size));
    if (!stale) {
        return;
    }
    NSLog(@"[SohIosShell] onboarding fit (%s): window %.0fx%.0f -> scene %.0fx%.0f orient %ld", why,
          window.frame.size.width, window.frame.size.height, sb.size.width, sb.size.height,
          (long)scene.interfaceOrientation);
    window.frame = sb;
    if (root != nil) {
        root.frame = window.bounds;
        [root setNeedsLayout];
        [root layoutIfNeeded];
    }
}

static UIWindow* SohIos_MakeOnboardingWindow(void) {
    UIWindowScene* scene = nil;
    for (int i = 0; i < 30 && scene == nil; i++) {
        scene = SohIos_ActiveScene();
        if (scene != nil) {
            break;
        }
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    UIWindow* w = nil;
    if (scene != nil) {
        w = [[UIWindow alloc] initWithWindowScene:scene];
    }
    if (w == nil) {
#if TARGET_OS_VISION
        // UIScreen does not exist on visionOS. The first-run prompts do not
        // use this window there; a missing scene has nothing to present on.
        NSLog(@"[SohIosShell] onboarding: no window scene after 3s");
        return nil;
#else
        w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        NSLog(@"[SohIosShell] onboarding: no window scene after 3s; alert window is scene-less");
#endif
    }
    w.rootViewController = [UIViewController new];
    // Above every window already in the scene. UIWindowLevelAlert is enough
    // for a normal install (the SDL launch window is Normal+1) but inside
    // LiveContainer the host's own windows can sit higher — its alerts use
    // lastWindow.windowLevel+1 for the same reason. A prompt under that
    // chrome is the black screen again.
    CGFloat level = UIWindowLevelAlert;
    for (UIWindow* other in UIApplication.sharedApplication.windows) {
        if (other != w && other.windowLevel >= level) {
            level = other.windowLevel + 1;
        }
    }
    w.windowLevel = level;
    [w makeKeyAndVisible];
    [w.rootViewController loadViewIfNeeded];
#if !TARGET_OS_VISION
    if (scene != nil && !SohIos_SceneIsLandscape(scene)) {
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometryPreferencesIOS* prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
            [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError* e) {
                NSLog(@"[SohIosShell] onboarding landscape request failed: %@", e);
            }];
            [w.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
        }
        for (int i = 0; i < 30 && !SohIos_SceneIsLandscape(scene); i++) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
#endif
    SohIos_FitModalWindow(w, "ready");
    NSLog(@"[SohIosShell] onboarding window ready %.0fx%.0f scene=%@", w.bounds.size.width, w.bounds.size.height,
          scene ? NSStringFromCGRect(scene.coordinateSpace.bounds) : @"none");
    return w;
}

// acceptTitle is the default button. cancelTitle == NULL → one button, returns 1.
// Otherwise returns 1 for accept, 0 for cancel. Blocks the calling thread.
int SohIos_AlertBlocking(const char* title, const char* message, const char* acceptTitle, const char* cancelTitle) {
    if (![NSThread isMainThread]) {
        __block int hopped = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{
            hopped = SohIos_AlertBlocking(title, message, acceptTitle, cancelTitle);
        });
        return hopped;
    }
    UIWindow* w = SohIos_MakeOnboardingWindow();
    if (w == nil) {
        return 0;
    }
    __block int result = -1;
    NSString* t = title ? [NSString stringWithUTF8String:title] : @"";
    NSString* m = message ? [NSString stringWithUTF8String:message] : @"";
    UIAlertController* a = [UIAlertController alertControllerWithTitle:t
                                                               message:m
                                                        preferredStyle:UIAlertControllerStyleAlert];
    NSString* accept = acceptTitle ? [NSString stringWithUTF8String:acceptTitle] : @"OK";
    [a addAction:[UIAlertAction actionWithTitle:accept
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* _) { result = 1; }]];
    if (cancelTitle != NULL) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:cancelTitle]
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction* _) { result = 0; }]];
    }
    [w.rootViewController presentViewController:a animated:NO completion:^{
        NSLog(@"[SohIosShell] onboarding alert presented: %@", t);
    }];
    while (result < 0) {
        SohIos_FitModalWindow(w, "alert");
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    w.hidden = YES;
    return result;
}

// Nudge the scene to landscape if needed. Retries a few times since the scene
// can lag window creation on iOS 26.
static void SohIos_EnsureLandscape(UIWindow* window, int attempt) {
    UIWindowScene* scene = SohIos_ActiveScene();
    if (scene == nil && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SohIos_EnsureLandscape(window, attempt + 1); });
        return;
    }
    if (scene == nil) {
        return;
    }
    if (window.windowScene != scene) {
        window.windowScene = scene;
    }
    UIInterfaceOrientation o = scene.interfaceOrientation;
    if (o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight) {
        return; // already landscape
    }
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS* prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError* e) {
            NSLog(@"[SohIosShell] landscape request failed: %@", e);
        }];
        [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

// Bridge `hideprobe` backend. Dispatches to the main thread (UIKit) and polls.
// (Starship divergence: the Ship of Harkinian port hangs this off its existing SohStickProbe
// category — this shell never carried the stick-region probe, so the category
// is declared here.)
@interface SohIosTouchOverlay (SohHideProbe)
- (NSString*)hideProbe:(NSArray<NSString*>*)a; // defined in the main @implementation
- (NSString*)perfProbe:(NSArray<NSString*>*)a; // defined in the main @implementation
@end

// Bridge perf instruments (stickspin / zpress / overlayshot) -> the overlay's
// perfProbe:, on the main thread (async + poll, like hideprobe; no
// dispatch_sync from the bridge thread, §2.11).
NSString* SohIos_OverlayPerfProbe(NSArray<NSString*>* args) {
    __block NSString* out = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* r = @"err no overlay";
        for (UIWindow* w in UIApplication.sharedApplication.windows) {
            UIView* root = w.rootViewController.view ?: w;
            for (UIView* v in root.subviews) {
                if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                    r = [(SohIosTouchOverlay*)v perfProbe:args];
                    break;
                }
            }
        }
        out = r;
    });
    for (int i = 0; i < 300 && out == nil; i++) {
        usleep(10 * 1000);
    }
    return out ?: @"err timeout";
}

NSString* SohIos_LayoutHideProbe(NSArray<NSString*>* args) {
    __block NSString* out = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* r = @"err no overlay";
        for (UIWindow* w in UIApplication.sharedApplication.windows) {
            UIView* root = w.rootViewController.view ?: w;
            for (UIView* v in root.subviews) {
                if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                    r = [(SohIosTouchOverlay*)v hideProbe:args];
                    break;
                }
            }
        }
        out = r;
    });
    for (int i = 0; i < 200 && out == nil; i++) {
        usleep(10 * 1000);
    }
    return out ?: @"err timeout";
}

static void SohIos_InstallOverlay(UIWindow* window) {
    // Add the touch overlay above SDL's Metal view, tracking the window bounds.
    for (UIView* v in window.subviews) {
        if ([v isKindOfClass:SohIosTouchOverlay.class]) {
            return; // already installed
        }
    }
    UIView* host = window.rootViewController.view ?: window;
    SohIosTouchOverlay* overlay = [[SohIosTouchOverlay alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:overlay];
#if TARGET_OS_VISION
    // Claim gamepad events app-wide: visionOS otherwise routes pad input to the
    // gaze-and-pinch UI layer, so SDL's GCController sees a DEAD pad — only the
    // d-pad leaks through as pointer navigation (device feedback: "joysticks and
    // buttons don't work, only dpad"). VISION-PRO-GUIDE 1.3.
    if (@available(visionOS 2.0, *)) {
        GCEventInteraction* padClaim = [GCEventInteraction new];
        padClaim.handledEventTypes = GCUIEventTypeGamepad;
        [host addInteraction:padClaim];
        NSLog(@"[SohIosShell] GCEventInteraction gamepad claim installed");
    }
#endif
    NSLog(@"[SohIosShell] touch overlay installed (%.0fx%.0f)", host.bounds.size.width, host.bounds.size.height);
    SohIos_AttachVirtualPad();
    SohIos_ScheduleSelfTest();
}

// The overlay would eat the extractor popups' taps (the stick zone overlaps
// them), and it's useless before game data exists — so install it only once
// an extracted archive is present (poll; extraction can take a while).
static void SohIos_InstallOverlayWhenReady(UIWindow* window, int attempt) {
    if (SohIos_DocumentsHasExt(@[ @"o2r" ])) {
        SohIos_InstallOverlay(window);
        return;
    }
    if (attempt < 1200) { // up to ~20 min of onboarding time
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, attempt + 1); });
    }
}

#if TARGET_OS_VISION
// visionOS §1.5 self-heal: SDL does NOT track the resizable visionOS window, so
// without this the game renders at its own (larger) size and overflows the
// window frame ("too big / doesn't fit"). Every tick, size the SDL window to
// its scene and the metal view chain to the window — but only when actually
// mismatched, so we don't fight SDL when things already agree.
extern void SohIos_GlueWindowToScene(UIWindow* w, UIWindowScene* scene);
extern UIView* SohIos_FindMetalView(UIWindow* w);
static void SohIos_VisionSelfHealTick(void) {
    if (gSoh3DMode != 0) {
        return; // in 3D the window is parked deliberately (do not fight it)
    }
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* mv = SohIos_FindMetalView(w);
        if (mv == nil) {
            continue;
        }
        UIWindowScene* scene = w.windowScene;
        if (scene == nil) {
            return;
        }
        CGRect sb = scene.coordinateSpace.bounds;
        BOOL windowOff = sb.size.width > 1 && !CGRectEqualToRect(w.frame, sb);
        BOOL viewOff = fabs(mv.bounds.size.width - w.bounds.size.width) > 2 ||
                       fabs(mv.bounds.size.height - w.bounds.size.height) > 2;
        if (windowOff || viewOff) {
            SohIos_GlueWindowToScene(w, scene);
            for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
                v.frame = w.bounds;
            }
            [w.rootViewController.view setNeedsLayout];
            [w.rootViewController.view layoutIfNeeded];
        }
        return;
    }
}
static void SohIos_StartVisionSelfHeal(void) {
    [NSTimer scheduledTimerWithTimeInterval:0.25
                                    repeats:YES
                                      block:^(NSTimer* t) { SohIos_VisionSelfHealTick(); }];
}
#endif

void SohIos_OnWindowCreated(struct SDL_Window* sdlWindow) {
    gSdlWindow = sdlWindow;
    // Not overlay-dependent — must be live during onboarding too (a crash or
    // remote-debug need can precede game data existing).
    SohIos_InstallCrashHandler();
    SohIos_StartConsoleBridge(NO);
    SohIos_InstallConfigPersist(); // flush CVars on resign (swipe-kill safety)
    dispatch_async(dispatch_get_main_queue(), ^{ SohIos_InstallBackgroundReconciler(); });
    SohIos_SeedDefaultsOnce();     // per-device fidelity defaults, first run only
    SohIos_MigrateComboCVars();    // SYNC WAVE 2 trap 4: clamp index-keyed CVars
    SDL_SetEventFilter(SohIos_EventFilter, NULL); // soh:// deep links
    // Input environment, first lines of the trace: which device, which pads,
    // and whether a hardware keyboard is attached — the last one decides
    // which of SDL's UIKit keyboard routes was even live on the reporter's
    // iPad (pressesBegan: is skipped whenever a GCKeyboard exists).
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    SohIos_Trace(@"soh %@ (build %@) on %@ %@", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
                 UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion);
    SohIos_Trace(@"hardware keyboard attached: %@", GCKeyboard.coalescedKeyboard != nil ? @"YES" : @"no");
    SohIos_Trace(@"controllers: %@",
                 GCController.controllers.count
                     ? [[GCController.controllers valueForKey:@"vendorName"] componentsJoinedByString:@", "]
                     : @"(none yet)");
    UIWindow* window = SohIos_GetSDLWindow(sdlWindow);
    if (window == nil) {
        NSLog(@"[SohIosShell] no UIKit window for SDL window");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SohIos_InstallSceneDelegate(); // soh:// URL delivery (scene-routed)
#if TARGET_OS_VISION
        // visionOS has no orientation; instead keep the window glued to its
        // resizable scene (§1.5) so the game fills it and never overflows.
        UIWindowScene* vscene = window.windowScene ?: SohIos_ActiveScene();
        if (vscene != nil) {
            window.windowScene = vscene;
            SohIos_GlueWindowToScene(window, vscene);
        }
        SohIos_StartVisionSelfHeal();
#else
        SohIos_EnsureLandscape(window, 0);
#endif
        // Native ROM picker if there's nothing to play yet .
        // NOTE: no window-creation onboarding alert (reference has one).
        // Starship's extraction flow dead-ends pre-window without a ROM —
        // the blocking picker (SohIos_PickRomBlocking, 0015 rev2) covers it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, 0); });
    });
}
