// Drives the uarch WRITE_TLB ecall with a chosen TLB set index, using only the public C API.
//
// Usage: write-tlb <run|log> <set_index>
//   run: executes the ecall with cm_run_uarch
//   log: executes the ecall with cm_log_step_uarch (the path used to produce uarch step proofs)
//
// The uarch RAM is left untouched: we look for an existing `ecall` word in the pristine uarch image and point
// uarch_pc at it, as if the machine were in the middle of a big step (uarch_cycle != 0). The ecall arguments come from
// the uarch registers: a7 = function (WRITE_TLB), a0 = set_index, a1 = slot_index, a2..a4 = slot payload.
// Valid set indices are 0 (code), 1 (read) and 2 (write).
//
// Exit codes: 0 = the uarch step reported an error, 1 = the uarch step succeeded, 2 = setup failure.
// (The process may also die from a signal when the out-of-range index reaches host memory.)
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

#define ECALL 0x00000073u
#define UARCH_RAM_SCAN_LENGTH (1u << 20)

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "run") != 0 && strcmp(argv[1], "log") != 0)) {
        fprintf(stderr, "usage: %s <run|log> <set_index>\n", argv[0]);
        return 2;
    }
    const int use_log = strcmp(argv[1], "log") == 0;
    const uint64_t set_index = strtoull(argv[2], NULL, 0);

    cm_machine *m = NULL;
    CHK(cm_create_new("{\"ram\":{\"length\":4096}}", NULL, NULL, &m));

    // The initial uarch pc is the start of the uarch RAM; find the first ecall instruction in the uarch image.
    uint64_t uarch_ram_start = 0;
    CHK(cm_read_reg(m, CM_REG_UARCH_PC, &uarch_ram_start));
    uint32_t *image = malloc(UARCH_RAM_SCAN_LENGTH);
    if (!image) {
        return 2;
    }
    CHK(cm_read_memory(m, uarch_ram_start, (uint8_t *) image, UARCH_RAM_SCAN_LENGTH));
    uint64_t ecall_pc = 0;
    for (uint64_t i = 0; i < UARCH_RAM_SCAN_LENGTH / 4; i++) {
        if (image[i] == ECALL) {
            ecall_pc = uarch_ram_start + 4 * i;
            break;
        }
    }
    free(image);
    if (ecall_pc == 0) {
        fprintf(stderr, "setup failed: no ecall instruction found in the uarch image\n");
        return 2;
    }

    // Mid big-step uarch state about to execute WRITE_TLB(set_index, slot 0, invalid page)
    CHK(cm_write_reg(m, CM_REG_UARCH_CYCLE, 1));
    CHK(cm_write_reg(m, CM_REG_UARCH_PC, ecall_pc));
    CHK(cm_write_reg(m, CM_REG_UARCH_X17, 4));          // a7 = UARCH_ECALL_FN_WRITE_TLB
    CHK(cm_write_reg(m, CM_REG_UARCH_X10, set_index));  // a0 = set_index (0..2 are valid)
    CHK(cm_write_reg(m, CM_REG_UARCH_X11, 0));          // a1 = slot_index
    CHK(cm_write_reg(m, CM_REG_UARCH_X12, UINT64_MAX)); // a2 = vaddr_page (TLB_INVALID_PAGE)
    CHK(cm_write_reg(m, CM_REG_UARCH_X13, 0));          // a3 = vp_offset
    CHK(cm_write_reg(m, CM_REG_UARCH_X14, 0));          // a4 = pma_index

    printf("%s: WRITE_TLB ecall at uarch pc 0x%" PRIx64 " with set_index=%" PRIu64 "\n", argv[1], ecall_pc,
        set_index);
    fflush(stdout);

    cm_error err = CM_ERROR_OK;
    if (use_log) {
        const char *log = NULL;
        err = cm_log_step_uarch(m, 0, &log);
    } else {
        cm_uarch_break_reason br;
        err = cm_run_uarch(m, 2, &br);
    }
    if (err != CM_ERROR_OK) {
        printf("%s: uarch step reported an error: %s\n", argv[1], cm_get_last_error_message());
        cm_delete(m);
        return 0;
    }
    uint64_t pc = 0;
    CHK(cm_read_reg(m, CM_REG_UARCH_PC, &pc));
    printf("%s: uarch step succeeded (uarch pc advanced to 0x%" PRIx64 ")\n", argv[1], pc);
    fflush(stdout);
    cm_delete(m);
    return 1;
}
