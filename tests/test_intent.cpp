// Headless unit tests for pc::IntentModel. Build+run: tests/run_tests.sh
#include "../plugin/src/IntentModel.h"
#include <cstdio>

using pc::IntentModel;
using pc::Mode;

static int failures = 0, passes = 0;
#define EXPECT(cond, name)                                                  \
    do {                                                                    \
        if (cond) { ++passes; }                                             \
        else { ++failures; std::printf("FAIL: %s (%s:%d)\n", name, __FILE__, __LINE__); } \
    } while (0)

static IntentModel enforcing() {
    IntentModel m;
    m.setMode(Mode::Enforce);
    return m;
}

int main() {
    {   // Closed panel auto-opened by a proxy click -> reverse it.
        IntentModel m = enforcing();
        m.onPointerDown(1);
        EXPECT(m.onFillStrokeChanged(true, 1).hide, "one new panel window during proxy click is reversed");
    }
    {   // Only once per gesture (no toggle loops).
        IntentModel m = enforcing();
        m.onPointerDown(1);
        m.onFillStrokeChanged(true, 1);
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "at most one reversal per gesture");
        m.onPointerDown(2);
        EXPECT(m.onFillStrokeChanged(true, 1).hide, "next gesture can act again");
    }
    {   // Panel already open (user opened it): no new window -> never closed.
        IntentModel m = enforcing();
        m.onPointerDown(3);
        EXPECT(!m.onFillStrokeChanged(true, 0).hide, "already-open panel stays open");
    }
    {   // Ambiguous: several windows appeared.
        IntentModel m = enforcing();
        m.onPointerDown(4);
        EXPECT(!m.onFillStrokeChanged(true, 2).hide, "several new windows are ambiguous");
    }
    {   // Keyboard X / scripts / idle broadcasts are not proxy clicks.
        IntentModel m = enforcing();
        m.onPointerDown(5);
        EXPECT(!m.onFillStrokeChanged(false, 1).hide, "non-pointer change ignored");
    }
    {   // Window > Color / F6 inside the gesture is respected.
        IntentModel m = enforcing();
        m.onPointerDown(6);
        m.onExplicitCommandBegin();
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "inside explicit command");
        m.onExplicitCommandEnd();
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "after explicit command, same gesture");
        m.onPointerDown(7);
        EXPECT(m.onFillStrokeChanged(true, 1).hide, "later proxy click acts normally");
    }
    {   // Modes.
        IntentModel m = enforcing();
        m.setMode(Mode::Diagnose);
        m.onPointerDown(10);
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "diagnose mode never acts");
        m.setMode(Mode::Off);
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "off mode never acts");
        m.setMode(Mode::Enforce);
        m.setPaused(true);
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "paused never acts");
        m.setPaused(false);
        EXPECT(m.onFillStrokeChanged(true, 1).hide, "resumed acts");
    }
    {   // Reentrancy guard for our own ToggleColorDialog.
        IntentModel m = enforcing();
        m.onPointerDown(11);
        IntentModel::Reentry r(m);
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "reentrant notification ignored");
    }
    {   // Ineffective reversal disables the fix for the session.
        IntentModel m = enforcing();
        m.disableForSession();
        m.onPointerDown(12);
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "session-disabled never acts");
        EXPECT(m.sessionDisabled(), "session-disabled flag reported");
    }
    {   // Generic path: Color window appears during a key press ("<") or click.
        IntentModel m = enforcing();
        m.onInputStart(20);
        EXPECT(m.onColorWindowAppeared(true, 1, 0).hide, "floating Color window during input is closed");
        EXPECT(!m.onColorWindowAppeared(true, 1, 0).hide, "only once per input");
        m.onInputStart(21);
        EXPECT(!m.onColorWindowAppeared(true, 0, 1).hide, "icon-dock drawer is never closed");
        EXPECT(!m.onColorWindowAppeared(true, 0, 0).hide, "no Color window, nothing to do");
        EXPECT(!m.onColorWindowAppeared(true, 2, 0).hide, "several Color windows are ambiguous");
        EXPECT(!m.onColorWindowAppeared(false, 1, 0).hide, "outside any input is never acted on");
    }
    {   // Explicit sources are respected on the generic path.
        IntentModel m = enforcing();
        m.onInputStart(30);
        m.onMenuAction();
        EXPECT(!m.onColorWindowAppeared(true, 1, 0).hide, "menu action (e.g. Window > Color) is explicit");
        m.onInputStart(31);
        m.onWorkspaceChanged();
        EXPECT(!m.onColorWindowAppeared(true, 1, 0).hide, "workspace switch may show Color");
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "workspace switch also blocks the Fill/Stroke path");
        m.onInputStart(32);
        m.onExplicitCommandBegin();
        EXPECT(!m.onColorWindowAppeared(true, 1, 0).hide, "Color command in progress");
        m.onExplicitCommandEnd();
        m.onInputStart(33);
        EXPECT(m.onColorWindowAppeared(true, 1, 0).hide, "next plain input acts again");
        m.setPaused(true);
        m.onInputStart(34);
        EXPECT(!m.onColorWindowAppeared(true, 1, 0).hide, "paused never acts (generic path)");
    }
    {   // Both paths share the once-per-input guard.
        IntentModel m = enforcing();
        m.onInputStart(40);
        m.onFillStrokeChanged(true, 1);
        EXPECT(!m.onColorWindowAppeared(true, 1, 0).hide, "no second reversal after the Fill/Stroke path acted");
    }
    {   // Experimental icon-dock drawer handling.
        IntentModel m = enforcing();
        m.onInputStart(50);
        EXPECT(!m.onDrawerAppeared(true, true).hide, "drawer handling is off by default");
        m.setDrawerExperiment(true);
        EXPECT(m.onDrawerAppeared(true, true).hide, "drawer popped by a color change is hidden");
        EXPECT(!m.onDrawerAppeared(true, true).hide, "once per input");
        m.onInputStart(51);
        EXPECT(!m.onDrawerAppeared(true, false).hide, "drawer the user opened (no color change) is left alone");
        m.onInputStart(52);
        m.onMenuAction();
        EXPECT(!m.onDrawerAppeared(true, true).hide, "menu action is explicit");
        m.onInputStart(53);
        m.onWorkspaceChanged();
        EXPECT(!m.onDrawerAppeared(true, true).hide, "workspace switch is respected");
        m.onInputStart(54);
        m.disableDrawerForSession();
        EXPECT(!m.onDrawerAppeared(true, true).hide, "stops after the drawer came back");
        m.onInputStart(55);
        EXPECT(m.onColorWindowAppeared(true, 1, 0).hide, "floating handling is unaffected by the drawer stop");
    }
    {   // No gesture yet (e.g. notification at launch).
        IntentModel m = enforcing();
        EXPECT(!m.onFillStrokeChanged(true, 1).hide, "no gesture recorded");
    }
    std::printf("%d passed, %d failed\n", passes, failures);
    return failures ? 1 : 0;
}
