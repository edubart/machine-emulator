// interp-priv-1: the state root hash at a given mcycle must not depend on how execution is split.
// Runs the same bare-metal image (prog.S) to the same target mcycle N through several execution paths and
// compares the resulting root hashes:
//   A  one cm_run(N)                                  (fast interpreter, what nodes use)
//   B  N x cm_run(mcycle + 1)                          (per-cycle fast interpreter)
//   C  N x (cm_run_uarch + cm_reset_uarch)             (uarch big-steps, what the on-chain step proves)
//   D  cm_run in chunks of 7 cycles
// Usage: repro prog.bin N
// Exit 1 + "BUG REPRODUCED" if any two paths disagree, 0 + "OK" if all agree, 2 on harness errors.
#include <cm.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        cm_error e_ = (x);                                                                                             \
        if (e_ != CM_ERROR_OK) {                                                                                       \
            fprintf(stderr, "%s:%d %s -> %d: %s\n", __FILE__, __LINE__, #x, e_, cm_get_last_error_message());          \
            exit(2);                                                                                                   \
        }                                                                                                              \
    } while (0)

static const char *g_bin;

static cm_machine *make_machine(void) {
    char cfg[1024];
    snprintf(cfg, sizeof cfg, "{\"ram\":{\"length\":1048576,\"backing_store\":{\"data_filename\":\"%s\"}}}", g_bin);
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    return m;
}

#define NPATHS 4
static cm_hash g_hash[NPATHS];

// Records the root hash of a path and prints when the M-destined STI was taken (s4) and how many
// S-handler loop iterations ran before it (s8).
static void record(int i, const char *name, cm_machine *m) {
    uint64_t mcycle = 0, s4 = 0, s8 = 0;
    CHK(cm_read_reg(m, CM_REG_MCYCLE, &mcycle));
    CHK(cm_read_reg(m, CM_REG_X20, &s4));
    CHK(cm_read_reg(m, CM_REG_X24, &s8));
    CHK(cm_get_root_hash(m, &g_hash[i]));
    printf("%-36s mcycle=%-6" PRIu64 " root=", name, mcycle);
    for (int k = 0; k < 8; k++) {
        printf("%02x", g_hash[i][k]);
    }
    printf("...  [STI taken at mcycle %" PRIu64 ", after %" PRIu64 " S-handler iterations]\n", s4, s8);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s prog.bin N\n", argv[0]);
        return 2;
    }
    g_bin = argv[1];
    const uint64_t n = strtoull(argv[2], NULL, 0);
    cm_break_reason br;

    // A: single run
    cm_machine *m = make_machine();
    CHK(cm_run(m, n, &br));
    record(0, "A  cm_run(N) once", m);
    cm_delete(m);

    // B: one cm_run per mcycle
    m = make_machine();
    for (uint64_t c = 0; c < n; c++) {
        CHK(cm_run(m, c + 1, &br));
    }
    record(1, "B  cm_run(mcycle+1) x N", m);
    cm_delete(m);

    // C: uarch big-steps (one uarch run + reset per mcycle)
    m = make_machine();
    for (uint64_t c = 0; c < n; c++) {
        cm_uarch_break_reason ubr;
        CHK(cm_run_uarch(m, UINT64_MAX, &ubr));
        if (ubr != CM_UARCH_BREAK_REASON_UARCH_HALTED) {
            fprintf(stderr, "uarch did not halt at mcycle step %" PRIu64 "\n", c);
            return 2;
        }
        CHK(cm_reset_uarch(m));
    }
    record(2, "C  uarch big-steps x N", m);
    cm_delete(m);

    // D: chunks of 7 cycles
    m = make_machine();
    for (uint64_t c = 0; c < n; c += 7) {
        CHK(cm_run(m, c + 7 < n ? c + 7 : n, &br));
    }
    record(3, "D  cm_run in chunks of 7 cycles", m);
    cm_delete(m);

    int differ = 0;
    for (int i = 1; i < NPATHS; i++) {
        if (memcmp(g_hash[0], g_hash[i], sizeof(cm_hash)) != 0) {
            differ = 1;
        }
    }
    if (differ) {
        printf("BUG REPRODUCED: root hash at mcycle %" PRIu64
               " depends on the execution path (single cm_run vs per-cycle cm_run vs uarch vs chunked)\n",
            n);
        return 1;
    }
    printf("OK: all execution paths agree at mcycle %" PRIu64 "\n", n);
    return 0;
}
