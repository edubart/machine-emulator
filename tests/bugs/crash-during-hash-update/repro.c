// A process killed while it updates the hash tree of a machine loaded with CM_SHARING_ALL leaves the directory with
// a hash tree that disagrees with its own data (HT-1) or that can no longer be hashed at all (HT-4).
//
// With sharing:all, the dense hash trees (.dht), dirty page trees (.dpt), sparse tree (hash_tree.sht) and page
// hash-tree cache (hash_tree.phtc) are MAP_SHARED files, so a partial update survives SIGKILL:
//   - HT-1: new page hashes are written into the shared dense-tree leaves before the inner nodes are recomputed and
//     before the pages are marked clean. On reload the pages are still dirty, but their leaves already "match", so
//     the pages are marked clean without propagating the change: the root hash is permanently wrong. Persisted
//     "marked" flags of the sparse tree have the same effect.
//   - HT-4: cache entries borrowed by the interrupted update stay "borrowed" in hash_tree.phtc. Hashing then fails
//     with "page hash-tree cache entry already borrowed" (forever), or with "update hash tree failed", after which a
//     retry returns a wrong root hash.
//
// The test creates a small stored machine, then repeatedly runs a child process that loads it with CM_SHARING_ALL,
// writes every RAM page and calls cm_get_root_hash(); the parent sends SIGKILL after a random delay. The directory is
// then reloaded (CM_SHARING_ALL, as its owner would) and cm_get_root_hash() is compared with the root hash of a fresh
// machine built from the directory's RAM data file only (no hash-tree files), i.e. a from-scratch hash of the bytes on
// disk. Fixed behavior: every reload returns that hash.
//
// Usage: repro <work-dir>                 (exit 1 = bug present, 0 = fixed, 77 = no kill landed, 2 = test error)
//        repro --child <dir> <pipe-fd>    (internal)
#define _GNU_SOURCE
#include <cm.h>
#include <dirent.h>
#include <inttypes.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define RAM_START UINT64_C(0x80000000)
#define RAM_LENGTH (UINT64_C(32) << 20) // 32 MiB = 8192 pages: two batches of the default 4096-entry page cache
#define MAX_ATTEMPTS 8
#define MIN_LANDED_FOR_OK 3     // an "OK" verdict needs at least this many kills that landed during the update
#define STOP_AFTER_BUGS 3       // stop early once the bug was observed this many times
#define TIME_BUDGET_SECONDS 40. // no new attempt is started after this much time

static char g_cfg[256];

static void die(const char *what) {
    fprintf(stderr, "test error: %s: %s\n", what, cm_get_last_error_message());
    exit(2);
}
#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            die(#x);                                                                                                   \
        }                                                                                                              \
    } while (0)

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + 1e-9 * (double) ts.tv_nsec;
}

static const char *short_hex(const cm_hash *h) {
    static char buf[2][24];
    static int k = 0;
    k ^= 1;
    for (int i = 0; i < 8; ++i) {
        sprintf(buf[k] + 2 * i, "%02x", (*h)[i]);
    }
    strcat(buf[k], "...");
    return buf[k];
}

// Writes a non-zero, page-dependent pattern over the whole RAM (dirties every RAM page)
static void fill_ram(cm_machine *m) {
    uint64_t *buf = malloc(RAM_LENGTH);
    if (!buf) {
        exit(2);
    }
    for (uint64_t i = 0; i < RAM_LENGTH / 8; ++i) {
        buf[i] = (i * UINT64_C(0x9e3779b97f4a7c15)) | 1;
    }
    CHK(cm_write_memory(m, RAM_START, (const uint8_t *) buf, RAM_LENGTH));
    free(buf);
}

// Child: load with sharing:all, write all of RAM, report "ready", hash, report the duration of the hash.
static int child(const char *dir, int fd) {
    cm_machine *m = NULL;
    CHK(cm_load_new(dir, NULL, CM_SHARING_ALL, &m));
    fill_ram(m);
    if (write(fd, "R", 1) != 1) {
        return 2;
    }
    const double t0 = now();
    cm_hash h;
    CHK(cm_get_root_hash(m, &h));
    char msg[64];
    const int n = snprintf(msg, sizeof msg, "D%.6f", now() - t0);
    if (write(fd, msg, (size_t) n) != n) {
        return 2;
    }
    cm_delete(m);
    return 0;
}

// Stored machine directories are flat
static void remove_dir(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) {
        return;
    }
    char fn[PATH_MAX];
    for (struct dirent *e = readdir(d); e; e = readdir(d)) {
        if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0) {
            snprintf(fn, sizeof fn, "%s/%s", dir, e->d_name);
            unlink(fn);
        }
    }
    closedir(d);
    rmdir(dir);
}

// Creates the stored machine with a directory (all backing stores in the directory) and a clean hash tree
static void make_stored(const char *dir) {
    remove_dir(dir);
    cm_machine *m = NULL;
    CHK(cm_create_new(g_cfg, NULL, dir, &m));
    cm_hash h;
    CHK(cm_get_root_hash(m, &h));
    cm_delete(m);
}

// Runs one child session. If delay >= 0, sends SIGKILL `delay` seconds after the child started cm_get_root_hash.
// Returns true if the child completed cm_get_root_hash (so the kill, if any, did not land during the update).
static bool session(const char *self, const char *dir, double delay, double *duration) {
    int p[2];
    if (pipe(p) != 0) {
        exit(2);
    }
    const pid_t parent = getpid();
    const pid_t pid = fork();
    if (pid < 0) {
        exit(2);
    }
    if (pid == 0) {
        prctl(PR_SET_PDEATHSIG, SIGKILL); // never outlive the test
        if (getppid() != parent) {
            _exit(2);
        }
        close(p[0]);
        char fd[16];
        snprintf(fd, sizeof fd, "%d", p[1]);
        // exec a fresh image: the library's OpenMP thread pool does not survive fork()
        execl(self, self, "--child", dir, fd, (char *) NULL);
        _exit(127);
    }
    close(p[1]);
    char c = 0;
    if (read(p[0], &c, 1) != 1 || c != 'R') {
        fprintf(stderr, "test error: child failed before starting the hash\n");
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        exit(2);
    }
    if (delay >= 0) {
        struct timespec ts = {.tv_sec = (time_t) delay, .tv_nsec = (long) ((delay - (double) (time_t) delay) * 1e9)};
        nanosleep(&ts, NULL);
        kill(pid, SIGKILL);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    char buf[64] = {0};
    const ssize_t n = read(p[0], buf, sizeof buf - 1);
    close(p[0]);
    const bool done = n > 0 && buf[0] == 'D';
    if (done && duration) {
        *duration = atof(buf + 1);
    }
    if (delay < 0 && (!WIFEXITED(st) || WEXITSTATUS(st) != 0)) {
        fprintf(stderr, "test error: uninterrupted child session failed\n");
        exit(2);
    }
    return done;
}

// Reference: a fresh machine built from the directory's RAM data file only (private mapping, no dht/dpt/sht/phtc).
// Nothing but RAM differs from the default configuration, so this is a from-scratch hash of the bytes on disk.
static void hash_from_data_files(const char *dir, cm_hash *out) {
    char fn[PATH_MAX];
    snprintf(fn, sizeof fn, "%s/%016" PRIx64 "-%" PRIx64 ".bin", dir, RAM_START, RAM_LENGTH);
    struct stat sb;
    if (stat(fn, &sb) != 0 || (uint64_t) sb.st_size != RAM_LENGTH) {
        fprintf(stderr, "test error: RAM data file %s not found in the stored machine\n", fn);
        exit(2);
    }
    char cfg[PATH_MAX + 256];
    snprintf(cfg, sizeof cfg, "{\"ram\":{\"length\":%" PRIu64 ",\"backing_store\":{\"data_filename\":\"%s\"}}}",
        RAM_LENGTH, fn);
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    CHK(cm_get_root_hash(m, out));
    cm_delete(m);
}

enum outcome { CONSISTENT, WRONG_HASH, UNUSABLE };

// Reloads the directory as its owner would (sharing:all) and checks cm_get_root_hash against the data files.
static enum outcome check_reload(const char *dir, const cm_hash *expected, bool *already_borrowed) {
    cm_hash ref;
    hash_from_data_files(dir, &ref);
    if (memcmp(ref, *expected, sizeof ref) != 0) {
        printf("test error: data written by the child is not on disk\n");
        exit(2);
    }
    cm_machine *m = NULL;
    if (cm_load_new(dir, NULL, CM_SHARING_ALL, &m) != CM_ERROR_OK) {
        printf("reload FAILS: cm_load_new: \"%s\"\n", cm_get_last_error_message());
        return UNUSABLE;
    }
    enum outcome res = CONSISTENT;
    cm_hash h;
    if (cm_get_root_hash(m, &h) != CM_ERROR_OK) {
        const char *msg = cm_get_last_error_message();
        *already_borrowed = *already_borrowed || strstr(msg, "already borrowed") != NULL;
        printf("reload: cm_get_root_hash FAILS (\"%s\"); retry: ", msg);
        res = UNUSABLE;
        // retry in the same process, as the owner would
        if (cm_get_root_hash(m, &h) != CM_ERROR_OK) {
            printf("FAILS again (\"%s\")\n", cm_get_last_error_message());
        } else if (memcmp(h, ref, sizeof h) != 0) {
            printf("returns a WRONG root hash %s (data files hash to %s)\n", short_hex(&h), short_hex(&ref));
            res = WRONG_HASH;
        } else {
            printf("returns the correct root hash\n");
        }
    } else if (memcmp(h, ref, sizeof h) != 0) {
        printf("reload: root hash is WRONG: %s, data files hash to %s\n", short_hex(&h), short_hex(&ref));
        res = WRONG_HASH;
    } else {
        printf("reload: root hash matches the data files\n");
    }
    cm_delete(m);
    return res;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--child") == 0) {
        return child(argv[2], atoi(argv[3]));
    }
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    const double start = now();
    char self[PATH_MAX];
    const ssize_t len = readlink("/proc/self/exe", self, sizeof self - 1);
    if (len <= 0) {
        return 2;
    }
    self[len] = 0;
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/machine", argv[1]);
    snprintf(g_cfg, sizeof g_cfg, "{\"ram\":{\"length\":%" PRIu64 "}}", RAM_LENGTH);

    // Expected root hash: the same writes on an in-memory machine
    cm_hash expected;
    {
        cm_machine *m = NULL;
        CHK(cm_create_new(g_cfg, NULL, NULL, &m));
        fill_ram(m);
        CHK(cm_get_root_hash(m, &expected));
        cm_delete(m);
    }

    // Control: an uninterrupted session must reload consistently (validates the harness and gives the duration)
    make_stored(dir);
    double duration = 0;
    session(self, dir, -1, &duration);
    bool already_borrowed = false;
    printf("control (no kill), cm_get_root_hash took %.0f ms: ", duration * 1e3);
    if (check_reload(dir, &expected, &already_borrowed) != CONSISTENT) {
        printf("test error: an uninterrupted session does not reload consistently\n");
        return 2;
    }

    const unsigned seed = (unsigned) time(NULL) ^ (unsigned) getpid();
    srand(seed);
    printf("random seed %u\n", seed);
    int attempts = 0, landed = 0, wrong = 0, unusable = 0;
    double scale = 1.0;
    while (attempts < MAX_ATTEMPTS && wrong + unusable < STOP_AFTER_BUGS && now() - start < TIME_BUDGET_SECONDS) {
        ++attempts;
        make_stored(dir);
        // kill somewhere inside the update (5%..90% of the measured duration)
        const double delay = duration * scale * (0.05 + 0.85 * (rand() / (double) RAND_MAX));
        printf("attempt %d: SIGKILL %.0f ms into cm_get_root_hash: ", attempts, delay * 1e3);
        fflush(stdout);
        if (session(self, dir, delay, NULL)) {
            printf("child finished first (not counted)\n");
            scale *= 0.6; // the host is faster than measured: kill earlier
            continue;
        }
        ++landed;
        switch (check_reload(dir, &expected, &already_borrowed)) {
            case WRONG_HASH:
                ++wrong;
                break;
            case UNUSABLE:
                ++unusable;
                break;
            default:
                break;
        }
    }
    remove_dir(dir);
    printf("summary: %d attempts, %d kills landed during the update: %d reloads with a wrong root hash, %d "
           "unusable reloads%s\n",
        attempts, landed, wrong, unusable,
        already_borrowed ? " (\"page hash-tree cache entry already borrowed\" observed)" : "");
    if (wrong + unusable > 0) {
        printf("BUG REPRODUCED: a process killed during cm_get_root_hash leaves the sharing:all directory with a hash "
               "tree that %s\n",
            wrong > 0 && unusable > 0 ? "disagrees with its own data or can no longer be hashed"
                : wrong > 0           ? "disagrees with its own data"
                                      : "can no longer be hashed");
        return 1;
    }
    if (landed < MIN_LANDED_FOR_OK) {
        printf("SKIP: only %d kills landed during the update (need %d)\n", landed, MIN_LANDED_FOR_OK);
        return 77;
    }
    printf("OK: all %d directories killed during cm_get_root_hash reload with the root hash of their data files\n",
        landed);
    return 0;
}
