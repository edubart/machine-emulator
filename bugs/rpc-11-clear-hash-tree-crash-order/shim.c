#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
/* Crash injector: once the file named by $CRASH_ARM exists, count punch-hole fallocate calls
   and SIGKILL the process right after the $CRASH_AFTER-th one returns. */
static int count = 0;
static int hook(int fd, int mode, long long off, long long len, int r) {
    const char *arm = getenv("CRASH_ARM");
    if (arm && access(arm, F_OK) == 0 && (mode & FALLOC_FL_PUNCH_HOLE)) {
        int n = atoi(getenv("CRASH_AFTER") ? getenv("CRASH_AFTER") : "1");
        if (++count >= n) {
            char b[128]; int k = snprintf(b, sizeof b, "shim: SIGKILL after punch-hole #%d (fd=%d len=%lld)\n", count, fd, len);
            write(2, b, k);
            raise(SIGKILL);
        }
    }
    return r;
}
int fallocate64(int fd, int mode, off_t off, off_t len) {
    static int (*real)(int, int, off_t, off_t);
    if (!real) real = dlsym(RTLD_NEXT, "fallocate64");
    int r = real(fd, mode, off, len);
    return hook(fd, mode, off, len, r);
}
int fallocate(int fd, int mode, off_t off, off_t len) {
    static int (*real)(int, int, off_t, off_t);
    if (!real) real = dlsym(RTLD_NEXT, "fallocate");
    int r = real(fd, mode, off, len);
    return hook(fd, mode, off, len, r);
}
