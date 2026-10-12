// Regression test: cm_send_cmio_response must not silently truncate a 64-bit response length.
//
// The C API narrowed the length parameter of cm_send_cmio_response (and the log/verify variants)
// from uint64_t to uint32_t. A C or FFI caller holding a 64-bit length (size_t, uint64_t) compiles
// cleanly under -Wall -Wextra, and the length is reduced modulo 2^32. A response of 4 GiB + 16 bytes,
// which does not fit the 2 MiB rx buffer, is then delivered as a 16-byte response and reported as a
// success. v0.21.0 rejected it with "CMIO response data is too large".
//
// Run (from the repo root, after sourcing bugs/env/env.sh):
//   sh <this dir>/run.sh
// Prints "BUG REPRODUCED" and exits 1 on the buggy behaviour, "OK" and exits 0 when fixed.
#define _GNU_SOURCE
#include <cm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define CHECK(x)                                                                                                       \
    do {                                                                                                               \
        if ((x) != 0) {                                                                                                \
            fprintf(stderr, "%s failed: %s\n", #x, cm_get_last_error_message());                                       \
            return 2;                                                                                                  \
        }                                                                                                              \
    } while (0)

int main(void) {
    cm_machine *m = NULL;
    CHECK(cm_create_new("{\"ram\":{\"length\":1048576}}", NULL, NULL, &m));
    // Put the machine on an rx-accepted manual yield, waiting for a response
    const uint64_t tohost = ((uint64_t) CM_HTIF_DEV_YIELD << 56) | ((uint64_t) CM_HTIF_YIELD_CMD_MANUAL << 48) |
        ((uint64_t) CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED << 32);
    CHECK(cm_write_reg(m, CM_REG_HTIF_TOHOST, tohost));
    CHECK(cm_write_reg(m, CM_REG_IFLAGS_Y, 1));

    // A host buffer whose size is a 64-bit quantity, larger than 4 GiB (only the first page is touched)
    const uint64_t length = (UINT64_C(1) << 32) + 16;
    uint8_t *data = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        return 2;
    }
    memset(data, 'A', 16);

    cm_hash before;
    CHECK(cm_get_root_hash(m, &before));
    const cm_error err = cm_send_cmio_response(m, CM_HTIF_YIELD_REASON_INSPECT_STATE, data, length, NULL);
    cm_hash after;
    CHECK(cm_get_root_hash(m, &after));
    uint64_t fromhost = 0;
    CHECK(cm_read_reg(m, CM_REG_HTIF_FROMHOST, &fromhost));
    const int changed = memcmp(before, after, sizeof(before)) != 0;
    printf("cm_send_cmio_response(length=%llu) -> %s; state changed=%d; fromhost length=%llu\n",
        (unsigned long long) length, err ? cm_get_last_error_message() : "success", changed,
        (unsigned long long) (fromhost & 0xffffffffu));
    cm_delete(m);
    if (err == 0 && changed) {
        printf("BUG REPRODUCED: a %llu-byte response was delivered as a %llu-byte response\n",
            (unsigned long long) length, (unsigned long long) (fromhost & 0xffffffffu));
        return 1;
    }
    printf("OK\n");
    return 0;
}
