// cm_log_step(N)/cm_verify_step(N) stop at the first automatic yield inside the step.
//
// Usage: autoyield <prog.bin> <work-dir>
//
// cm_log_step, cm_verify_step (and the risc0 replay) call interpret() once. interpret() returns as soon as the guest
// performs an HTIF automatic yield, so the log header still claims N mcycles while the logged/verified transition ends
// at the yield (mcycle start+k, k < N). Every other path treats the automatic yield as a non-fixed point and continues:
// cm_run resumed after the yield, the uarch (one mcycle per big step), cm_collect_mcycle_*.
//
// Property checked (what a fix restores): for a guest that performs an automatic yield strictly inside an N-mcycle
// window, ONE cm_log_step(N) leaves the machine in the same state as cm_run resumed to start+N (and as N uarch big
// steps), and cm_verify_step(N) on that log returns that same root hash.
// Control: the same comparison on the same guest without the yield must agree on any build.
//
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure / control failed / reference paths disagree.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <cm.h>

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            fprintf(stderr, "setup failed: %s: %s\n", #x, cm_get_last_error_message());                                \
            exit(2);                                                                                                   \
        }                                                                                                              \
    } while (0)

static const uint64_t N = 64; // step size in mcycles; the yield happens at mcycle 37
static const char *prog_bin, *work_dir;

static const char *break_reason_name(cm_break_reason br) {
    switch (br) {
        case CM_BREAK_REASON_FAILED: return "FAILED";
        case CM_BREAK_REASON_HALTED: return "HALTED";
        case CM_BREAK_REASON_YIELDED_MANUALLY: return "YIELDED_MANUALLY";
        case CM_BREAK_REASON_YIELDED_AUTOMATICALLY: return "YIELDED_AUTOMATICALLY";
        case CM_BREAK_REASON_YIELDED_SOFTLY: return "YIELDED_SOFTLY";
        case CM_BREAK_REASON_REACHED_TARGET_MCYCLE: return "REACHED_TARGET_MCYCLE";
        default: return "other";
    }
}

static cm_machine *make(uint64_t mode) {
    char cfg[4096];
    snprintf(cfg, sizeof(cfg), "{\"ram\":{\"length\":65536,\"backing_store\":{\"data_filename\":\"%s\"}}}", prog_bin);
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, "{\"console\":{\"output_destination\":\"to_null\"}}", NULL, &m));
    CHK(cm_write_memory(m, 0x80001000, (const uint8_t *) &mode, sizeof(mode)));
    return m;
}

static uint64_t mcycle(cm_machine *m) {
    uint64_t v = 0;
    CHK(cm_read_reg(m, CM_REG_MCYCLE, &v));
    return v;
}

static void print_hash(const char *tag, const cm_hash *h, const char *extra) {
    printf("    %-38s ", tag);
    for (int i = 0; i < 8; i++) {
        printf("%02x", (*h)[i]);
    }
    printf("...%s\n", extra ? extra : "");
}

// Returns 1 when the single N-mcycle step log agrees with cm_run and the uarch, 0 otherwise
static int compare(uint64_t mode) {
    printf("guest %s\n", mode ? "WITH an automatic yield inside the step" : "without yields (control)");
    char extra[256];

    // Reference 1: cm_run to mcycle N, resuming after automatic yields (non-fixed points)
    cm_machine *m = make(mode);
    cm_break_reason br = CM_BREAK_REASON_FAILED, first = CM_BREAK_REASON_FAILED;
    uint64_t first_at = 0;
    do {
        CHK(cm_run(m, N, &br));
        if (first == CM_BREAK_REASON_FAILED) {
            first = br;
            first_at = mcycle(m);
        }
    } while (br == CM_BREAK_REASON_YIELDED_AUTOMATICALLY);
    cm_hash h_run;
    CHK(cm_get_root_hash(m, &h_run));
    snprintf(extra, sizeof(extra), "  (first break: %s at mcycle %" PRIu64 ")", break_reason_name(first), first_at);
    print_hash("cm_run resumed to mcycle 64", &h_run, extra);
    cm_delete(m);

    // Reference 2: N uarch big steps (what the on-chain step verifier executes, one mcycle each)
    m = make(mode);
    for (uint64_t i = 0; i < N; ++i) {
        CHK(cm_run_uarch(m, CM_UARCH_CYCLE_MAX, NULL));
        CHK(cm_reset_uarch(m));
    }
    cm_hash h_uarch;
    CHK(cm_get_root_hash(m, &h_uarch));
    print_hash("64 uarch big steps", &h_uarch, NULL);
    cm_delete(m);
    if (memcmp(h_run, h_uarch, sizeof(cm_hash)) != 0) {
        printf("ERROR: reference paths (cm_run, uarch) disagree\n");
        exit(2);
    }

    // Under test: ONE cm_log_step(N) + cm_verify_step(N)
    char log_filename[4096];
    snprintf(log_filename, sizeof(log_filename), "%s/step-%" PRIu64 ".log", work_dir, mode);
    unlink(log_filename);
    m = make(mode);
    cm_hash before, after, verified;
    CHK(cm_get_root_hash(m, &before));
    CHK(cm_log_step(m, N, log_filename, &br));
    CHK(cm_get_root_hash(m, &after));
    const uint64_t stopped = mcycle(m);
    CHK(cm_verify_step(&before, log_filename, N, &verified));
    unlink(log_filename);
    cm_delete(m);
    snprintf(extra, sizeof(extra), "  (break: %s, machine at mcycle %" PRIu64 ")", break_reason_name(br), stopped);
    print_hash("machine after cm_log_step(64)", &after, extra);
    print_hash("cm_verify_step(64)", &verified, NULL);
    const int ok = memcmp(after, h_run, sizeof(cm_hash)) == 0 && memcmp(verified, h_run, sizeof(cm_hash)) == 0;
    printf("    => the 64-mcycle step log %s cm_run/uarch\n", ok ? "AGREES with" : "DIVERGES from");
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <prog.bin> <work-dir>\n", argv[0]);
        return 2;
    }
    prog_bin = argv[1];
    work_dir = argv[2];
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!compare(0)) {
        printf("ERROR: control (no yield) disagrees\n");
        return 2;
    }
    return compare(1) ? 0 : 1;
}
