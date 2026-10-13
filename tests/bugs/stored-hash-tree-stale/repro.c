// Persisted hash-tree files (.dht/.dpt) written by the emulator itself can miss pages modified by the guest,
// so a later session trusts stale page hashes and reports a root hash that does not match the data.
// Cause: dirty-page marking for pages in the hot write TLB is deferred until the slot is evicted or the hash
// tree is updated (mark_write_tlb_dirty_pages()). machine::store() and ~machine() persist/close the dirty
// page tree without flushing those pending marks; when the processor state (which holds the TLB) is not
// persisted together with the tree, the marks are lost and the pages count as clean on reload.
// No tampering is involved; the three scenarios use documented features:
//   A: in-memory machine with a flash drive whose data, dht and dpt files are shared; session 1 runs and
//      exits normally, session 2 creates the same machine from the same files.
//   B: machine created on disk (cm_create with a directory), loaded with CM_SHARING_CONFIG (flash shared),
//      run, deleted, loaded again.
//   C: same on-disk machine loaded with CM_SHARING_CONFIG, run, stored with cm_store(CM_SHARING_CONFIG),
//      the stored copy loaded.
// Each reloaded machine's root hash is compared with the root hash of the same state recomputed from scratch:
// a fresh in-memory machine (same config, same program, same cycles before the flash-only changes) into
// which the reloaded machine's flash contents are written with cm_write_memory().
// A smaller page hash-tree cache (phtc_size) keeps the stored directories small; it does not affect the bug.
// Usage: repro <work-dir>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cm.h>

#define RAM_START UINT64_C(0x80000000)
#define FLASH_START UINT64_C(0x80000000000000)
#define FLASH_LENGTH 0x10000 // 16 pages
#define GUEST_CYCLES 1000    // the guest writes all 16 flash pages several times

// Hand-encoded RV64 program (no cross toolchain needed): an endless loop that stores an incrementing
// counter into the first word of each of the 16 pages of the flash drive.
static const uint32_t program[] = {
    0x00100293, //        addi t0, zero, 1
    0x03729293, //        slli t0, t0, 55     t0 = 0x80000000000000 (flash drive)
    0x00000313, //        addi t1, zero, 0
    0x00130313, // loop:  addi t1, t1, 1
    0x00028e13, //        addi t3, t0, 0
    0x01000393, //        addi t2, zero, 16
    0x006e3023, // inner: sd   t1, 0(t3)
    0x00001eb7, //        lui  t4, 1
    0x01de0e33, //        add  t3, t3, t4      next page
    0xfff38393, //        addi t2, t2, -1
    0xfe0398e3, //        bnez t2, inner
    0xfe1ff06f, //        j    loop
};

static const char *work_dir = NULL;

static void check(cm_error e, const char *what) {
    if (e != CM_ERROR_OK) {
        fprintf(stderr, "%s failed: %s\n", what, cm_get_last_error_message());
        exit(2);
    }
}

static void print_hash(const char *label, const cm_hash *h) {
    printf("  %-38s", label);
    for (int i = 0; i < 32; i++) {
        printf("%02x", (*h)[i]);
    }
    printf("\n");
}

static void path(char *out, size_t size, const char *name) {
    snprintf(out, size, "%s/%s", work_dir, name);
}

static void flash_config(char *out, size_t size, const char *backing_store) {
    snprintf(out, size,
        "{\"ram\":{\"length\":65536},\"hash_tree\":{\"phtc_size\":1024},"
        "\"flash_drive\":[{\"start\":%" PRIu64 ",\"length\":%d%s%s}]}",
        FLASH_START, FLASH_LENGTH, backing_store[0] ? ",\"backing_store\":" : "", backing_store);
}

static void write_program(cm_machine *m) {
    uint8_t code[sizeof program];
    for (size_t i = 0; i < sizeof program / sizeof program[0]; i++) {
        for (int b = 0; b < 4; b++) {
            code[4 * i + b] = (uint8_t) (program[i] >> (8 * b));
        }
    }
    check(cm_write_memory(m, RAM_START, code, sizeof code), "cm_write_memory(program)");
}

static void run(cm_machine *m, uint64_t cycles) {
    uint64_t mcycle = 0;
    check(cm_read_reg(m, CM_REG_MCYCLE, &mcycle), "cm_read_reg(mcycle)");
    cm_break_reason br;
    check(cm_run(m, mcycle + cycles, &br), "cm_run");
}

// Root hash of the reloaded machine vs. root hash recomputed from scratch.
// warm_cycles: cycles the machine ran before the (flash-only) changes that were persisted.
static int compare_with_scratch(cm_machine *reloaded, uint64_t warm_cycles) {
    cm_hash loaded;
    check(cm_get_root_hash(reloaded, &loaded), "cm_get_root_hash");
    static uint8_t flash[FLASH_LENGTH];
    check(cm_read_memory(reloaded, FLASH_START, flash, sizeof flash), "cm_read_memory(flash)");
    uint64_t mcycle = 0;
    check(cm_read_reg(reloaded, CM_REG_MCYCLE, &mcycle), "cm_read_reg(mcycle)");
    if (mcycle != warm_cycles) {
        fprintf(stderr, "unexpected mcycle %" PRIu64 " in reloaded machine\n", mcycle);
        exit(2);
    }
    char cfg[512];
    flash_config(cfg, sizeof cfg, "");
    cm_machine *ref = NULL;
    check(cm_create_new(cfg, NULL, NULL, &ref), "cm_create_new(reference)");
    write_program(ref);
    run(ref, warm_cycles);
    check(cm_write_memory(ref, FLASH_START, flash, sizeof flash), "cm_write_memory(flash)");
    cm_hash scratch;
    check(cm_get_root_hash(ref, &scratch), "cm_get_root_hash(reference)");
    cm_delete(ref);
    uint64_t word = 0;
    memcpy(&word, flash, sizeof word);
    printf("  flash word 0 (written by the guest)    %" PRIu64 "\n", word);
    if (word == 0) {
        fprintf(stderr, "guest writes did not reach the flash drive\n");
        exit(2);
    }
    print_hash("root hash of the reloaded machine", &loaded);
    print_hash("root hash recomputed from scratch", &scratch);
    if (memcmp(loaded, scratch, sizeof loaded) != 0) {
        printf("  => STALE: persisted hash tree does not match the data\n");
        return 1;
    }
    printf("  => consistent\n");
    return 0;
}

static int scenario_a(void) {
    printf("A: in-memory machine, flash drive with shared data/dht/dpt files, reopened after a session\n");
    char data[512], dht[512], dpt[512], bs[2048], cfg[4096];
    path(data, sizeof data, "a-flash.bin");
    path(dht, sizeof dht, "a-flash.dht");
    path(dpt, sizeof dpt, "a-flash.dpt");
    FILE *f = fopen(data, "wb");
    static const uint8_t zeros[FLASH_LENGTH];
    if (f == NULL || fwrite(zeros, 1, sizeof zeros, f) != sizeof zeros || fclose(f) != 0) {
        perror("a-flash.bin");
        exit(2);
    }
    snprintf(bs, sizeof bs,
        "{\"data_filename\":\"%s\",\"dht_filename\":\"%s\",\"dpt_filename\":\"%s\",\"shared\":true}", data, dht, dpt);
    flash_config(cfg, sizeof cfg, bs);
    // session 1: hash (tree files now clean), run the guest, close normally
    cm_machine *m = NULL;
    check(cm_create_new(cfg, NULL, NULL, &m), "cm_create_new(A session 1)");
    write_program(m);
    cm_hash h;
    check(cm_get_root_hash(m, &h), "cm_get_root_hash");
    run(m, GUEST_CYCLES);
    cm_delete(m);
    // session 2: same configuration, reusing the persisted files
    check(cm_create_new(cfg, NULL, NULL, &m), "cm_create_new(A session 2)");
    write_program(m);
    int r = compare_with_scratch(m, 0);
    cm_delete(m);
    return r;
}

// Creates the on-disk machine used by scenarios B and C (2 cycles run, hash tree clean).
static void create_on_disk(const char *dir) {
    char cfg[512];
    flash_config(cfg, sizeof cfg, "{\"shared\":true}");
    cm_machine *m = NULL;
    check(cm_create_new(cfg, NULL, dir, &m), "cm_create_new(on disk)");
    write_program(m);
    run(m, 2);
    cm_hash h;
    check(cm_get_root_hash(m, &h), "cm_get_root_hash");
    cm_delete(m);
}

static int scenario_b(void) {
    printf("B: on-disk machine loaded with CM_SHARING_CONFIG, run, closed, reloaded\n");
    char dir[512];
    path(dir, sizeof dir, "b");
    create_on_disk(dir);
    cm_machine *m = NULL;
    check(cm_load_new(dir, NULL, CM_SHARING_CONFIG, &m), "cm_load_new(B, config)");
    run(m, GUEST_CYCLES); // flash changes persist, processor/RAM changes are discarded
    cm_delete(m);
    check(cm_load_new(dir, NULL, CM_SHARING_NONE, &m), "cm_load_new(B, none)");
    int r = compare_with_scratch(m, 2);
    cm_delete(m);
    return r;
}

static int scenario_c(void) {
    printf("C: on-disk machine loaded with CM_SHARING_CONFIG, run, stored with cm_store(CM_SHARING_CONFIG)\n");
    char dir[512], stored[512];
    path(dir, sizeof dir, "c");
    path(stored, sizeof stored, "c-stored");
    create_on_disk(dir);
    cm_machine *m = NULL;
    check(cm_load_new(dir, NULL, CM_SHARING_CONFIG, &m), "cm_load_new(C, config)");
    run(m, GUEST_CYCLES);
    check(cm_store(m, stored, CM_SHARING_CONFIG), "cm_store(C, config)");
    cm_delete(m);
    check(cm_load_new(stored, NULL, CM_SHARING_NONE, &m), "cm_load_new(C stored, none)");
    int r = compare_with_scratch(m, 2);
    cm_delete(m);
    return r;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    work_dir = argv[1];
    int bug = scenario_a();
    bug |= scenario_b();
    bug |= scenario_c();
    if (bug) {
        printf("BUG REPRODUCED: emulator-produced hash-tree files miss pages written by the guest; the reloaded "
               "machine reports a root hash that does not match its data\n");
        return 1;
    }
    printf("OK: reloaded root hashes match the root hashes recomputed from scratch\n");
    return 0;
}
