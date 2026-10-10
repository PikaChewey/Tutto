//
//  SMCBridge.h
//  Tutto
//
//  Reads (and, as root, writes) keys on the System Management Controller through
//  the AppleSMC user client, and reads temperature sensors through the IOHID event
//  system. Reads need no privileges. Writes return kIOReturnNotPrivileged unless
//  the caller is root, which is why fan control goes through TuttoHelper.
//

#ifndef SMCBridge_h
#define SMCBridge_h

#include <stdbool.h>
#include <stdint.h>

/// A raw SMC value: its four-character type ("flt ", "ui8 ", "fpe2" …) and bytes.
typedef struct {
    uint32_t key;
    uint32_t dataType;
    uint32_t dataSize;
    uint8_t attributes;
    uint8_t bytes[32];
} TSMCValue;

/// Opens the AppleSMC user client. Returns false if there is no SMC.
bool TSMCOpen(void);
void TSMCClose(void);

/// Reads one key. Returns false if the key does not exist on this Mac.
bool TSMCRead(const char key[4], TSMCValue *value);

/// Writes `size` bytes to a key. Returns the IOKit status (0 = success).
/// Non-root callers get kIOReturnNotPrivileged (0xe00002c1).
int32_t TSMCWrite(const char key[4], const uint8_t *bytes, uint32_t size);

/// Total number of keys, and the key at an index (for discovery).
uint32_t TSMCKeyCount(void);
bool TSMCKeyAtIndex(uint32_t index, uint32_t *key);

/// Decodes common numeric SMC types (flt, fpe2, sp78, ui8/16/32, si8/16) to a double.
/// Returns false for types it does not understand.
bool TSMCValueAsDouble(const TSMCValue *value, double *out);

// MARK: - Temperature sensors (IOHID, Apple silicon)

#define TSENSOR_MAX 128

typedef struct {
    char name[64];
    double celsius;
} TSensorReading;

/// Reads every temperature sensor the IOHID event system exposes. Returns the count.
/// The client is created on first use and kept; call TSensorsRelease() when done.
int32_t TSensorsRead(TSensorReading *readings, int32_t capacity);
void TSensorsRelease(void);

#endif /* SMCBridge_h */
