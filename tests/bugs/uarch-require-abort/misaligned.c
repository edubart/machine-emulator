// A misaligned uarch instruction fetch aborts the process: the uarch require() is an assert().
//
// Usage: misaligned <work-dir>
//
// uarch-solidity-compat.hpp implements require(cond, msg) as assert(cond && msg). It guards the alignment checks of
// readUint64/32/16, writeUint64/32/16 and copyBits in uarch-step.cpp. Every other uarch failure throws (and maps to
// a C API error), and Solidity's require() reverts; in assert-enabled builds (the default relwithdebinfo build,
// packaging) the host process aborts instead.
//
// The misaligned uarch pc is reached by *executing* a custom uarch RAM image (config
// uarch.ram.backing_store.data_filename), with no register poking:
//   0x600000: lui  t0, 0x600          ; t0 = 0x600000
//   0x600004: jalr x0, 10(t0)         ; JALR clears only bit 0 -> uarch pc = 0x60000a
//   0x600008: (padding so that 0x60000a holds the bytes of "addi x1, x0, 42", straddling two 32-bit slots)
// The third uarch step then fetches readUint32(0x60000a) and hits require((paddr & 3) == 0, ...).
//
// Cases, each in a child process (an abort is observed instead of killing the test):
//   run:    cm_run_uarch on that machine, up to uarch cycle 3;
//   log:    cm_log_step_uarch, three times (the first two are aligned and must succeed);
//   verify: static cm_verify_step_uarch(NULL, root_before, log) for the third step. The log is built here from
//           cm_get_proof: the step reads uarch_cycle, uarch_halt_flag and uarch_pc (all in the 32-byte leaf at
//           0x400000), then fetches the instruction, so a log with those three reads reaches the fetch. This is the
//           path where both the pre-state hash and the log can come from an untrusted party.
//   control: the same log construction, for the same state but with uarch_halt_flag = 1 (the step then reads only
//           uarch_cycle and uarch_halt_flag), must be accepted with root_after == root_before. This checks that the
//           constructed logs are well formed.
// Property checked (what a fix restores): each case returns a C API error (no abort, and the misaligned fetch is not
// executed or accepted).
//
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure / control failed.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

// Child exit codes
enum { CHILD_ERROR_RETURNED = 0, CHILD_ACCEPTED = 1, CHILD_SETUP = 2 };

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            fprintf(stderr, "    setup failed: %s: %s\n", #x, cm_get_last_error_message());                            \
            _exit(CHILD_SETUP);                                                                                        \
        }                                                                                                              \
    } while (0)

#define UARCH_STATE_LEAF UINT64_C(0x400000) // uarch_halt_flag (+0), uarch_cycle (+8), uarch_pc (+16)

static char image_path[4096];

static cm_machine *make_machine(void) {
    char cfg[8192];
    snprintf(cfg, sizeof(cfg),
        "{\"ram\":{\"length\":65536},\"uarch\":{\"ram\":{\"backing_store\":{\"data_filename\":\"%s\"}}}}", image_path);
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    return m;
}

static void base64(const uint8_t *p, int n, char *out) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int o = 0;
    for (int i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t) p[i] << 16;
        if (i + 1 < n) v |= (uint32_t) p[i + 1] << 8;
        if (i + 2 < n) v |= p[i + 2];
        out[o++] = tbl[(v >> 18) & 63];
        out[o++] = tbl[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? tbl[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < n) ? tbl[v & 63] : '=';
    }
    out[o] = 0;
}

// Copies the JSON value that follows "key": in json (a string or an array without nested brackets)
static void json_value(const char *json, const char *key, char *out, size_t out_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *s = strstr(json, pattern);
    if (s == NULL) {
        fprintf(stderr, "    setup failed: no %s in proof\n", key);
        _exit(CHILD_SETUP);
    }
    s += strlen(pattern);
    const char *e = strchr(s + 1, *s == '[' ? ']' : '"');
    if (e == NULL || (size_t) (e + 1 - s) >= out_size) {
        fprintf(stderr, "    setup failed: bad %s in proof\n", key);
        _exit(CHILD_SETUP);
    }
    memcpy(out, s, e + 1 - s);
    out[e + 1 - s] = 0;
}

// Builds a uarch step log with `count` word reads of the uarch state leaf: uarch_cycle, uarch_halt_flag, uarch_pc
static char *build_log(cm_machine *m, int count) {
    uint8_t leaf[32];
    for (int i = 0; i < 4; ++i) {
        uint64_t w = 0;
        CHK(cm_read_word(m, UARCH_STATE_LEAF + 8 * i, &w));
        memcpy(leaf + 8 * i, &w, 8); // little-endian host
    }
    char leaf_b64[64];
    base64(leaf, 32, leaf_b64);
    const char *proof = NULL;
    CHK(cm_get_proof(m, UARCH_STATE_LEAF, 5, 64, &proof));
    static char siblings[8192], target_hash[128];
    json_value(proof, "sibling_hashes", siblings, sizeof(siblings));
    json_value(proof, "target_hash", target_hash, sizeof(target_hash));
    static const uint64_t offsets[3] = {8, 0, 16}; // uarch_cycle, uarch_halt_flag, uarch_pc (order of uarch_step)
    const size_t size = 32768;
    char *log = malloc(size);
    int n = snprintf(log, size, "{\"accesses\":[");
    for (int i = 0; i < count; ++i) {
        n += snprintf(log + n, size - n,
            "%s{\"address\":%" PRIu64 ",\"log2_size\":3,\"read\":\"%s\",\"read_hash\":%s,\"sibling_hashes\":%s,"
            "\"type\":\"read\"}",
            i ? "," : "", UARCH_STATE_LEAF + offsets[i], leaf_b64, target_hash, siblings);
    }
    snprintf(log + n, size - n, "],\"log_type\":{\"has_annotations\":false,\"has_large_data\":false}}");
    return log;
}

// Machine after the two aligned uarch steps: uarch pc == 0x60000a
static cm_machine *at_misaligned_pc(void) {
    cm_machine *m = make_machine();
    cm_uarch_break_reason br;
    CHK(cm_run_uarch(m, 2, &br));
    uint64_t pc = 0;
    CHK(cm_read_reg(m, CM_REG_UARCH_PC, &pc));
    if (pc != 0x60000a) {
        fprintf(stderr, "    setup failed: uarch pc is 0x%" PRIx64 ", expected 0x60000a\n", pc);
        _exit(CHILD_SETUP);
    }
    return m;
}

static int report(cm_error e) {
    if (e == CM_ERROR_OK) {
        printf("    returned OK: the misaligned fetch was executed/accepted\n");
        return CHILD_ACCEPTED;
    }
    printf("    returned error %d: %s\n", e, cm_get_last_error_message());
    return CHILD_ERROR_RETURNED;
}

static int case_run(void) {
    cm_machine *m = make_machine();
    cm_uarch_break_reason br;
    // Stop right after the 3rd uarch cycle (the misaligned fetch), so that a build that executes it is not confused
    // with one that rejects it by a later, unrelated error.
    return report(cm_run_uarch(m, 3, &br));
}

static int case_log(void) {
    cm_machine *m = make_machine();
    const char *log = NULL;
    CHK(cm_log_step_uarch(m, 0, &log)); // lui (aligned)
    CHK(cm_log_step_uarch(m, 0, &log)); // jalr (aligned)
    return report(cm_log_step_uarch(m, 0, &log));
}

static int case_verify(void) {
    cm_machine *m = at_misaligned_pc();
    cm_hash before, after;
    CHK(cm_get_root_hash(m, &before));
    char *log = build_log(m, 3);
    cm_delete(m);
    return report(cm_verify_step_uarch(NULL, &before, log, &after));
}

static int case_control(void) {
    cm_machine *m = at_misaligned_pc();
    CHK(cm_write_reg(m, CM_REG_UARCH_HALT, 1));
    cm_hash before, after;
    CHK(cm_get_root_hash(m, &before));
    char *log = build_log(m, 2);
    cm_delete(m);
    if (cm_verify_step_uarch(NULL, &before, log, &after) != CM_ERROR_OK) {
        fprintf(stderr, "    constructed log rejected: %s\n", cm_get_last_error_message());
        return CHILD_SETUP;
    }
    if (memcmp(before, after, sizeof(cm_hash)) != 0) {
        fprintf(stderr, "    constructed log verified to an unexpected root hash\n");
        return CHILD_SETUP;
    }
    printf("    constructed log accepted, root hash unchanged\n");
    return CHILD_ERROR_RETURNED;
}

// Runs one case in a child process; returns its exit code, or 128+signal when it died
static int in_child(const char *title, int (*fn)(void)) {
    printf("%s\n", title);
    const pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        exit(2);
    }
    if (pid == 0) {
        const int rc = fn();
        fflush(stdout);
        _exit(rc);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        perror("waitpid");
        exit(2);
    }
    if (WIFSIGNALED(status)) {
        printf("    -> process killed by signal %d\n", WTERMSIG(status));
        return 128 + WTERMSIG(status);
    }
    return WEXITSTATUS(status);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    snprintf(image_path, sizeof(image_path), "%s/uarch-ram.bin", argc > 1 ? argv[1] : ".");
    const uint32_t image[4] = {
        0x006002b7u, // 0x600000: lui  t0, 0x600
        0x00a28067u, // 0x600004: jalr x0, 10(t0)
        0x00930000u, // 0x600008: halfword at 0x60000a = 0x0093 (low half of addi x1, x0, 42)
        0x000002a0u, // 0x60000c: halfword at 0x60000c = 0x02a0 (high half of addi x1, x0, 42)
    };
    FILE *f = fopen(image_path, "wb");
    if (f == NULL || fwrite(image, sizeof(image), 1, f) != 1 || fclose(f) != 0) {
        perror(image_path);
        return 2;
    }
    if (in_child("control: constructed uarch step log for a halted uarch (static cm_verify_step_uarch)",
            case_control) != CHILD_ERROR_RETURNED) {
        printf("ERROR: control failed\n");
        return 2;
    }
    struct {
        const char *title;
        int (*fn)(void);
    } cases[] = {
        {"run: cm_run_uarch reaching uarch pc 0x60000a", case_run},
        {"log: cm_log_step_uarch of the step at uarch pc 0x60000a", case_log},
        {"verify: static cm_verify_step_uarch(NULL, root_before, log) of the step at uarch pc 0x60000a", case_verify},
    };
    int bug = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        const int rc = in_child(cases[i].title, cases[i].fn);
        if (rc == CHILD_SETUP) {
            printf("ERROR: setup failure\n");
            return 2;
        }
        if (rc != CHILD_ERROR_RETURNED) {
            bug = 1;
        }
    }
    return bug;
}
