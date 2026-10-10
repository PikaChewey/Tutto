//
//  MultitouchBridge.h
//  Tutto
//
//  A tiny C shim over Apple's private MultitouchSupport.framework.
//  It is loaded at runtime with dlopen, so the app still launches (and simply
//  reports "unavailable") if a future macOS removes or changes the framework.
//

#ifndef MultitouchBridge_h
#define MultitouchBridge_h

#include <stdbool.h>
#include <stdint.h>

#define CC_MAX_CONTACTS 12

/// One finger (or palm) on a trackpad, in normalized surface coordinates.
typedef struct {
    int32_t identifier;  ///< Stable for as long as this contact stays on the surface.
    int32_t state;       ///< Raw MultitouchSupport path state; 3 and 4 mean "touching".
    float x;             ///< 0 = left edge, 1 = right edge.
    float y;             ///< 0 = bottom edge, 1 = top edge.
    float size;          ///< Contact size ("zTotal"); grows with pressure and area.
    float majorAxis;     ///< Ellipse axes of the contact, useful for palm detection.
    float minorAxis;
} CCContact;

typedef struct {
    bool builtIn;
    int32_t familyID;
    int32_t surfaceWidth;   ///< Hundredths of a millimetre.
    int32_t surfaceHeight;  ///< Hundredths of a millimetre.
} CCDeviceInfo;

/// Called on MultitouchSupport's delivery thread for every frame while a finger
/// is on a trackpad. Never called while the surface is untouched.
typedef void (*CCFrameHandler)(void *context,
                               int32_t deviceIndex,
                               const CCContact *contacts,
                               int32_t count);

/// Starts every trackpad (built-in and Magic Trackpad; mice are skipped).
/// Returns the number of trackpads started, or -1 if MultitouchSupport could not be loaded.
int32_t CCMultitouchStart(CCFrameHandler handler, void *context);

/// Stops and releases every device. Safe to call when nothing is running.
void CCMultitouchStop(void);

/// Number of trackpads currently started.
int32_t CCMultitouchDeviceCount(void);

/// Fills `info` for a started trackpad. Returns false for an invalid index.
bool CCMultitouchDeviceInfo(int32_t deviceIndex, CCDeviceInfo *info);

/// The IORegistry service of a started trackpad (0 if unknown). Its driver holds the
/// live trackpad settings macOS pushes to it, such as Tap to click.
uint32_t CCMultitouchDeviceService(int32_t deviceIndex);

#endif /* MultitouchBridge_h */
