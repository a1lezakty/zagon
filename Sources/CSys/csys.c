#define _GNU_SOURCE
#include <string.h>
#include "csys.h"

const void *z_memmem(const void *h, size_t hl, const void *n, size_t nl) { return memmem(h, hl, n, nl); }

#include <stdbool.h>
#if defined(__linux__)
/* The static Linux SDK links mimalloc, which keeps freed pages of a thread's heap until that thread allocates again:
   an idle daemon would hold the peak of its last pass. Weak, so glibc builds link without it (ELF only: Mach-O
   needs every undefined symbol at link time). */
extern void mi_collect(bool force) __attribute__((weak));
#endif
#ifdef __GLIBC__
#include <malloc.h>
#endif
#ifdef __APPLE__
#include <malloc/malloc.h>
#endif
void z_release_memory(void) {
#if defined(__linux__)
    if (mi_collect) { mi_collect(true); return; }
#endif
#if defined(__GLIBC__)
    malloc_trim(0);
#elif defined(__APPLE__)
    malloc_zone_pressure_relief(NULL, 0);
#endif
}

#ifdef __linux__
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
/* Lowers the CPU (nice 10) and I/O (idle class) priority of the calling thread only (Linux keeps both per thread). */
void z_background_thread(void) {
    setpriority(PRIO_PROCESS, 0, 10);
    syscall(SYS_ioprio_set, 1 /* IOPRIO_WHO_PROCESS */, 0, 3 << 13 /* IOPRIO_CLASS_IDLE */);
}
#else
void z_background_thread(void) {}
#endif

#include <fcntl.h>
/* Drops the page cache of a file we are done with (a full pass reads gigabytes once; the service's cgroup would carry
   them). Linux only; a hint, errors ignored. */
void z_drop_cache(int fd) {
#ifdef __linux__
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
#else
    (void)fd;
#endif
}

#ifdef __linux__
#include <sys/syscall.h>
#include <unistd.h>
static __thread gid_t saved_groups[256];
static __thread long saved_count = -1;
int z_as_user(unsigned uid, unsigned gid) {
    gid_t g = gid;
    saved_count = syscall(SYS_getgroups, 256, saved_groups);
    if (saved_count < 0 || syscall(SYS_setgroups, 1, &g) != 0) return -1;
    syscall(SYS_setfsgid, gid);
    syscall(SYS_setfsuid, uid);
    /* both calls return the previous id; asking with -1 (invalid) reports the current one */
    if ((unsigned)syscall(SYS_setfsuid, -1) != uid || (unsigned)syscall(SYS_setfsgid, -1) != gid) { z_as_root(); return -1; }
    return 0;
}
void z_as_root(void) {
    syscall(SYS_setfsuid, 0);
    syscall(SYS_setfsgid, 0);
    if (saved_count >= 0) syscall(SYS_setgroups, saved_count, saved_groups);
}
#else
int z_as_user(unsigned uid, unsigned gid) { (void)uid; (void)gid; return -1; }
void z_as_root(void) {}
#endif
