//
//  SMCBridge.c
//  Tutto
//

#include "SMCBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>

// MARK: - SMC user client ABI (stable since Intel Macs, unchanged on Apple silicon)

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "SMCParam must be 80 bytes");

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static io_connect_t connection = 0;

static uint32_t fourCC(const char key[4]) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static kern_return_t call(SMCParam *input, SMCParam *output) {
    size_t outputSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(connection, kSMCHandleYPCEvent, input, sizeof(SMCParam), output, &outputSize);
}

bool TSMCOpen(void) {
    if (connection != 0) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return false;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        connection = 0;
        return false;
    }
    return true;
}

void TSMCClose(void) {
    if (connection != 0) {
        IOServiceClose(connection);
        connection = 0;
    }
}

static bool keyInfo(uint32_t key, SMCKeyInfo *info) {
    SMCParam input = {0}, output = {0};
    input.key = key;
    input.data8 = kSMCGetKeyInfo;
    if (call(&input, &output) != KERN_SUCCESS || output.result != 0) return false;
    *info = output.keyInfo;
    return true;
}

bool TSMCRead(const char key[4], TSMCValue *value) {
    if (!TSMCOpen() || value == NULL) return false;
    uint32_t code = fourCC(key);
    SMCKeyInfo info;
    if (!keyInfo(code, &info)) return false;
    SMCParam input = {0}, output = {0};
    input.key = code;
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = kSMCReadKey;
    if (call(&input, &output) != KERN_SUCCESS || output.result != 0) return false;
    memset(value, 0, sizeof(*value));
    value->key = code;
    value->dataType = info.dataType;
    value->dataSize = info.dataSize > 32 ? 32 : info.dataSize;
    value->attributes = (uint8_t)info.dataAttributes;
    memcpy(value->bytes, output.bytes, value->dataSize);
    return true;
}

int32_t TSMCWrite(const char key[4], const uint8_t *bytes, uint32_t size) {
    if (!TSMCOpen()) return (int32_t)kIOReturnNotOpen;
    if (size > 32 || bytes == NULL) return (int32_t)kIOReturnBadArgument;
    uint32_t code = fourCC(key);
    SMCKeyInfo info;
    if (!keyInfo(code, &info)) return (int32_t)kIOReturnNotFound;
    if (info.dataSize != size) return (int32_t)kIOReturnBadArgument;
    SMCParam input = {0}, output = {0};
    input.key = code;
    input.data8 = kSMCWriteKey;
    input.keyInfo.dataSize = size;
    memcpy(input.bytes, bytes, size);
    kern_return_t result = call(&input, &output);
    if (result != KERN_SUCCESS) return (int32_t)result;
    return output.result == 0 ? 0 : (int32_t)kIOReturnError;
}

uint32_t TSMCKeyCount(void) {
    TSMCValue value;
    if (!TSMCRead("#KEY", &value) || value.dataSize < 4) return 0;
    return ((uint32_t)value.bytes[0] << 24) | ((uint32_t)value.bytes[1] << 16) |
           ((uint32_t)value.bytes[2] << 8) | (uint32_t)value.bytes[3];
}

bool TSMCKeyAtIndex(uint32_t index, uint32_t *key) {
    if (!TSMCOpen() || key == NULL) return false;
    SMCParam input = {0}, output = {0};
    input.data8 = kSMCGetKeyFromIndex;
    input.data32 = index;
    if (call(&input, &output) != KERN_SUCCESS || output.result != 0) return false;
    *key = output.key;
    return true;
}

bool TSMCValueAsDouble(const TSMCValue *v, double *out) {
    if (v == NULL || out == NULL) return false;
    const uint8_t *b = v->bytes;
    switch (v->dataType) {
    case 0x666c7420: { // "flt " little-endian float
        if (v->dataSize < 4) return false;
        float f;
        memcpy(&f, b, 4);
        if (!isfinite(f)) return false;
        *out = f;
        return true;
    }
    case 0x66706532: // "fpe2" big-endian unsigned 14.2
        *out = (double)(((uint32_t)b[0] << 8) | b[1]) / 4.0;
        return true;
    case 0x73703738: { // "sp78" big-endian signed 7.8
        int16_t raw = (int16_t)(((uint16_t)b[0] << 8) | b[1]);
        *out = raw / 256.0;
        return true;
    }
    case 0x75693820: *out = b[0]; return true; // "ui8 "
    case 0x75693136: *out = (double)(((uint32_t)b[0] << 8) | b[1]); return true; // "ui16"
    case 0x75693332: *out = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]); return true;
    case 0x73693820: *out = (int8_t)b[0]; return true; // "si8 "
    case 0x73693136: *out = (int16_t)(((uint16_t)b[0] << 8) | b[1]); return true; // "si16"
    default: return false;
    }
}

// MARK: - IOHID temperature sensors (private, stable since macOS 11)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15

static IOHIDEventSystemClientRef sensorClient = NULL;

int32_t TSensorsRead(TSensorReading *readings, int32_t capacity) {
    if (readings == NULL || capacity <= 0) return 0;
    if (sensorClient == NULL) {
        sensorClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (sensorClient == NULL) return 0;
        int page = 0xff00, usage = 5;  // AppleVendor, TemperatureSensor
        CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
        const void *values[] = {pageNumber, usageNumber};
        CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                      &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(sensorClient, matching);
        CFRelease(matching);
        CFRelease(pageNumber);
        CFRelease(usageNumber);
    }
    CFArrayRef services = IOHIDEventSystemClientCopyServices(sensorClient);
    if (services == NULL) return 0;
    int32_t count = 0;
    CFIndex total = CFArrayGetCount(services);
    for (CFIndex i = 0; i < total && count < capacity; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (event != NULL) {
            double value = IOHIDEventGetFloatValue(event, kIOHIDEventTypeTemperature << 16);
            TSensorReading *reading = &readings[count];
            memset(reading->name, 0, sizeof(reading->name));
            if (product != NULL && CFGetTypeID(product) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)product, reading->name, sizeof(reading->name), kCFStringEncodingUTF8);
            }
            reading->celsius = value;
            count++;
            CFRelease(event);
        }
        if (product != NULL) CFRelease(product);
    }
    CFRelease(services);
    return count;
}

void TSensorsRelease(void) {
    if (sensorClient != NULL) {
        CFRelease(sensorClient);
        sensorClient = NULL;
    }
}
