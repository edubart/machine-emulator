// cm_replace_memory_range() on a machine that has already run leaves stale host pointers in the hot TLB.
// machine::replace_memory_range() swaps the address range (unmapping the old host memory) but never calls
// init_hot_tlb_contents(), unlike the constructor and the other paths that swap host memory. The next
// cm_run() keeps translating guest accesses through the cached host pointer of the old (unmapped) range:
//   - "crash" mode: replace flash0 only -> the guest's stores to flash0 hit unmapped memory (SIGSEGV);
//   - "divergence" mode: replace flash0, then flash1 (same size) -> the new flash1 mapping typically reuses
//     the freed address range, so the guest's stores to flash0 silently land in flash1 and cm_run() ends with
//     wrong memory contents and a wrong root hash, while cm_log_step() (which re-initializes the hot TLB)
//     computes the correct state. A node would then commit to hashes its own step proofs disagree with.
// Each execution path runs in a forked child; results come back through a pipe.
// Usage: repro <crash|divergence> <work-dir>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

#define RAM_START UINT64_C(0x80000000)
#define FLASH0 UINT64_C(0x80000000000000)
#define FLASH1 UINT64_C(0x80000060000000)
#define FLASH_LENGTH 0x10000
#define WARM_CYCLES 100 // enough to execute the first stores to flash0 (warms the write TLB slot)
#define MCYCLE_END (UINT64_C(1) << 20)

// Hand-encoded RV64 program (no cross toolchain needed):
static const uint32_t program[] = {
    0x00100293, //       addi t0, zero, 1
    0x03729293, //       slli t0, t0, 55        t0 = 0x80000000000000 (flash0)
    0x00000e13, //       addi t3, zero, 0
    0x3e800e93, //       addi t4, zero, 1000
    0x01c2b023, // loop: sd   t3, 0(t0)         store to flash0 through the write TLB
    0x001e0e13, //       addi t3, t3, 1
    0xffde4ce3, //       blt  t3, t4, loop
    0x40008337, //       lui  t1, 0x40008       HTIF tohost
    0x00100393, //       addi t2, zero, 1
    0x00733023, //       sd   t2, 0(t1)         halt with exit code 0
    0x0000006f, //       j    .
};

typedef struct {
    uint64_t halted, mcycle, flash0, flash1;
    cm_hash root;
} result_t;

static const char *mode = NULL;
static const char *work_dir = NULL;

static void check(cm_error e, const char *what) {
    if (e != CM_ERROR_OK) {
        fprintf(stderr, "%s failed: %s\n", what, cm_get_last_error_message());
        _exit(2);
    }
}

static void replace_flash(cm_machine *m, uint64_t start) {
    char cfg[256];
    snprintf(cfg, sizeof cfg, "{\"start\":%" PRIu64 ",\"length\":%d}", start, FLASH_LENGTH);
    check(cm_replace_memory_range(m, cfg), "cm_replace_memory_range");
}

// Path 0: cm_run in place. Path 1: same sequence, but the final run is done by cm_log_step (reference).
static void child(int path, int fd) {
    char cfg[512];
    snprintf(cfg, sizeof cfg,
        "{\"ram\":{\"length\":1048576},\"flash_drive\":[{\"start\":%" PRIu64 ",\"length\":%d},{\"start\":%" PRIu64
        ",\"length\":%d}]}",
        FLASH0, FLASH_LENGTH, FLASH1, FLASH_LENGTH);
    cm_machine *m = NULL;
    check(cm_create_new(cfg, NULL, NULL, &m), "cm_create_new");
    uint8_t code[sizeof program];
    for (size_t i = 0; i < sizeof program / sizeof program[0]; i++) {
        for (int b = 0; b < 4; b++) {
            code[4 * i + b] = (uint8_t) (program[i] >> (8 * b));
        }
    }
    check(cm_write_memory(m, RAM_START, code, sizeof code), "cm_write_memory");
    cm_break_reason br;
    check(cm_run(m, WARM_CYCLES, &br), "cm_run(warm-up)");
    replace_flash(m, FLASH0);
    if (strcmp(mode, "divergence") == 0) {
        replace_flash(m, FLASH1);
    }
    if (path == 0) {
        check(cm_run(m, MCYCLE_END, &br), "cm_run");
    } else {
        char log[512];
        snprintf(log, sizeof log, "%s/step-%s.log", work_dir, mode);
        unlink(log); // cm_log_step refuses to overwrite an existing log
        check(cm_log_step(m, MCYCLE_END - WARM_CYCLES, log, &br), "cm_log_step");
    }
    result_t r;
    memset(&r, 0, sizeof r);
    check(cm_read_reg(m, CM_REG_IFLAGS_H, &r.halted), "cm_read_reg");
    check(cm_read_reg(m, CM_REG_MCYCLE, &r.mcycle), "cm_read_reg");
    check(cm_read_word(m, FLASH0, &r.flash0), "cm_read_word");
    check(cm_read_word(m, FLASH1, &r.flash1), "cm_read_word");
    check(cm_get_root_hash(m, &r.root), "cm_get_root_hash");
    cm_delete(m);
    if (write(fd, &r, sizeof r) != (ssize_t) sizeof r) {
        _exit(2);
    }
    _exit(0);
}

// Returns 0 on success, 1 if the child was killed by a signal, 2 on harness error.
static int run_path(int path, result_t *r) {
    int fds[2];
    if (pipe(fds) != 0) {
        perror("pipe");
        return 2;
    }
    pid_t p = fork();
    if (p < 0) {
        perror("fork");
        return 2;
    }
    if (p == 0) {
        close(fds[0]);
        child(path, fds[1]);
    }
    close(fds[1]);
    ssize_t n = read(fds[0], r, sizeof *r);
    close(fds[0]);
    int st = 0;
    if (waitpid(p, &st, 0) != p) {
        perror("waitpid");
        return 2;
    }
    if (WIFSIGNALED(st)) {
        printf("%-10s killed by signal %d\n", path == 0 ? "cm_run" : "log_step", WTERMSIG(st));
        return 1;
    }
    if (WEXITSTATUS(st) != 0 || n != (ssize_t) sizeof *r) {
        return 2;
    }
    printf("%-10s halted=%" PRIu64 " mcycle=%" PRIu64 " flash0[0]=%" PRIu64 " flash1[0]=%" PRIu64 " root=",
        path == 0 ? "cm_run" : "log_step", r->halted, r->mcycle, r->flash0, r->flash1);
    for (int i = 0; i < 8; i++) {
        printf("%02x", r->root[i]);
    }
    printf("...\n");
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 3 || (strcmp(argv[1], "crash") != 0 && strcmp(argv[1], "divergence") != 0)) {
        fprintf(stderr, "usage: %s <crash|divergence> <work-dir>\n", argv[0]);
        return 2;
    }
    mode = argv[1];
    work_dir = argv[2];
    printf("mode %s: run %d cycles, replace flash0%s, run to halt\n", mode, WARM_CYCLES,
        strcmp(mode, "divergence") == 0 ? " and flash1" : "");
    // Reference: cm_log_step re-initializes the hot TLB before running
    result_t ref;
    if (run_path(1, &ref) != 0) {
        return 2;
    }
    // The guest stores 0..999 to flash0 and never touches flash1
    if (ref.halted != 1 || ref.flash0 != 999 || ref.flash1 != 0) {
        fprintf(stderr, "reference path does not match the program semantics\n");
        return 2;
    }
    result_t r;
    int st = run_path(0, &r);
    if (st == 2) {
        return 2;
    }
    if (st == 1) {
        printf("BUG REPRODUCED: cm_run after cm_replace_memory_range crashed (stale hot-TLB pointer into "
               "unmapped host memory)\n");
        return 1;
    }
    if (r.halted != ref.halted || r.mcycle != ref.mcycle || r.flash0 != ref.flash0 || r.flash1 != ref.flash1 ||
        memcmp(r.root, ref.root, sizeof r.root) != 0) {
        printf("BUG REPRODUCED: cm_run after cm_replace_memory_range diverges from cm_log_step (guest stores went "
               "through a stale hot-TLB pointer: wrong memory contents and root hash)\n");
        return 1;
    }
    printf("OK: cm_run after cm_replace_memory_range matches cm_log_step\n");
    return 0;
}
