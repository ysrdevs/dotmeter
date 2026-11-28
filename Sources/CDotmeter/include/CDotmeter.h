#ifndef CDOTMETER_H
#define CDOTMETER_H

#include <errno.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <stdint.h>

// Apple SMC user-client parameter block. Layout must match the kext exactly (80 bytes).
typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

// Typed wrapper so Swift can read per-process resource usage without pointer gymnastics.
static inline int dotmeter_proc_rusage_v4(int pid, struct rusage_info_v4 *out) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)out);
}

// CPU time, memory, disk bytes and energy for one process. Version 6 of the structure adds the energy
// counter; older systems answer with version 4, which has everything else.
typedef struct {
    uint64_t cpu_time;
    uint64_t footprint;
    uint64_t disk_read;
    uint64_t disk_written;
    uint64_t energy_nj;
    int      has_energy;
    // When the process started, in mach time: with the pid, this says which process it is.
    uint64_t start;
} dotmeter_proc_usage_t;

// Returns 0 when read, -2 when the process may not be read by this user (another user's, or the system's),
// and -1 for anything else. A refusal is final, so the older structure is not tried after one.
static inline int dotmeter_proc_usage(int pid, dotmeter_proc_usage_t *out) {
    struct rusage_info_v6 six;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&six) == 0) {
        out->start = six.ri_proc_start_abstime;
        out->cpu_time = six.ri_user_time + six.ri_system_time;
        out->footprint = six.ri_phys_footprint;
        out->disk_read = six.ri_diskio_bytesread;
        out->disk_written = six.ri_diskio_byteswritten;
        out->energy_nj = six.ri_energy_nj;
        out->has_energy = 1;
        return 0;
    }
    if (errno == EPERM) return -2;
    if (errno == ESRCH) return -1;
    struct rusage_info_v4 four;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&four) == 0) {
        out->start = four.ri_proc_start_abstime;
        out->cpu_time = four.ri_user_time + four.ri_system_time;
        out->footprint = four.ri_phys_footprint;
        out->disk_read = four.ri_diskio_bytesread;
        out->disk_written = four.ri_diskio_byteswritten;
        out->energy_nj = 0;
        out->has_energy = 0;
        return 0;
    }
    return errno == EPERM ? -2 : -1;
}

// APFS lets several files share the same blocks (clones). `private_size` is what deleting this one file would free;
// `ref_count` above 1 means its blocks are shared, and `clone_id` is the same for every file sharing them.
#include <sys/attr.h>
#include <unistd.h>

typedef struct {
    uint64_t clone_id;
    int64_t  private_size;
    uint32_t ref_count;
} dotmeter_clone_info_t;

static inline int dotmeter_clone_info(const char *path, dotmeter_clone_info_t *out) {
    struct attrlist request = {0};
    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;
    struct {
        uint32_t length;
        off_t    private_size;
        uint64_t clone_id;
        uint32_t ref_count;
    } __attribute__((aligned(4), packed)) reply = {0};
    if (getattrlist(path, &request, &reply, sizeof(reply), FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) != 0) return -1;
    if (reply.length < sizeof(reply)) return -1;
    out->clone_id = reply.clone_id;
    out->private_size = reply.private_size;
    out->ref_count = reply.ref_count;
    return 0;
}

// Network interfaces. getifaddrs only exposes 32-bit byte counters, which wrap every 4 GB; the routing
// sysctl carries the kernel's 64-bit ones, along with link speed, MTU and the hardware address.
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_media.h>
#include <net/if_var.h>
#include <net/route.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

typedef struct {
    char     name[IFNAMSIZ];
    uint32_t flags;
    uint32_t type;
    uint32_t mtu;
    uint64_t baudrate;
    uint64_t ibytes;
    uint64_t obytes;
    uint64_t ipackets;
    uint64_t opackets;
    uint64_t ierrors;
    uint64_t oerrors;
    uint8_t  mac[6];
    uint8_t  mac_length;
} dotmeter_interface_t;

// Fills up to `capacity` entries and returns how many there are, or -1 when the kernel could not be asked.
static inline int dotmeter_interfaces(dotmeter_interface_t *out, int capacity) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length == 0) return -1;
    length += length / 4;
    char *buffer = (char *)malloc(length);
    if (buffer == NULL) return -1;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) { free(buffer); return -1; }
    int count = 0;
    char *end = buffer + length;
    for (char *cursor = buffer; cursor + sizeof(struct if_msghdr) <= end && count < capacity; ) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (header->ifm_msglen == 0) break;
        if (header->ifm_type == RTM_IFINFO2 && cursor + sizeof(struct if_msghdr2) + sizeof(struct sockaddr_dl) <= end) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)cursor;
            struct sockaddr_dl *link = (struct sockaddr_dl *)(info + 1);
            dotmeter_interface_t *entry = &out[count];
            memset(entry, 0, sizeof(*entry));
            size_t n = link->sdl_nlen < IFNAMSIZ - 1 ? link->sdl_nlen : IFNAMSIZ - 1;
            memcpy(entry->name, link->sdl_data, n);
            entry->flags = (uint32_t)info->ifm_flags;
            entry->type = info->ifm_data.ifi_type;
            entry->mtu = info->ifm_data.ifi_mtu;
            entry->baudrate = info->ifm_data.ifi_baudrate;
            entry->ibytes = info->ifm_data.ifi_ibytes;
            entry->obytes = info->ifm_data.ifi_obytes;
            entry->ipackets = info->ifm_data.ifi_ipackets;
            entry->opackets = info->ifm_data.ifi_opackets;
            entry->ierrors = info->ifm_data.ifi_ierrors;
            entry->oerrors = info->ifm_data.ifi_oerrors;
            if (link->sdl_alen == 6) {
                memcpy(entry->mac, LLADDR(link), 6);
                entry->mac_length = 6;
            }
            count++;
        }
        cursor += header->ifm_msglen;
    }
    free(buffer);
    return count;
}

// Whether an interface has a carrier (a cable plugged in and negotiated, a Wi-Fi network joined).
// Returns -1 for interfaces that have no media to report, such as tunnels.
static inline int dotmeter_interface_media(const char *name, int *active, int *full_duplex) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct ifmediareq request;
    memset(&request, 0, sizeof(request));
    strlcpy(request.ifm_name, name, sizeof(request.ifm_name));
    int result = ioctl(fd, SIOCGIFMEDIA, &request);
    close(fd);
    if (result != 0 || (request.ifm_status & IFM_AVALID) == 0) return -1;
    *active = (request.ifm_status & IFM_ACTIVE) != 0;
    *full_duplex = (request.ifm_active & IFM_FDX) != 0;
    return 0;
}

// IOReport: the energy counters behind powermetrics, readable without privileges. It ships with macOS but
// has no public header.
#include <CoreFoundation/CoreFoundation.h>
typedef struct __IOReportSubscription *IOReportSubscriptionRef;
CF_RETURNS_RETAINED CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subscribed, uint64_t channel, CFTypeRef b);
CF_RETURNS_RETAINED CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef subscribed, CFTypeRef a);
CF_RETURNS_RETAINED CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current, CFTypeRef a);
CF_RETURNS_NOT_RETAINED CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
CF_RETURNS_NOT_RETAINED CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t *error);

// One ICMP echo over an unprivileged datagram socket. Returns 0 and the round trip in milliseconds,
// 1 when nothing came back in time, or -1 with errno set when it could not be sent at all.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <poll.h>
#include <time.h>

static inline uint16_t dotmeter_checksum(const uint8_t *data, size_t length) {
    uint32_t sum = 0;
    for (size_t i = 0; i + 1 < length; i += 2) sum += (uint32_t)((data[i] << 8) | data[i + 1]);
    if (length & 1) sum += (uint32_t)(data[length - 1] << 8);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

static inline int dotmeter_ping(const char *address, int timeout_ms, uint16_t sequence, double *milliseconds) {
    struct sockaddr_in to;
    memset(&to, 0, sizeof(to));
    to.sin_len = sizeof(to);
    to.sin_family = AF_INET;
    if (inet_pton(AF_INET, address, &to.sin_addr) != 1) { errno = EINVAL; return -1; }
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) return -1;

    uint8_t packet[32];
    memset(packet, 0, sizeof(packet));
    packet[0] = ICMP_ECHO;
    uint16_t identifier = (uint16_t)(getpid() & 0xffff);
    packet[4] = (uint8_t)(identifier >> 8);
    packet[5] = (uint8_t)(identifier & 0xff);
    packet[6] = (uint8_t)(sequence >> 8);
    packet[7] = (uint8_t)(sequence & 0xff);
    for (int i = 8; i < 32; i++) packet[i] = (uint8_t)i;
    uint16_t sum = dotmeter_checksum(packet, sizeof(packet));
    packet[2] = (uint8_t)(sum >> 8);
    packet[3] = (uint8_t)(sum & 0xff);

    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (sendto(fd, packet, sizeof(packet), 0, (struct sockaddr *)&to, sizeof(to)) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    int result = 1;
    for (;;) {
        int64_t left = (int64_t)timeout_ms - (int64_t)((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1000000);
        if (left <= 0) break;
        struct pollfd waiting = { fd, POLLIN, 0 };
        if (poll(&waiting, 1, (int)left) <= 0) break;
        uint8_t reply[256];
        ssize_t n = recv(fd, reply, sizeof(reply), 0);
        if (n < 8) continue;
        // The reply arrives with its IP header in front.
        size_t header = (reply[0] >> 4) == 4 ? (size_t)(reply[0] & 0x0f) * 4 : 0;
        if ((size_t)n < header + 8) continue;
        const uint8_t *icmp = reply + header;
        if (icmp[0] != ICMP_ECHOREPLY) continue;
        if ((uint16_t)((icmp[6] << 8) | icmp[7]) != sequence) continue;
        *milliseconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6;
        result = 0;
        break;
    }
    close(fd);
    return result;
}

// The NVMe SMART log, read through a plug-in interface that only C can call.
#include "DotmeterSMART.h"

#endif
