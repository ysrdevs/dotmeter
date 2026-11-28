#include "DotmeterSMART.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <string.h>

// The plug-in type and the interface inside it. Neither is in a public header; these are the ids the driver's
// registry entry lists under IOCFPlugInTypes and that smartmontools uses to read a Mac's NVMe drives.
#define DOTMETER_SMART_TYPE CFUUIDGetConstantUUIDWithBytes(NULL, \
    0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
#define DOTMETER_SMART_INTERFACE CFUUIDGetConstantUUIDWithBytes(NULL, \
    0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

// The start of the interface's table of functions. Only the first is called; the table goes on.
typedef struct {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *interface, void *log);
} dotmeter_smart_interface_t;

int dotmeter_nvme_smart_log(io_service_t service, uint8_t log[512], int32_t *detail) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t made = IOCreatePlugInInterfaceForService(service, DOTMETER_SMART_TYPE, kIOCFPlugInInterfaceID, &plugin, &score);
    if (made != KERN_SUCCESS || plugin == NULL) {
        if (detail) *detail = (int32_t)made;
        return -1;
    }
    int result = 0;
    dotmeter_smart_interface_t **smart = NULL;
    HRESULT asked = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(DOTMETER_SMART_INTERFACE), (LPVOID *)&smart);
    if (asked != S_OK || smart == NULL) {
        if (detail) *detail = (int32_t)asked;
        result = -2;
    } else {
        // Into a buffer of our own first: a drive that fails part-way must not leave half a log behind.
        uint8_t buffer[512];
        memset(buffer, 0, sizeof(buffer));
        IOReturn read = (*smart)->SMARTReadData(smart, buffer);
        if (read == kIOReturnSuccess) {
            memcpy(log, buffer, sizeof(buffer));
        } else {
            if (detail) *detail = (int32_t)read;
            result = -3;
        }
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return result;
}
