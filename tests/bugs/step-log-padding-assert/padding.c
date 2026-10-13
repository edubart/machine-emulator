// cm_log_step() and cm_get_node_hash() on hash-tree nodes in the power-of-two padding of a memory range.
//
// Usage: padding <work-dir>
//
// Each address range has a dense hash tree over bit_ceil(page_count) pages. For a range whose length is not a power
// of two, the tail of that tree is padding (pristine pages past the end of the range). When a step touches a page in
// the last, partially filled power-of-two block of the range, cm_log_step needs the hash of a sibling subtree that
// starts at or past the range end. hash_tree::get_dense_node_hash() asserts that the node lies inside the range,
// so in assert-enabled builds (the default relwithdebinfo build, packaging) the process aborts.
//
// Machine: 64 KiB RAM and a flash drive at 0x90000000. The guest computes the address of a flash page and the logged
// mcycle is a single "ld" from that page:
//   lui t0,0x48000 ; slli t0,t0,1 ; lui t1,<page> ; add t0,t0,t1 ; ld t1,0(t0) ; j .
//
// Every case runs in a child process, so an abort is observed instead of killing the test.
// Property checked (what a fix restores):
//   - cm_log_step(1) over the "ld" from the last page of a 3-page drive produces a log, the machine ends in the same
//     state as cm_run, and cm_verify_step on that log returns the same root hash;
//   - cm_get_node_hash() on a padding page returns the pristine page hash (equal to an untouched page of the drive).
// Controls (must pass on any build): the same step on a 4-page drive, and a load from page 0 of the 3-page drive.
//
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure / control failed.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

#define FLASH_START UINT64_C(0x90000000)
#define PAGE_SIZE UINT64_C(4096)

// Child exit codes
enum { CHILD_OK = 0, CHILD_WRONG = 1, CHILD_SETUP = 2 };

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            fprintf(stderr, "    setup failed: %s: %s\n", #x, cm_get_last_error_message());                            \
            _exit(CHILD_SETUP);                                                                                        \
        }                                                                                                              \
    } while (0)

static const char *work_dir;

static void print_hash(const char *tag, const cm_hash *h) {
    printf("    %-26s ", tag);
    for (int i = 0; i < 8; i++) {
        printf("%02x", (*h)[i]);
    }
    printf("...\n");
}

// Creates the machine and runs it up to the "ld" (mcycle 4)
static cm_machine *new_machine(uint64_t flash_length, uint32_t page) {
    char cfg[256];
    snprintf(cfg, sizeof(cfg),
        "{\"ram\":{\"length\":65536},\"flash_drive\":[{\"start\":%" PRIu64 ",\"length\":%" PRIu64 "}]}", FLASH_START,
        flash_length);
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    const uint32_t prog[] = {
        0x480002b7u,                  // lui  t0, 0x48000
        0x00129293u,                  // slli t0, t0, 1      -> t0 = 0x90000000
        (page << 12) | 0x337u,        // lui  t1, page       -> t1 = page * 4096
        0x006282b3u,                  // add  t0, t0, t1
        0x0002b303u,                  // ld   t1, 0(t0)      <- the logged mcycle
        0x0000006fu,                  // j    .
    };
    CHK(cm_write_memory(m, 0x80000000, (const uint8_t *) prog, sizeof(prog)));
    cm_break_reason br;
    CHK(cm_run(m, 4, &br));
    return m;
}

// cm_log_step(1) over the "ld", verified, compared with cm_run on a twin machine
static int case_log_step(uint64_t flash_length, uint32_t page) {
    cm_machine *twin = new_machine(flash_length, page);
    cm_break_reason br;
    CHK(cm_run(twin, 5, &br));
    cm_hash expected;
    CHK(cm_get_root_hash(twin, &expected));
    cm_delete(twin);

    cm_machine *m = new_machine(flash_length, page);
    cm_hash before, after, verified;
    CHK(cm_get_root_hash(m, &before));
    char log_filename[4096];
    snprintf(log_filename, sizeof(log_filename), "%s/step-%" PRIu64 "-%u.log", work_dir, flash_length, page);
    unlink(log_filename);
    if (cm_log_step(m, 1, log_filename, &br) != CM_ERROR_OK) {
        printf("    cm_log_step failed: %s\n", cm_get_last_error_message());
        return CHILD_WRONG;
    }
    CHK(cm_get_root_hash(m, &after));
    if (cm_verify_step(&before, log_filename, 1, &verified) != CM_ERROR_OK) {
        printf("    cm_verify_step failed: %s\n", cm_get_last_error_message());
        return CHILD_WRONG;
    }
    unlink(log_filename);
    cm_delete(m);
    print_hash("cm_run (twin)", &expected);
    print_hash("after cm_log_step", &after);
    print_hash("cm_verify_step", &verified);
    const int ok = memcmp(after, expected, sizeof(cm_hash)) == 0 && memcmp(verified, expected, sizeof(cm_hash)) == 0;
    return ok ? CHILD_OK : CHILD_WRONG;
}

// cm_get_node_hash on a padding page must be the pristine page hash (same as untouched page 0 of the drive)
static int case_node_hash(uint64_t flash_length, uint32_t padding_page) {
    cm_machine *m = new_machine(flash_length, 0);
    cm_hash zero_page, padding;
    CHK(cm_get_node_hash(m, FLASH_START, 12, &zero_page));
    if (cm_get_node_hash(m, FLASH_START + padding_page * PAGE_SIZE, 12, &padding) != CM_ERROR_OK) {
        printf("    cm_get_node_hash failed: %s\n", cm_get_last_error_message());
        return CHILD_WRONG;
    }
    cm_delete(m);
    print_hash("untouched page 0", &zero_page);
    print_hash("padding page", &padding);
    return memcmp(zero_page, padding, sizeof(cm_hash)) == 0 ? CHILD_OK : CHILD_WRONG;
}

// Runs one case in a child process. Returns CHILD_OK / CHILD_WRONG / CHILD_SETUP, or 128+signal when it died.
static int in_child(const char *title, int is_node_hash, uint64_t flash_length, uint32_t page) {
    printf("%s\n", title);
    fflush(stdout);
    const pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        exit(2);
    }
    if (pid == 0) {
        const int rc = is_node_hash ? case_node_hash(flash_length, page) : case_log_step(flash_length, page);
        fflush(stdout);
        _exit(rc);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        perror("waitpid");
        exit(2);
    }
    if (WIFSIGNALED(status)) {
        printf("    -> child killed by signal %d\n", WTERMSIG(status));
        return 128 + WTERMSIG(status);
    }
    const int rc = WEXITSTATUS(status);
    printf("    -> %s\n", rc == CHILD_OK ? "ok" : (rc == CHILD_WRONG ? "WRONG" : "setup failure"));
    return rc;
}

int main(int argc, char **argv) {
    work_dir = argc > 1 ? argv[1] : ".";
    setvbuf(stdout, NULL, _IONBF, 0);
    // Controls: nothing past the end of the range is needed
    if (in_child("control: 4-page drive (power of two), ld from page 2, cm_log_step(1)", 0, 4 * PAGE_SIZE, 2) !=
            CHILD_OK ||
        in_child("control: 3-page drive, ld from page 0, cm_log_step(1)", 0, 3 * PAGE_SIZE, 0) != CHILD_OK) {
        printf("ERROR: control failed\n");
        return 2;
    }
    const int log_rc = in_child("test: 3-page drive, ld from page 2 (last page), cm_log_step(1)", 0, 3 * PAGE_SIZE, 2);
    const int node_rc = in_child("test: 3-page drive, cm_get_node_hash(padding page 3, 12)", 1, 3 * PAGE_SIZE, 3);
    if (log_rc == CHILD_SETUP || node_rc == CHILD_SETUP) {
        printf("ERROR: setup failure\n");
        return 2;
    }
    int bug = 0;
    if (log_rc != CHILD_OK) {
        printf("cm_log_step over the last page of a non-power-of-two range %s\n",
            log_rc > 128 ? "aborted the process" : "failed or disagreed with cm_run");
        bug = 1;
    }
    if (node_rc != CHILD_OK) {
        printf("cm_get_node_hash on a padding page %s\n",
            node_rc > 128 ? "aborted the process" : "failed or returned a non-pristine hash");
        bug = 1;
    }
    return bug;
}
