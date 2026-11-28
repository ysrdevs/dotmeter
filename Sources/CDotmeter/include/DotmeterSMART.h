#ifndef DOTMETER_SMART_H
#define DOTMETER_SMART_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

// The NVMe SMART / health log, read through the user client the NVMe driver offers for it (the plug-in that
// ships inside IONVMeFamily). It needs no privileges. `service` is the registry entry that says
// "NVMe SMART Capable"; `log` receives the 512 bytes as the drive returned them.
//
// Returns 0 when read. Otherwise -1: the plug-in could not be loaded for this service, -2: it does not offer
// the SMART interface, -3: the drive refused the read. `detail` then holds what IOKit answered.
int dotmeter_nvme_smart_log(io_service_t service, uint8_t log[512], int32_t *detail);

#endif
