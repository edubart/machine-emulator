// LD_PRELOAD shim: make ioctl(FICLONE) fail with errno from FICLONE_SHIM_ERRNO.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <linux/fs.h>
int ioctl(int fd, unsigned long req, ...) {
    va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
    const char *e = getenv("FICLONE_SHIM_ERRNO");
    if (req == FICLONE && e) { errno = atoi(e); return -1; }
    static int (*real)(int, unsigned long, ...) = 0;
    if (!real) real = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
    return real(fd, req, arg);
}
