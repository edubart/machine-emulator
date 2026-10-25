// LD_PRELOAD hook: after a successful FALLOC_FL_PUNCH_HOLE on the RAM dense hash tree file
// (0000000080000000-*.dht), SIGKILL the process. This simulates a process kill in the window
// between dense_hash_tree::clear() and dirty_page_tree::mark_dirty_pages_and_up() in hash_tree::clear().
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <linux/falloc.h>
typedef int (*fallocate_fn)(int, int, off_t, off_t);
static void maybe_kill(int fd, int mode, int result) {
    if (result != 0 || !(mode & FALLOC_FL_PUNCH_HOLE)) return;
    char link[64], path[4096];
    snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, path, sizeof path - 1);
    if (n <= 0) return;
    path[n] = 0;
    const char *target = getenv("KILL_AFTER_PUNCH_SUFFIX");
    if (!target) target = ".dht";
    if (strstr(path, "/0000000080000000-") && strstr(path, target)) {
        fprintf(stderr, "[hook] punched hole in %s; SIGKILL now\n", path);
        fflush(stderr);
        kill(getpid(), SIGKILL);
    }
}
int fallocate(int fd, int mode, off_t off, off_t len) {
    static fallocate_fn real;
    if (!real) real = (fallocate_fn)dlsym(RTLD_NEXT, "fallocate");
    int r = real(fd, mode, off, len);
    maybe_kill(fd, mode, r);
    return r;
}
int fallocate64(int fd, int mode, off_t off, off_t len) {
    static fallocate_fn real;
    if (!real) real = (fallocate_fn)dlsym(RTLD_NEXT, "fallocate64");
    int r = real(fd, mode, off, len);
    maybe_kill(fd, mode, r);
    return r;
}
