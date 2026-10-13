// cm_read_virtual_memory()/cm_write_virtual_memory() compute the page-rounded end of the request as
// (vaddr + length + 0xfff) & ~0xfff (src/machine.cpp read/write_virtual_memory). When the last byte of the
// range is in the top page of the 64-bit address space, that value overflows to a small number, the page
// loop runs zero times and the call reports success without reading/writing anything. Ranges that wrap
// past 2^64 are also "successfully" ignored instead of being rejected.
// The test maps the two top virtual pages with a real Sv39 page table, switches to S-mode and checks that
// every request that reports success actually transferred the data, and that a wrapping request fails.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cm.h>

#define ROOT UINT64_C(0x80010000) // Sv39 root page table
#define L1 UINT64_C(0x80011000)
#define L0 UINT64_C(0x80012000)
#define P0 UINT64_C(0x80020000) // physical page mapped at vaddr 0xffffffffffffe000
#define P1 UINT64_C(0x80021000) // physical page mapped at vaddr 0xfffffffffffff000
#define VTOP0 UINT64_C(0xffffffffffffe000)
#define VTOP1 UINT64_C(0xfffffffffffff000)
#define PAGE 0x1000

static cm_machine *m = NULL;

static void check(cm_error e, const char *what) {
    if (e != CM_ERROR_OK) {
        fprintf(stderr, "%s failed: %s\n", what, cm_get_last_error_message());
        exit(2);
    }
}

static void write_pte(uint64_t table, int index, uint64_t pa, uint64_t flags) {
    uint64_t pte = ((pa >> 12) << 10) | flags;
    uint8_t b[8];
    for (int i = 0; i < 8; i++) {
        b[i] = (uint8_t) (pte >> (8 * i));
    }
    check(cm_write_memory(m, table + 8 * (uint64_t) index, b, sizeof b), "cm_write_memory(pte)");
}

static int all_bytes(uint64_t paddr, uint64_t length, uint8_t value) {
    static uint8_t buf[PAGE];
    check(cm_read_memory(m, paddr, buf, length), "cm_read_memory");
    for (uint64_t i = 0; i < length; i++) {
        if (buf[i] != value) {
            return 0;
        }
    }
    return 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    check(cm_create_new("{\"ram\":{\"length\":1048576}}", NULL, NULL, &m), "cm_create_new");
    // Sv39: VPN[2] = VPN[1] = 0x1ff, VPN[0] = 0x1fe / 0x1ff
    write_pte(ROOT, 0x1ff, L1, 0x1);  // V (pointer)
    write_pte(L1, 0x1ff, L0, 0x1);    // V (pointer)
    write_pte(L0, 0x1fe, P0, 0xc7);   // V R W A D
    write_pte(L0, 0x1ff, P1, 0xc7);   // V R W A D
    check(cm_write_reg(m, CM_REG_SATP, (8ULL << 60) | (ROOT >> 12)), "cm_write_reg(satp)");
    check(cm_write_reg(m, CM_REG_IPRV, 1), "cm_write_reg(iprv)"); // S-mode, so translation applies
    static uint8_t page[2 * PAGE];
    memset(page, 'P', PAGE);
    check(cm_write_memory(m, P1, page, PAGE), "cm_write_memory(P1)");
    uint64_t pa0 = 0, pa1 = 0;
    check(cm_translate_virtual_address(m, VTOP0, &pa0), "translate");
    check(cm_translate_virtual_address(m, VTOP1, &pa1), "translate");
    if (pa0 != P0 || pa1 != P1) {
        fprintf(stderr, "page table setup failed\n");
        return 2;
    }

    // control: a request that does not touch the top page works
    memset(page, 'C', 0x800);
    check(cm_write_virtual_memory(m, VTOP0, page, 0x800), "control write");
    if (!all_bytes(P0, 0x800, 'C')) {
        fprintf(stderr, "control write did not work\n");
        return 2;
    }
    printf("control write [0x%" PRIx64 ", +0x800): written\n", VTOP0);

    int bug = 0;
    // 1) mapped, non-wrapping write spanning the two top pages (last byte 0xfffffffffffff7ff)
    memset(page, 'W', PAGE);
    cm_error e = cm_write_virtual_memory(m, VTOP0 + 0x800, page, PAGE);
    int written = all_bytes(P0 + 0x800, 0x800, 'W') && all_bytes(P1, 0x800, 'W');
    printf("write [0x%" PRIx64 ", +0x1000): returned %d, data written: %s\n", VTOP0 + 0x800, (int) e,
        written ? "yes" : "no");
    if (e == CM_ERROR_OK && !written) {
        printf("  success reported but nothing was written\n");
        bug = 1;
    }

    // 2) mapped read of the whole top page (range ends exactly at 2^64)
    uint8_t expected[PAGE];
    check(cm_read_memory(m, P1, expected, PAGE), "cm_read_memory(P1)");
    uint8_t got[PAGE];
    memset(got, 0xaa, sizeof got); // sentinel: not the page contents
    e = cm_read_virtual_memory(m, VTOP1, got, PAGE);
    int correct = memcmp(got, expected, PAGE) == 0;
    printf("read  [0x%" PRIx64 ", +0x1000): returned %d, data correct: %s\n", VTOP1, (int) e, correct ? "yes" : "no");
    if (e == CM_ERROR_OK && !correct) {
        printf("  success reported but the buffer does not hold the page contents\n");
        bug = 1;
    }

    // 3) write that wraps past 2^64 (vaddr 0 is not mapped): must fail
    memset(page, 'X', sizeof page);
    e = cm_write_virtual_memory(m, VTOP1, page, 2 * PAGE);
    printf("write [0x%" PRIx64 ", +0x2000) wraps around: returned %d (%s)\n", VTOP1, (int) e,
        e != CM_ERROR_OK ? cm_get_last_error_message() : "success");
    if (e == CM_ERROR_OK) {
        printf("  wrapping request reported success\n");
        bug = 1;
    }
    cm_delete(m);

    if (bug) {
        printf("BUG REPRODUCED: virtual memory API reports success without transferring data for ranges ending in "
               "the top page of the address space (page-limit overflow)\n");
        return 1;
    }
    printf("OK: virtual memory requests touching the top page are serviced or rejected\n");
    return 0;
}
