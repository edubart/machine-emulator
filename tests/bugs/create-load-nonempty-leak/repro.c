// cm_create()/cm_load() on a machine object that already holds a machine instance overwrite the
// instance pointer without releasing the previous instance (src/local-machine.cpp do_create/do_load).
// The previous machine is leaked together with its file descriptors, mappings and backing-file locks:
// after cm_delete() the object's shared backing file stays locked for the rest of the process, so the
// same machine can no longer be created again. The JSON-RPC server rejects the call ("machine exists").
// Property checked: after cm_delete(), every resource of the object is released, i.e. a machine that
// shares the same backing file can be created again and the number of open descriptors is back to normal.
// Usage: repro <work-dir>
#include <dirent.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

#define RAM_START 0x80000000ULL
#define FLASH_LENGTH 4096

static char cfg_shared[1024];
static const char *cfg_plain = "{\"ram\":{\"length\":4096}}";

static int count_fds(void) {
    DIR *d = opendir("/proc/self/fd");
    if (d == NULL) {
        return -1;
    }
    int n = 0;
    while (readdir(d) != NULL) {
        n++;
    }
    closedir(d);
    return n;
}

// Can a machine sharing the flash backing file be created (i.e. is the file not locked by a leaked machine)?
static int can_create_shared(void) {
    cm_machine *m = NULL;
    if (cm_create_new(cfg_shared, NULL, NULL, &m) != CM_ERROR_OK) {
        printf("  creating a machine that shares the flash file again failed: %s\n", cm_get_last_error_message());
        return 0;
    }
    cm_delete(m);
    return 1;
}

// Create a machine sharing the flash file in a fresh object, then call create/load on it again.
// Runs in a forked child (a leaked lock would otherwise persist into the next scenario).
static int scenario(const char *name, const char *stored_dir) {
    printf("%s on a non-empty machine object:\n", name);
    if (stored_dir != NULL) { // a small stored machine to load
        cm_machine *s = NULL;
        if (cm_create_new(cfg_plain, NULL, NULL, &s) != CM_ERROR_OK || cm_store(s, stored_dir, CM_SHARING_ALL) != CM_ERROR_OK) {
            fprintf(stderr, "setup failed: %s\n", cm_get_last_error_message());
            exit(2);
        }
        cm_delete(s);
    }
    // warm-up (lazily opened library descriptors), then baseline
    if (!can_create_shared()) {
        exit(2);
    }
    int baseline_fds = count_fds();
    cm_machine *m = NULL;
    if (cm_new(&m) != CM_ERROR_OK || cm_create(m, cfg_shared, NULL, NULL) != CM_ERROR_OK ||
        cm_write_word(m, RAM_START, 0x1234) != CM_ERROR_OK) {
        fprintf(stderr, "setup failed: %s\n", cm_get_last_error_message());
        exit(2);
    }
    cm_error e = stored_dir != NULL ? cm_load(m, stored_dir, NULL, CM_SHARING_NONE) : cm_create(m, cfg_plain, NULL, NULL);
    printf("  second call returned %d (%s)\n", (int) e, e != CM_ERROR_OK ? cm_get_last_error_message() : "success");
    if (e == CM_ERROR_OK) {
        uint64_t w = 0;
        cm_read_word(m, RAM_START, &w);
        printf("  word written to the first instance now reads 0x%" PRIx64 " (first instance replaced)\n", w);
    }
    cm_delete(m);
    int fds = count_fds();
    printf("  open descriptors after cm_delete: %d (baseline %d)\n", fds, baseline_fds);
    int ok = can_create_shared();
    if (fds != baseline_fds) {
        ok = 0;
    }
    printf("  resources released: %s\n", ok ? "yes" : "NO (previous instance leaked)");
    return ok;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    char flash[512], stored[512];
    snprintf(flash, sizeof flash, "%s/shared-flash.bin", argv[1]);
    snprintf(stored, sizeof stored, "%s/stored", argv[1]);
    snprintf(cfg_shared, sizeof cfg_shared,
        "{\"ram\":{\"length\":4096},\"flash_drive\":[{\"length\":%d,"
        "\"backing_store\":{\"data_filename\":\"%s\",\"shared\":true}}]}",
        FLASH_LENGTH, flash);
    FILE *f = fopen(flash, "wb");
    if (f == NULL) {
        perror("fopen");
        return 2;
    }
    static const char zeros[FLASH_LENGTH];
    if (fwrite(zeros, 1, sizeof zeros, f) != sizeof zeros || fclose(f) != 0) {
        perror("fwrite");
        return 2;
    }
    // The parent does not call into the library before forking (fork safety of its worker threads).
    int bug = 0;
    for (int i = 0; i < 2; i++) {
        pid_t p = fork();
        if (p < 0) {
            perror("fork");
            return 2;
        }
        if (p == 0) {
            _exit(i == 0 ? !scenario("cm_create", NULL) : !scenario("cm_load", stored));
        }
        int st = 0;
        if (waitpid(p, &st, 0) != p || !WIFEXITED(st) || WEXITSTATUS(st) > 1) {
            fprintf(stderr, "scenario %d failed to run (status 0x%x)\n", i, st);
            return 2;
        }
        bug |= WEXITSTATUS(st);
    }
    if (bug) {
        printf("BUG REPRODUCED: cm_create/cm_load on a non-empty machine object leak the previous machine "
               "instance (descriptors and backing-file locks stay held after cm_delete)\n");
        return 1;
    }
    printf("OK: cm_create/cm_load on a non-empty machine object do not leak the previous instance\n");
    return 0;
}
