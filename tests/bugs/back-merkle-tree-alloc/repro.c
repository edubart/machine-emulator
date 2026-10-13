// back_merkle_tree's constructor allocates and zero-fills (log2_max_leaves + 1) hashes *before* it checks that
// log2_max_leaves is in range (back-merkle-tree.hpp: m_context(std::max(1, log2_max_leaves + 1)) runs before the
// "log2_max_leaves is too large" check). A previous_partial_bundle passed to cm_collect_mcycle_root_hashes() (a JSON
// input, also accepted from JSON-RPC clients) is parsed into a back_merkle_tree, so its log2_max_leaves field controls
// the size of an allocation that happens before the input is rejected: 2^28 asks for 8 GiB, and INT_MAX overflows.
//
// The test uses a bounded value, log2_max_leaves = 2^21 (64 MiB worth of hashes), and measures the process peak RSS
// around the call. Fixed behavior: the bundle is rejected without allocating (peak RSS grows by much less than 32 MiB).
// Control: log2_max_leaves = 63 (in range but inconsistent with the call) is rejected with no measurable growth.
//
// Usage: repro      (exit 1 = bug present, 0 = fixed, 2 = test error)
#include <cm.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BIG_LOG2_MAX_LEAVES (1 << 21) // (2^21 + 1) * 32 bytes = 64 MiB, bounded on purpose
#define THRESHOLD_KIB (32 * 1024)

static long status_kib(const char *key) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) {
        return -1;
    }
    char line[256];
    long v = -1;
    const size_t n = strlen(key);
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, n) == 0 && line[n] == ':') {
            v = strtol(line + n + 1, NULL, 10);
            break;
        }
    }
    fclose(f);
    return v;
}

// Resets the peak RSS (VmHWM) of this process to its current RSS (Linux >= 4.0); harmless if unsupported
static void reset_peak_rss(void) {
    FILE *f = fopen("/proc/self/clear_refs", "w");
    if (f) {
        fputs("5", f);
        fclose(f);
    }
}

// Calls cm_collect_mcycle_root_hashes with a partial bundle claiming log2_max_leaves; returns the peak RSS growth
static long try_bundle(cm_machine *m, long log2_max_leaves, int *accepted, char *err, size_t errlen) {
    char bundle[256];
    snprintf(bundle, sizeof bundle,
        "{\"log2_max_leaves\":%ld,\"hash_function\":\"keccak256\",\"leaf_count\":0,\"context\":[]}", log2_max_leaves);
    reset_peak_rss();
    const long before = status_kib("VmHWM");
    const char *result = NULL;
    const cm_error e = cm_collect_mcycle_root_hashes(m, 10, 0, 0, 0, bundle, &result);
    const long after = status_kib("VmHWM");
    *accepted = e == CM_ERROR_OK;
    snprintf(err, errlen, "%s", e == CM_ERROR_OK ? "accepted" : cm_get_last_error_message());
    if (before < 0 || after < 0) {
        fprintf(stderr, "test error: cannot read VmHWM from /proc/self/status\n");
        exit(2);
    }
    return after - before;
}

int main(void) {
    cm_machine *m = NULL;
    if (cm_create_new("{\"ram\":{\"length\":1048576}}", NULL, NULL, &m) != CM_ERROR_OK) {
        fprintf(stderr, "test error: %s\n", cm_get_last_error_message());
        return 2;
    }
    int accepted = 0;
    char err[512];

    // Control: an in-range log2_max_leaves that does not match log2_bundle_mcycle_count (0) must be rejected cheaply
    long grow = try_bundle(m, 63, &accepted, err, sizeof err);
    printf("control: log2_max_leaves=63: %s; peak RSS grew by %ld KiB\n", err, grow);
    if (accepted || grow >= THRESHOLD_KIB) {
        printf("test error: control bundle was accepted or allocated a lot of memory\n");
        cm_delete(m);
        return 2;
    }

    grow = try_bundle(m, BIG_LOG2_MAX_LEAVES, &accepted, err, sizeof err);
    printf("log2_max_leaves=%d: %s; peak RSS grew by %ld KiB\n", BIG_LOG2_MAX_LEAVES, err, grow);
    cm_delete(m);
    if (accepted) {
        printf("BUG REPRODUCED: a partial bundle with log2_max_leaves=%d was accepted\n", BIG_LOG2_MAX_LEAVES);
        return 1;
    }
    if (grow >= THRESHOLD_KIB) {
        printf("BUG REPRODUCED: %ld MiB were allocated for log2_max_leaves=%d before the partial bundle was rejected "
               "(2^28 would allocate 8 GiB)\n",
            grow / 1024, BIG_LOG2_MAX_LEAVES);
        return 1;
    }
    printf("OK: the out-of-range partial bundle was rejected before allocating its context\n");
    return 0;
}
