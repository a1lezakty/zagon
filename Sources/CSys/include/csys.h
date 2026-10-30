#ifndef ZAGON_CSYS_H
#define ZAGON_CSYS_H
#include <stddef.h>
#include <sys/stat.h>
#include <dirent.h>
#include <poll.h>
#ifdef __linux__
#include <sys/inotify.h>
#endif

/// memmem(3) is not visible to Swift on every libc; thin wrapper.
const void *z_memmem(const void *haystack, size_t hl, const void *needle, size_t nl);

/// Gives the calling thread's freed heap back to the system (mimalloc in the static build, glibc malloc_trim).
void z_release_memory(void);

/// posix_fadvise(DONTNEED) on Linux: forget the cached pages of a file read or written once.
void z_drop_cache(int fd);

/// Calling thread to nice 10 and the idle I/O class (Linux; no-op elsewhere).
void z_background_thread(void);

/// File-system identity of the calling thread only (Linux setfsuid / setfsgid / setgroups as raw syscalls, so other
/// threads keep theirs): files are then created and checked as `uid`, without root's file capabilities.
/// Returns 0, or -1 if not switched (also on other systems). `z_as_root` switches back.
int z_as_user(unsigned uid, unsigned gid);
void z_as_root(void);

#endif
