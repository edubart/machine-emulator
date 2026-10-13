// cm_send_cmio_response / cm_log_send_cmio_response with data == NULL and length > 0 fail but leave the machine
// partially modified.
//
// Usage: null-data
//
// send_cmio_response() writes imcyclemax and the revert root hash before writeMemoryWithPadding(), which then throws
// on data == NULL. The C wrappers never validate the pointer, although cm.h promises that "validation errors leave the
// machine unchanged".
//
// The machine is put directly (via its config) at an rx-accepted manual yield: iflags.Y = 1 and
// htif.tohost = dev yield (2) << 56 | cmd manual (1) << 48 | reason rx-accepted (1) << 32 = 144396667347533824.
//
// Property checked (what a fix restores): if a call fails, the machine root hash is unchanged.
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cm.h>

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            fprintf(stderr, "setup failed: %s: %s\n", #x, cm_get_last_error_message());                                \
            exit(2);                                                                                                   \
        }                                                                                                              \
    } while (0)

static cm_machine *make(void) {
    const char *cfg = "{\"ram\":{\"length\":65536},\"processor\":{\"registers\":{\"iflags\":{\"Y\":1},"
                      "\"htif\":{\"tohost\":144396667347533824}}}}";
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    return m;
}

// Returns 1 when the call failed and left the machine modified
static int check(const char *what, int use_log) {
    cm_machine *m = make();
    cm_hash before, after;
    CHK(cm_get_root_hash(m, &before));
    const char *log = NULL;
    const cm_error e = use_log
        ? cm_log_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, NULL, 8, &before, 0, &log)
        : cm_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, NULL, 8, &before);
    printf("%s(data=NULL, length=8): %s%s\n", what, e == CM_ERROR_OK ? "succeeded" : "error: ",
        e == CM_ERROR_OK ? "" : cm_get_last_error_message());
    CHK(cm_get_root_hash(m, &after));
    uint64_t imcyclemax = 0;
    CHK(cm_read_reg(m, CM_REG_IMCYCLEMAX, &imcyclemax));
    const int changed = memcmp(before, after, sizeof(cm_hash)) != 0;
    printf("    root hash changed: %s (imcyclemax = 0x%" PRIx64 ")\n", changed ? "YES" : "no", imcyclemax);
    cm_delete(m);
    return e != CM_ERROR_OK && changed;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    // Control: the same machine accepts a valid response
    cm_machine *m = make();
    cm_hash h;
    CHK(cm_get_root_hash(m, &h));
    const uint8_t data[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    CHK(cm_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, data, sizeof(data), &h));
    cm_delete(m);

    const int a = check("cm_send_cmio_response", 0);
    const int b = check("cm_log_send_cmio_response", 1);
    return (a || b) ? 1 : 0;
}
