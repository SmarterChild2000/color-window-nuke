// IntentModel.h — decides whether a Color panel appearance was user-requested.
//
// Pure C++ (no Illustrator, no AppKit) so it can be unit-tested headlessly.
//
// Observed behaviour (docs/HOW-IT-WORKS.md):
//   * Clicking the inactive Fill/Stroke swatch shows the Color panel first, and
//     then Illustrator broadcasts kAIPaintStyleFillStrokeChangedNotifier
//     synchronously, on the click's mouse-up.
//   * The Window > Color checkmark is NOT live (it updates only when the Window
//     menu opens), so it cannot tell us the panel's state.
//   * When the closed Color panel is auto-opened as a floating panel, a new
//     floating Adobe panel window becomes visible during that click and is
//     already visible when the notifier arrives.
//
// So: a Fill/Stroke-changed notification that arrives inside a pointer gesture
// during which exactly one new floating panel window appeared is an automatic
// activation. Window > Color and its shortcut never produce that notification,
// a panel the user already had open produces no new window, and anything
// ambiguous (zero or several new windows, other window kinds) is left alone.
//
// More generally, a window positively identified as the Color panel that
// becomes visible as a *floating* window during a click or key press is an
// automatic activation, unless that input was explicit: a Window > Color
// command, any menu action, or a workspace switch. Color appearing as an
// icon-dock drawer is not handled (closing it would remove it from the dock).
// When unsure the model does nothing: native Illustrator behaviour.
#pragma once
#include <cstdint>

namespace pc {

enum class Mode : int8_t { Off = 0, Diagnose = 1, Enforce = 2 };

struct Decision {
    bool hide;
    const char *reason;
};

class IntentModel {
public:
    void setMode(Mode m) { mode_ = m; }
    Mode mode() const { return mode_; }
    void setPaused(bool p) { paused_ = p; }

    // A reversal that did not make the panel window go away means our reading
    // of this Illustrator build is wrong: stop acting for the rest of the session.
    void disableForSession() { sessionDisabled_ = true; }
    bool sessionDisabled() const { return sessionDisabled_; }

    // Called before Illustrator dispatches a left-mouse-down or key-down.
    void onInputStart(uint64_t inputId) { gesture_ = inputId; }
    void onPointerDown(uint64_t inputId) { onInputStart(inputId); }

    // "AI Command Notifier: Before/After Adobe Color Palette" (Window > Color, F6, ...).
    void onExplicitCommandBegin() { inExplicitCommand_ = true; explicitGesture_ = gesture_; }
    void onExplicitCommandEnd() { inExplicitCommand_ = false; }
    // Any menu action (mouse or key equivalent) is an explicit user command.
    void onMenuAction() { explicitGesture_ = gesture_; }
    // A workspace switch may legitimately show the Color panel.
    void onWorkspaceChanged() { workspaceGesture_ = gesture_; }

    // kAIPaintStyleFillStrokeChangedNotifier.
    //   inPointerEvent:  NSApp.currentEvent is a left mouse down/up/drag.
    //   newPanelWindows: floating Adobe panel windows that became visible since
    //                    this gesture's mouse-down.
    Decision onFillStrokeChanged(bool inPointerEvent, int newPanelWindows) {
        if (reentrant_) return {false, "reentrant (our own reversal)"};
        if (mode_ != Mode::Enforce) return {false, "mode is not enforce"};
        if (paused_) return {false, "paused by user"};
        if (sessionDisabled_) return {false, "disabled for this session after an ineffective reversal"};
        if (inExplicitCommand_) return {false, "inside explicit Color command"};
        if (!inPointerEvent) return {false, "not a pointer gesture (keyboard X, script, idle)"};
        if (gesture_ == 0) return {false, "no pointer gesture recorded"};
        if (explicitGesture_ == gesture_) return {false, "gesture contained explicit command"};
        if (workspaceGesture_ == gesture_) return {false, "workspace switch"};
        if (actedGesture_ == gesture_) return {false, "already reversed in this gesture"};
        if (newPanelWindows == 0) return {false, "no panel window appeared (panel was already open, or docked)"};
        if (newPanelWindows > 1) return {false, "several panel windows appeared (ambiguous)"};
        actedGesture_ = gesture_;
        return {true, "Color panel window auto-opened by a Fill/Stroke proxy click"};
    }

    // A window identified as the Color panel became visible during the current
    // click or key press (any path: "<" key, Appearance panel, ...).
    //   duringInput:     still within the input that started this gesture.
    //   floatingColor:   new floating windows identified as the Color panel.
    //   drawerColor:     new icon-dock drawers identified as the Color panel.
    Decision onColorWindowAppeared(bool duringInput, int floatingColor, int drawerColor) {
        if (reentrant_) return {false, "reentrant (our own reversal)"};
        if (mode_ != Mode::Enforce) return {false, "mode is not enforce"};
        if (paused_) return {false, "paused by user"};
        if (sessionDisabled_) return {false, "disabled for this session after an ineffective reversal"};
        if (inExplicitCommand_) return {false, "inside explicit Color command"};
        if (!duringInput) return {false, "not during a click or key press"};
        if (gesture_ == 0) return {false, "no input recorded"};
        if (explicitGesture_ == gesture_) return {false, "input was an explicit command or menu action"};
        if (workspaceGesture_ == gesture_) return {false, "workspace switch"};
        if (actedGesture_ == gesture_) return {false, "already reversed in this input"};
        if (floatingColor == 0)
            return {false, drawerColor ? "Color appeared as an icon-dock drawer (not handled)" : "no Color panel window"};
        if (floatingColor > 1) return {false, "several Color windows appeared (ambiguous)"};
        actedGesture_ = gesture_;
        return {true, "Color panel window auto-opened during a click or key press"};
    }

    // EXPERIMENTAL (off by default): an icon-dock drawer holding the Color panel
    // popped out. Only hidden when a color change caused it (Fill/Stroke, "<"):
    // a drawer the user opened by clicking the Color icon involves no color
    // change. Never calls ToggleColorDialog (that would remove the icon).
    void setDrawerExperiment(bool on) { drawerExperiment_ = on; }
    void disableDrawerForSession() { drawerDisabled_ = true; }
    bool drawerDisabled() const { return drawerDisabled_; }
    Decision onDrawerAppeared(bool duringInput, bool causedByColorChange) {
        if (reentrant_) return {false, "reentrant (our own reversal)"};
        if (mode_ != Mode::Enforce) return {false, "mode is not enforce"};
        if (paused_) return {false, "paused by user"};
        if (!drawerExperiment_) return {false, "icon-dock drawer handling is off (experimental)"};
        if (drawerDisabled_) return {false, "drawer handling stopped for this session (drawer came back)"};
        if (inExplicitCommand_) return {false, "inside explicit Color command"};
        if (!duringInput) return {false, "not during a click or key press"};
        if (gesture_ == 0) return {false, "no input recorded"};
        if (explicitGesture_ == gesture_) return {false, "input was an explicit command or menu action"};
        if (workspaceGesture_ == gesture_) return {false, "workspace switch"};
        if (!causedByColorChange) return {false, "drawer opened without a color change (user clicked the icon)"};
        if (drawerActedGesture_ == gesture_) return {false, "already hid a drawer in this input"};
        drawerActedGesture_ = gesture_;
        return {true, "Color drawer popped out by a color change"};
    }

    // Guard so notifications caused by our own ToggleColorDialog are ignored.
    struct Reentry {
        explicit Reentry(IntentModel &m) : m_(m) { m_.reentrant_ = true; }
        ~Reentry() { m_.reentrant_ = false; }
        IntentModel &m_;
    };

private:
    Mode mode_ = Mode::Diagnose;
    bool paused_ = false;
    bool reentrant_ = false;
    bool sessionDisabled_ = false;
    bool inExplicitCommand_ = false;
    uint64_t gesture_ = 0;
    uint64_t actedGesture_ = 0;
    uint64_t explicitGesture_ = 0;
    uint64_t workspaceGesture_ = 0;
    bool drawerExperiment_ = false;
    bool drawerDisabled_ = false;
    uint64_t drawerActedGesture_ = 0;
};

}  // namespace pc
