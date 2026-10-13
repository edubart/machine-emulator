// A shadow WRITE-TLB slot that targets a non-writable memory range lets cm_run write to that range.
//
// Usage: rotlb <work-dir>
//
// shadow_tlb_verify_slot (src/shadow-tlb.hpp) validates a committed shadow TLB slot before it becomes a hot entry. It
// checks the invalid marker, the padding, the alignment, that the PMA is a memory range and that the page is in
// bounds, but not the permission of the set the slot belongs to. The slow store path only installs WRITE-TLB entries
// for writable (W=1) ranges, but a slot in committed state (written with the documented full-shadow cm_write_memory
// "manual snapshot" path, or present in a stored machine directory) is trusted as is. The fast store path then
// writes through it with no further check.
//
// Guest (M-mode, satp = 0, so virtual == physical), hand-encoded at the start of RAM:
//   RAM+0x00: auipc x3, 0         ; x3 = RAM
//   RAM+0x04: ld    x2, 24(x3)    ; x2 = target address (the dword at RAM+0x18)
//   RAM+0x08: addi  x1, x0, 0x55
//   RAM+0x0c: sd    x1, 0(x2)     ; store to the non-writable target
//   RAM+0x10: j     .             ; spin (also the trap vector: mtvec = RAM+0x10)
//   RAM+0x14: nop
//   RAM+0x18: .dword target
//
// Cases, each in a child process (a host crash is observed instead of killing the test):
//   control:         no crafted slot, target = PMA table (0x10000). The store must raise a store access fault
//                    (mcause 7) and leave the PMA table unchanged. This checks the premise: the target is not writable
//                    by the guest.
//   pma-table:       crafted WRITE-TLB slot vaddr 0x10000 -> PMA table range, freshly created machine.
//   pma-table-loaded: the same on a machine stored and loaded back (the PMA table is then mapped read-only on the host).
//   ro-flash:        crafted WRITE-TLB slot to a read-only flash drive backed by a file in <work-dir>.
// Property checked (what a fix restores): cm_run never modifies a non-writable range through such a slot (the slot
// must be rejected, so the store takes the slow path and faults) and the host process does not crash.
//
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure / control failed.
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

enum { CHILD_OK = 0, CHILD_BUG = 1, CHILD_SETUP = 2 };

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            printf("    setup failed: %s: %s\n", #x, cm_get_last_error_message());                                    \
            _exit(CHILD_SETUP);                                                                                        \
        }                                                                                                              \
    } while (0)

// Shadow TLB layout (src/shadow-tlb.hpp): 3 sets (CODE, READ, WRITE) of 256 slots of 32 bytes each
// {vaddr_page, vp_offset, pma_index, zero_padding}.
enum { TLB_WRITE = 2, TLB_SET_SIZE = 256, TLB_SLOT_SIZE = 32, PAGE_SIZE = 4096 };
// PMA table entry (src/pmas-constants.hpp): {istart, ilength}, istart = start | flags; M is bit 0, W is bit 3.
#define PMA_ISTART_M_MASK UINT64_C(1)
#define PMA_ISTART_W_MASK (UINT64_C(1) << 3)
#define PMA_ISTART_START_MASK (~UINT64_C(0) << 12)
#define PMA_ENTRY_SIZE 16

#define FLASH_START UINT64_C(0x80000000000000)
#define MCAUSE_STORE_ACCESS_FAULT 7

static void put_u64(uint8_t *p, uint64_t v) {
    memcpy(p, &v, sizeof v);
}
static uint64_t get_u64(const uint8_t *p) {
    uint64_t v = 0;
    memcpy(&v, p, sizeof v);
    return v;
}

static void write_guest(cm_machine *m, uint64_t target) {
    uint8_t prog[32];
    const uint32_t insns[6] = {0x00000197u, 0x0181b103u, 0x05500093u, 0x00113023u, 0x0000006fu, 0x00000013u};
    memcpy(prog, insns, sizeof insns);
    put_u64(prog + 24, target);
    CHK(cm_write_memory(m, CM_AR_RAM_START, prog, sizeof prog));
    CHK(cm_write_reg(m, CM_REG_MTVEC, CM_AR_RAM_START + 0x10));
}

// Index of the PMA entry of the memory range that starts at range_start, with a check that it is not writable.
static uint64_t find_pma_index(cm_machine *m, uint64_t range_start) {
    uint8_t pmas[CM_AR_PMAS_LENGTH];
    CHK(cm_read_memory(m, CM_AR_PMAS_START, pmas, sizeof pmas));
    for (uint64_t i = 0; i < sizeof pmas / PMA_ENTRY_SIZE; i++) {
        const uint64_t istart = get_u64(pmas + i * PMA_ENTRY_SIZE);
        if ((istart & PMA_ISTART_M_MASK) != 0 && (istart & PMA_ISTART_START_MASK) == range_start) {
            if ((istart & PMA_ISTART_W_MASK) != 0) {
                printf("    setup failed: range 0x%" PRIx64 " is writable (istart=0x%" PRIx64 ")\n", range_start,
                    istart);
                _exit(CHILD_SETUP);
            }
            return i;
        }
    }
    printf("    setup failed: no memory PMA starts at 0x%" PRIx64 "\n", range_start);
    _exit(CHILD_SETUP);
}

// Install WRITE-TLB slot vaddr_page -> paddr_page (identity) in the committed shadow, through the full-shadow
// cm_write_memory (the path that re-initializes the hot TLB from the shadow TLB).
static void craft_write_tlb_slot(cm_machine *m, uint64_t page, uint64_t pma_index) {
    static uint8_t shadow[CM_AR_SHADOW_STATE_LENGTH];
    CHK(cm_read_memory(m, CM_AR_SHADOW_STATE_START, shadow, sizeof shadow));
    const uint64_t slot_index = (page / PAGE_SIZE) % TLB_SET_SIZE;
    uint8_t *slot = shadow + CM_AR_SHADOW_TLB_START + (uint64_t) TLB_WRITE * TLB_SET_SIZE * TLB_SLOT_SIZE +
        slot_index * TLB_SLOT_SIZE;
    put_u64(slot + 0, page);       // vaddr_page
    put_u64(slot + 8, 0);          // vp_offset (paddr == vaddr)
    put_u64(slot + 16, pma_index); // pma_index
    put_u64(slot + 24, 0);         // zero_padding_
    CHK(cm_write_memory(m, CM_AR_SHADOW_STATE_START, shadow, sizeof shadow));
}

typedef enum { CASE_CONTROL, CASE_PMA_TABLE, CASE_PMA_TABLE_LOADED, CASE_RO_FLASH } case_id;

static int run_case(case_id id, const char *workdir) {
    char config[8192];
    char path[4096];
    uint64_t target = CM_AR_PMAS_START;
    snprintf(config, sizeof config, "{\"ram\":{\"length\":65536}}");
    if (id == CASE_RO_FLASH) {
        // 4 KiB read-only flash drive backed by a file filled with 0xaa
        snprintf(path, sizeof path, "%s/ro-flash.bin", workdir);
        FILE *f = fopen(path, "wb");
        if (!f) {
            printf("    setup failed: cannot create %s\n", path);
            return CHILD_SETUP;
        }
        for (int i = 0; i < PAGE_SIZE; i++) {
            fputc(0xaa, f);
        }
        fclose(f);
        snprintf(config, sizeof config,
            "{\"ram\":{\"length\":65536},\"flash_drive\":[{\"start\":%" PRIu64 ",\"length\":%d,\"read_only\":true,"
            "\"backing_store\":{\"data_filename\":\"%s\"}}]}",
            FLASH_START, PAGE_SIZE, path);
        target = FLASH_START;
    }
    cm_machine *m = NULL;
    CHK(cm_create_new(config, NULL, NULL, &m));
    if (id == CASE_PMA_TABLE_LOADED) {
        snprintf(path, sizeof path, "%s/stored", workdir);
        CHK(cm_store(m, path, CM_SHARING_ALL));
        cm_delete(m);
        m = NULL;
        CHK(cm_load_new(path, NULL, CM_SHARING_NONE, &m));
    }
    write_guest(m, target);
    const uint64_t pma_index = find_pma_index(m, target);
    if (id != CASE_CONTROL) {
        craft_write_tlb_slot(m, target, pma_index);
    }
    static uint8_t before[PAGE_SIZE];
    static uint8_t after[PAGE_SIZE];
    CHK(cm_read_memory(m, target, before, sizeof before));
    printf("    target 0x%" PRIx64 " (PMA index %" PRIu64 ", W=0), first dword before: 0x%016" PRIx64 "\n", target,
        pma_index, get_u64(before));
    cm_break_reason br = CM_BREAK_REASON_FAILED;
    const cm_error err = cm_run(m, 16, &br);
    char msg[256] = "ok";
    if (err != CM_ERROR_OK) {
        snprintf(msg, sizeof msg, "error %d: %s", (int) err, cm_get_last_error_message());
    }
    uint64_t mcause = 0;
    CHK(cm_read_reg(m, CM_REG_MCAUSE, &mcause));
    CHK(cm_read_memory(m, target, after, sizeof after));
    const int changed = memcmp(before, after, sizeof before) != 0;
    printf("    cm_run(16): %s, mcause=%" PRIu64 ", first dword after: 0x%016" PRIx64 ", range %s\n", msg, mcause,
        get_u64(after), changed ? "MODIFIED" : "unchanged");
    cm_delete(m);
    if (id == CASE_CONTROL) {
        return (!changed && mcause == MCAUSE_STORE_ACCESS_FAULT) ? CHILD_OK : CHILD_SETUP;
    }
    return changed ? CHILD_BUG : CHILD_OK;
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    // A crashing child must not leave a core file behind
    const struct rlimit no_core = {0, 0};
    setrlimit(RLIMIT_CORE, &no_core);
    static const struct {
        case_id id;
        const char *name;
    } cases[] = {
        {CASE_CONTROL, "control: honest machine, guest store to the PMA table"},
        {CASE_PMA_TABLE, "pma-table: crafted WRITE-TLB slot -> PMA table, created machine"},
        {CASE_PMA_TABLE_LOADED, "pma-table-loaded: crafted WRITE-TLB slot -> PMA table, stored and loaded machine"},
        {CASE_RO_FLASH, "ro-flash: crafted WRITE-TLB slot -> read-only flash drive"},
    };
    int bugs = 0;
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        printf("== %s\n", cases[i].name);
        const pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 2;
        }
        if (pid == 0) {
            _exit(run_case(cases[i].id, argv[1]));
        }
        int status = 0;
        if (waitpid(pid, &status, 0) != pid) {
            perror("waitpid");
            return 2;
        }
        if (WIFSIGNALED(status)) {
            printf("    child killed by signal %d (%s) during cm_run\n", WTERMSIG(status), strsignal(WTERMSIG(status)));
            if (cases[i].id == CASE_CONTROL) {
                return 2;
            }
            bugs++;
            continue;
        }
        const int code = WIFEXITED(status) ? WEXITSTATUS(status) : CHILD_SETUP;
        if (code == CHILD_SETUP) {
            printf("    case setup or control failed\n");
            return 2;
        }
        if (code == CHILD_BUG) {
            bugs++;
        }
    }
    printf("== %d of 3 crafted-slot case(s) reproduced\n", bugs);
    return bugs ? 1 : 0;
}
