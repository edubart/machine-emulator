// LD_PRELOAD shim: SIGKILLs the process after KILL_AFTER_PHTC_WRITES pwrite() calls to a file
// whose path ends in "hash_tree.phtc". Simulates a node killed (OOM, crash, power-off of process,
// container stop) while cm_store()/cm_clone_stored() is writing the page hash-tree cache file.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
static long count = 0;
static int is_phtc(int fd) {
    char link[64], path[4096];
    snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, path, sizeof path - 1);
    if (n <= 0) return 0;
    path[n] = 0;
    const char *suf = "hash_tree.phtc";
    size_t ls = strlen(suf);
    return (size_t)n >= ls && strcmp(path + n - ls, suf) == 0;
}
static void maybe_kill(int fd) {
    const char *s = getenv("KILL_AFTER_PHTC_WRITES");
    if (!s || !is_phtc(fd)) return;
    if (++count > atol(s)) kill(getpid(), SIGKILL);
}
ssize_t pwrite(int fd, const void *buf, size_t n, off_t off) {
    static ssize_t (*real)(int, const void *, size_t, off_t);
    if (!real) real = dlsym(RTLD_NEXT, "pwrite");
    maybe_kill(fd);
    return real(fd, buf, n, off);
}
ssize_t pwrite64(int fd, const void *buf, size_t n, off_t off) {
    static ssize_t (*real)(int, const void *, size_t, off_t);
    if (!real) real = dlsym(RTLD_NEXT, "pwrite64");
    maybe_kill(fd);
    return real(fd, buf, n, off);
}
