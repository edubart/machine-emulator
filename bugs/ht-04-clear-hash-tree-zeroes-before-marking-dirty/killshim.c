// LD_PRELOAD shim: forwards fallocate() to libc, then, if the call punched a hole in the file whose
// path contains $KILL_AFTER_PUNCH_OF, SIGKILLs the process. This reproduces a real process kill at the
// exact point inside hash_tree::clear() between dense_hash_tree().clear() and mark_dirty_pages_and_up().
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void maybe_kill(int fd, int mode, int result) {
    const char *pat = getenv("KILL_AFTER_PUNCH_OF");
    if (!pat || result != 0 || !(mode & FALLOC_FL_PUNCH_HOLE)) return;
    char link[64], path[4096];
    snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, path, sizeof path - 1);
    if (n <= 0) return;
    path[n] = 0;
    if (strstr(path, pat)) {
        fprintf(stderr, "shim: punched %s, sending SIGKILL\n", path);
        kill(getpid(), SIGKILL);
    }
}
int fallocate64(int fd, int mode, off_t off, off_t len) {
    static int (*real)(int, int, off_t, off_t);
    if (!real) real = (int (*)(int, int, off_t, off_t))dlsym(RTLD_NEXT, "fallocate64");
    int r = real(fd, mode, off, len);
    maybe_kill(fd, mode, r);
    return r;
}
int fallocate(int fd, int mode, off_t off, off_t len) { return fallocate64(fd, mode, off, len); }
