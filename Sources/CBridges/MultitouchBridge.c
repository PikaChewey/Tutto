//
//  MultitouchBridge.c
//  Tutto
//

#include "MultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

// MARK: - Private ABI

typedef const void *MTDeviceRef;

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

/// Layout used by every maintained open-source MultitouchSupport client and
/// validated on macOS 26 (Apple silicon). The static asserts stop the build if
/// the compiler ever lays it out differently.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector millimeters;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

_Static_assert(sizeof(MTTouch) == 96, "MTTouch must be 96 bytes");
_Static_assert(offsetof(MTTouch, normalized) == 32, "MTTouch.normalized offset");
_Static_assert(offsetof(MTTouch, zTotal) == 48, "MTTouch.zTotal offset");
_Static_assert(offsetof(MTTouch, majorAxis) == 60, "MTTouch.majorAxis offset");

// The touch count and frame number are 32-bit ints. Declaring them wider would
// read undefined upper register bits on arm64.
typedef void (*MTFrameCallbackRefcon)(MTDeviceRef, MTTouch *, int32_t, double, int32_t, void *);
typedef void (*MTFrameCallback)(MTDeviceRef, MTTouch *, int32_t, double, int32_t);

typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef bool (*MTDeviceIsBuiltInFn)(MTDeviceRef);
typedef int32_t (*MTDeviceGetFamilyIDFn)(MTDeviceRef, int32_t *);
typedef int32_t (*MTDeviceGetSurfaceFn)(MTDeviceRef, int32_t *, int32_t *);
typedef bool (*MTRegisterRefconFn)(MTDeviceRef, MTFrameCallbackRefcon, void *);
typedef bool (*MTRegisterFn)(MTDeviceRef, MTFrameCallback);
typedef bool (*MTUnregisterFn)(MTDeviceRef, void *);
typedef int32_t (*MTDeviceStartFn)(MTDeviceRef, int32_t);
typedef int32_t (*MTDeviceStopFn)(MTDeviceRef);
typedef uint32_t (*MTDeviceGetServiceFn)(MTDeviceRef);

static struct {
    void *handle;
    MTDeviceCreateListFn createList;
    MTDeviceIsBuiltInFn isBuiltIn;
    MTDeviceGetFamilyIDFn familyID;
    MTDeviceGetSurfaceFn surface;
    MTRegisterRefconFn registerRefcon;
    MTRegisterFn registerPlain;
    MTUnregisterFn unregister;
    MTDeviceStartFn start;
    MTDeviceStopFn stop;
    MTDeviceGetServiceFn service;
} api;

// MARK: - State

#define CC_MAX_DEVICES 8

typedef struct {
    MTDeviceRef device;
    int32_t index;
    CCDeviceInfo info;
} DeviceSlot;

static DeviceSlot slots[CC_MAX_DEVICES];
static int32_t slotCount = 0;
static CFMutableArrayRef deviceList = NULL;
static CCFrameHandler frameHandler = NULL;
static void *frameContext = NULL;
static atomic_bool running = false;

static bool loadAPI(void) {
    if (api.handle != NULL) {
        return true;
    }
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                          RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        return false;
    }
    api.createList = (MTDeviceCreateListFn)dlsym(handle, "MTDeviceCreateList");
    api.isBuiltIn = (MTDeviceIsBuiltInFn)dlsym(handle, "MTDeviceIsBuiltIn");
    api.familyID = (MTDeviceGetFamilyIDFn)dlsym(handle, "MTDeviceGetFamilyID");
    api.surface = (MTDeviceGetSurfaceFn)dlsym(handle, "MTDeviceGetSensorSurfaceDimensions");
    api.registerRefcon = (MTRegisterRefconFn)dlsym(handle, "MTRegisterContactFrameCallbackWithRefcon");
    api.registerPlain = (MTRegisterFn)dlsym(handle, "MTRegisterContactFrameCallback");
    api.unregister = (MTUnregisterFn)dlsym(handle, "MTUnregisterContactFrameCallback");
    api.start = (MTDeviceStartFn)dlsym(handle, "MTDeviceStart");
    api.stop = (MTDeviceStopFn)dlsym(handle, "MTDeviceStop");
    api.service = (MTDeviceGetServiceFn)dlsym(handle, "MTDeviceGetService");  // optional

    if (api.createList == NULL || api.isBuiltIn == NULL || api.unregister == NULL ||
        api.start == NULL || api.stop == NULL ||
        (api.registerRefcon == NULL && api.registerPlain == NULL)) {
        dlclose(handle);
        memset(&api, 0, sizeof(api));
        return false;
    }
    api.handle = handle;
    return true;
}

// MARK: - Frames

static void deliver(const DeviceSlot *slot, const MTTouch *touches, int32_t count) {
    if (!atomic_load_explicit(&running, memory_order_acquire) || frameHandler == NULL) {
        return;
    }
    if (count < 0 || (count > 0 && touches == NULL)) {
        return;
    }

    CCContact contacts[CC_MAX_CONTACTS];
    int32_t kept = 0;
    for (int32_t i = 0; i < count && kept < CC_MAX_CONTACTS; i++) {
        const MTTouch *touch = &touches[i];
        const float x = touch->normalized.position.x;
        const float y = touch->normalized.position.y;
        if (!isfinite(x) || !isfinite(y) || !isfinite(touch->zTotal)) {
            continue;
        }
        contacts[kept++] = (CCContact){
            .identifier = touch->pathIndex,
            .state = touch->state,
            .x = fminf(fmaxf(x, 0.0f), 1.0f),
            .y = fminf(fmaxf(y, 0.0f), 1.0f),
            .size = touch->zTotal,
            .majorAxis = isfinite(touch->majorAxis) ? touch->majorAxis : 0.0f,
            .minorAxis = isfinite(touch->minorAxis) ? touch->minorAxis : 0.0f,
        };
    }
    frameHandler(frameContext, slot->index, contacts, kept);
}

static void frameCallbackRefcon(MTDeviceRef device, MTTouch *touches, int32_t count,
                                double timestamp, int32_t frame, void *refcon) {
    (void)device;
    (void)timestamp;
    (void)frame;
    if (refcon != NULL) {
        deliver((const DeviceSlot *)refcon, touches, count);
    }
}

static void frameCallbackPlain(MTDeviceRef device, MTTouch *touches, int32_t count,
                               double timestamp, int32_t frame) {
    (void)timestamp;
    (void)frame;
    for (int32_t i = 0; i < slotCount; i++) {
        if (slots[i].device == device) {
            deliver(&slots[i], touches, count);
            return;
        }
    }
}

// MARK: - Lifecycle

static bool isTrackpad(MTDeviceRef device, CCDeviceInfo *info) {
    memset(info, 0, sizeof(*info));
    info->builtIn = api.isBuiltIn(device);
    if (api.familyID != NULL) {
        api.familyID(device, &info->familyID);
    }
    if (api.surface != NULL) {
        api.surface(device, &info->surfaceWidth, &info->surfaceHeight);
    }
    if (info->builtIn) {
        return true;
    }
    // Magic Mouse reports family 112/113 and a small surface; corners make no sense there.
    if (info->familyID == 112 || info->familyID == 113) {
        return false;
    }
    return info->surfaceWidth >= 9000 && info->surfaceHeight >= 5000;
}

int32_t CCMultitouchStart(CCFrameHandler handler, void *context) {
    CCMultitouchStop();
    if (handler == NULL || !loadAPI()) {
        return -1;
    }

    deviceList = api.createList();
    if (deviceList == NULL) {
        return 0;
    }

    frameHandler = handler;
    frameContext = context;
    slotCount = 0;

    const CFIndex total = CFArrayGetCount(deviceList);
    for (CFIndex i = 0; i < total && slotCount < CC_MAX_DEVICES; i++) {
        MTDeviceRef device = CFArrayGetValueAtIndex(deviceList, i);
        CCDeviceInfo info;
        if (device == NULL || !isTrackpad(device, &info)) {
            continue;
        }
        DeviceSlot *slot = &slots[slotCount];
        slot->device = device;
        slot->index = slotCount;
        slot->info = info;

        bool registered = api.registerRefcon != NULL
            ? api.registerRefcon(device, frameCallbackRefcon, slot)
            : api.registerPlain(device, frameCallbackPlain);
        if (!registered) {
            continue;
        }
        if (api.start(device, 0) != 0) {
            api.unregister(device, api.registerRefcon != NULL ? (void *)frameCallbackRefcon
                                                              : (void *)frameCallbackPlain);
            continue;
        }
        slotCount++;
    }

    atomic_store_explicit(&running, slotCount > 0, memory_order_release);
    if (slotCount == 0) {
        CFRelease(deviceList);
        deviceList = NULL;
    }
    return slotCount;
}

void CCMultitouchStop(void) {
    atomic_store_explicit(&running, false, memory_order_release);
    for (int32_t i = 0; i < slotCount; i++) {
        api.stop(slots[i].device);
        api.unregister(slots[i].device, api.registerRefcon != NULL ? (void *)frameCallbackRefcon
                                                                   : (void *)frameCallbackPlain);
        slots[i].device = NULL;
    }
    slotCount = 0;
    if (deviceList != NULL) {
        CFRelease(deviceList);
        deviceList = NULL;
    }
}

int32_t CCMultitouchDeviceCount(void) {
    return slotCount;
}

uint32_t CCMultitouchDeviceService(int32_t deviceIndex) {
    if (api.service == NULL || deviceIndex < 0 || deviceIndex >= slotCount || slots[deviceIndex].device == NULL) {
        return 0;
    }
    return api.service(slots[deviceIndex].device);
}

bool CCMultitouchDeviceInfo(int32_t deviceIndex, CCDeviceInfo *info) {
    if (info == NULL || deviceIndex < 0 || deviceIndex >= slotCount) {
        return false;
    }
    *info = slots[deviceIndex].info;
    return true;
}
