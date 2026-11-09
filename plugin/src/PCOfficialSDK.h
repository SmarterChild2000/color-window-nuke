// PCOfficialSDK.h — maps Color Window Nuke onto the official Adobe Illustrator SDK.
// Used when building with `build.sh --sdk <IllustratorSDK root>`; the SDK is
// obtained from Adobe (https://developer.adobe.com/console) and never bundled.
#pragma once
#include "SPBasic.h"
#include "SPInterf.h"
#include "SPAccess.h"
#include "AINotifier.h"
#include "AIMenu.h"
#include "AIPaintStyle.h"
#include "AIPlugin.h"
#include "AIRuntime.h"
#include "AIWorkspace.h"
#include "AIMenuCommandNotifiers.h"

// Names used by ColorWindowNuke.mm for explicit suite versions.
#define kAINotifierSuiteVersion5 AIAPI_VERSION(5)
#define kAINotifierSuiteVersion4 AIAPI_VERSION(4)
#define kAIMenuSuiteVersion11 AIAPI_VERSION(11)
#define kAIPaintStyleSuiteVersion10 AIAPI_VERSION(10)
