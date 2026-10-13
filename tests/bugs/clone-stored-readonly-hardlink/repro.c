// cm_clone_stored() decides between hard link and reflink/copy from the permission bits of each stored file
// (os::clone_file: no write bit -> hard link), not from whether the address range is writable. When the files
// of a stored machine are read-only on disk (an operator protected a template with chmod a-w, or it comes from
// a read-only package), the clone's RAM data and hash-tree files are hard links to the source's. A
// CM_SHARING_ALL load of the clone maps them O_RDWR + MAP_SHARED (this works for a process with
// CAP_DAC_OVERRIDE, e.g. root), so running the clone writes through to the source stored machine.
//
// Scenarios (each in its own subdirectory of <work-dir>):
//   all: every file of the stored machine is made read-only (the source then loads with the clone's new root);
//   ram: only the RAM data file is made read-only (silent: the source still loads with its original root,
//        because its own hash-tree files were copied, but its RAM data changed).
// Checks, after running the clone:
//   - every file of the source directory is byte-for-byte unchanged;
//   - the source still loads (CM_SHARING_NONE) with its original root hash;
//   - the loaded source's hash tree matches its data (cm_verify_hash_tree).
// Without the privilege to open read-only files for writing, the SHARING_ALL load of such a clone fails
// (EACCES) before anything is written, so the write-through cannot be observed. The test then checks the cause
// directly: no file of the clone that a SHARING_ALL load maps writable (everything except config.json and the
// files the emulator itself stored read-only) may share its inode with the source.
//
// Usage: repro <work-dir>
// Exit 1 + "BUG REPRODUCED" while the defect is present, 0 + "OK" once fixed, 77 when it cannot be checked,
// 2 when the test itself fails.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cm.h>

#define RAM_START UINT64_C(0x80000000)
#define RAM_LENGTH UINT64_C(0x10000) // 64 KiB
#define MARKER_ADDR (RAM_START + 0x8000)
#define MARKER_INITIAL UINT64_C(0x5555555555555555)
#define MAX_FILES 64

// Hand-encoded RV64 guest (no cross toolchain needed): overwrite the marker word, then halt through HTIF.
static const uint32_t program[] = {
    0x00008297, // auipc t0, 0x8         t0 = 0x80008000 (MARKER_ADDR)
    0xfff00313, // addi  t1, zero, -1
    0x0062b023, // sd    t1, 0(t0)       marker = 0xffffffffffffffff
    0x400082b7, // lui   t0, 0x40008     t0 = 0x40008000 (HTIF tohost)
    0x00100313, // addi  t1, zero, 1
    0x0062b023, // sd    t1, 0(t0)       halt
    0x0000006f, // j     .
};

typedef struct {
    char name[256];
    int writable_at_store; // the emulator stored it writable (it belongs to a range a SHARING_ALL load writes)
    uint64_t digest;       // FNV-1a of the contents
} file_info;

static void fail(const char *what) {
    fprintf(stderr, "ERROR: %s: %s\n", what, cm_get_last_error_message());
    exit(2);
}

static void check(cm_error e, const char *what) {
    if (e != CM_ERROR_OK) {
        fail(what);
    }
}

static void path_of(char *out, size_t n, const char *dir, const char *name) {
    if ((size_t) snprintf(out, n, "%s/%s", dir, name) >= n) {
        fprintf(stderr, "ERROR: path too long\n");
        exit(2);
    }
}

static uint64_t file_digest(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    uint64_t h = UINT64_C(0xcbf29ce484222325);
    unsigned char buf[65536];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) {
        for (size_t i = 0; i < n; i++) {
            h = (h ^ buf[i]) * UINT64_C(0x100000001b3);
        }
    }
    fclose(f);
    return h;
}

static int list_files(const char *dir, file_info *files) {
    DIR *d = opendir(dir);
    if (!d) {
        perror(dir);
        exit(2);
    }
    int n = 0;
    struct dirent *e = NULL;
    while ((e = readdir(d)) != NULL) {
        char p[4096];
        struct stat st;
        path_of(p, sizeof p, dir, e->d_name);
        if (stat(p, &st) != 0 || !S_ISREG(st.st_mode)) {
            continue;
        }
        if (n == MAX_FILES || strlen(e->d_name) >= sizeof files[n].name) {
            fprintf(stderr, "ERROR: unexpected stored directory layout\n");
            exit(2);
        }
        strcpy(files[n].name, e->d_name);
        files[n].writable_at_store = (st.st_mode & 0222) != 0;
        files[n].digest = file_digest(p);
        n++;
    }
    closedir(d);
    return n;
}

static void make_read_only(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0 || chmod(path, st.st_mode & 07555) != 0) {
        perror(path);
        exit(2);
    }
}

static void hash_hex(const cm_hash *h, char *out) {
    for (int i = 0; i < 8; i++) {
        sprintf(out + 2 * i, "%02x", (*h)[i]);
    }
}

// Returns 1 (bug reproduced), 0 (OK) or 77 (cannot check)
static int scenario(const char *work_dir, const char *label) {
    char src[4096], dst[4096], ram_name[64], src_ram[4096], dst_ram[4096], hx[17];
    snprintf(src, sizeof src, "%s/%s-source", work_dir, label);
    snprintf(dst, sizeof dst, "%s/%s-clone", work_dir, label);
    snprintf(ram_name, sizeof ram_name, "%016" PRIx64 "-%" PRIx64 ".bin", RAM_START, RAM_LENGTH);
    path_of(src_ram, sizeof src_ram, src, ram_name);
    path_of(dst_ram, sizeof dst_ram, dst, ram_name);
    printf("=== scenario '%s': %s\n", label,
        strcmp(label, "all") == 0 ? "every file of the stored machine read-only"
                                  : "only the RAM data file of the stored machine read-only");

    // 1. Store a tiny machine (hashed before storing, so its stored hash tree is clean)
    cm_machine *m = NULL;
    const char *config = "{\"ram\":{\"length\":65536},\"hash_tree\":{\"phtc_size\":16}}";
    check(cm_create_new(config, NULL, NULL, &m), "cm_create_new");
    check(cm_write_memory(m, RAM_START, (const uint8_t *) program, sizeof program), "cm_write_memory");
    const uint64_t marker = MARKER_INITIAL;
    check(cm_write_memory(m, MARKER_ADDR, (const uint8_t *) &marker, sizeof marker), "cm_write_memory");
    cm_hash root0;
    check(cm_get_root_hash(m, &root0), "cm_get_root_hash");
    check(cm_store(m, src, CM_SHARING_ALL), "cm_store");
    cm_delete(m);
    m = NULL;

    // 2. Protect the stored machine
    static file_info files[MAX_FILES];
    const int nfiles = list_files(src, files);
    for (int i = 0; i < nfiles; i++) {
        if (strcmp(label, "all") == 0 || strcmp(files[i].name, ram_name) == 0) {
            char p[4096];
            path_of(p, sizeof p, src, files[i].name);
            make_read_only(p);
        }
    }
    hash_hex(&root0, hx);
    printf("source stored with root %s..., marker 0x%016" PRIx64 "\n", hx, marker);

    // Can this process open read-only files for writing (root / CAP_DAC_OVERRIDE)?
    int privileged = 0;
    int fd = open(src_ram, O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        privileged = 1;
        close(fd);
    } else if (errno != EACCES && errno != EPERM) {
        perror(src_ram);
        exit(2);
    }

    // 3. Clone it
    check(cm_clone_stored(NULL, src, dst), "cm_clone_stored");

    // Which clone files that a SHARING_ALL load maps writable share their inode with the source?
    int shared = 0, ram_shared = 0;
    for (int i = 0; i < nfiles; i++) {
        if (!files[i].writable_at_store || strcmp(files[i].name, "config.json") == 0) {
            continue; // stored read-only by the emulator itself (read-only range), or never written by a load
        }
        char ps[4096], pd[4096];
        struct stat ss, sd;
        path_of(ps, sizeof ps, src, files[i].name);
        path_of(pd, sizeof pd, dst, files[i].name);
        if (stat(ps, &ss) != 0 || stat(pd, &sd) != 0) {
            perror(pd);
            exit(2);
        }
        if (ss.st_dev == sd.st_dev && ss.st_ino == sd.st_ino) {
            shared++;
            ram_shared |= strcmp(files[i].name, ram_name) == 0;
        }
    }
    printf("clone: %d writable-range/hash-tree file(s) are hard links to the source%s\n", shared,
        ram_shared ? " (including the RAM data file)" : "");

    if (!privileged) {
        printf("this process cannot open read-only files for writing (no CAP_DAC_OVERRIDE): a SHARING_ALL load of "
               "a hard-linked clone fails before it can write through, so the hard links decide\n");
        cm_error e = cm_load_new(dst, NULL, CM_SHARING_ALL, &m);
        if (e != CM_ERROR_OK) {
            printf("SHARING_ALL load of the clone fails: %s\n", cm_get_last_error_message());
        }
        if (shared > 0) {
            cm_delete(m); // not run: nothing is written
            printf("BUG REPRODUCED: scenario '%s': cm_clone_stored hard-linked %d file(s) of writable ranges/hash "
                   "tree of a read-only stored machine; a SHARING_ALL load of the clone maps them shared-writable\n",
                label, shared);
            return 1;
        }
        if (e != CM_ERROR_OK) {
            printf("SKIP: scenario '%s': the clone is independent, but this process cannot load it with "
                   "SHARING_ALL, so the write-through check cannot run\n",
                label);
            return 77;
        }
    } else {
        // 4. Run the clone on disk
        check(cm_load_new(dst, NULL, CM_SHARING_ALL, &m), "cm_load_new(clone, CM_SHARING_ALL)");
    }
    cm_break_reason br;
    check(cm_run(m, 1000, &br), "cm_run");
    if (br != CM_BREAK_REASON_HALTED) {
        fprintf(stderr, "ERROR: the guest did not halt (break reason %d)\n", (int) br);
        exit(2);
    }
    cm_hash clone_root;
    check(cm_get_root_hash(m, &clone_root), "cm_get_root_hash");
    cm_delete(m);
    m = NULL;
    hash_hex(&clone_root, hx);
    printf("ran the clone (SHARING_ALL) to halt: clone root %s...\n", hx);

    // 5. The source must be untouched
    int changed = 0;
    for (int i = 0; i < nfiles; i++) {
        char p[4096];
        path_of(p, sizeof p, src, files[i].name);
        if (file_digest(p) != files[i].digest) {
            changed++;
        }
    }
    check(cm_load_new(src, NULL, CM_SHARING_NONE, &m), "cm_load_new(source, CM_SHARING_NONE)");
    cm_hash root1;
    uint64_t marker1 = 0;
    bool consistent = false;
    check(cm_get_root_hash(m, &root1), "cm_get_root_hash");
    check(cm_read_memory(m, MARKER_ADDR, (uint8_t *) &marker1, sizeof marker1), "cm_read_memory");
    check(cm_verify_hash_tree(m, &consistent), "cm_verify_hash_tree");
    cm_delete(m);
    const int root_same = memcmp(root0, root1, sizeof root0) == 0;
    hash_hex(&root1, hx);
    printf("source after running the clone: %d file(s) changed, marker 0x%016" PRIx64
           ", loads with root %s... (%s), stored hash tree %s its data\n",
        changed, marker1, hx,
        root_same ? "original" : (memcmp(root1, clone_root, sizeof root1) == 0 ? "the clone's post-run root" : "other"),
        consistent ? "matches" : "does NOT match");
    if (changed > 0 || marker1 != MARKER_INITIAL || !root_same || !consistent) {
        printf("BUG REPRODUCED: scenario '%s': running a clone made by cm_clone_stored modified its read-only source "
               "stored machine%s\n",
            label, root_same && !consistent ? " while the source still reports its original root hash" : "");
        return 1;
    }
    printf("OK: scenario '%s': the source stored machine is unchanged\n", label);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    const int a = scenario(argv[1], "all");
    const int b = scenario(argv[1], "ram");
    if (a == 1 || b == 1) {
        return 1;
    }
    if (a == 77 || b == 77) {
        return 77;
    }
    printf("OK: cm_clone_stored clones of a read-only stored machine are independent of their source\n");
    return 0;
}
