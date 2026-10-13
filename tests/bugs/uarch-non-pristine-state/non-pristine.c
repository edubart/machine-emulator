// Compares the big-machine execution paths with the uarch big step on machines whose uarch state is not pristine.
//
// Usage: non-pristine <work-dir>
//
// The documented equivalence is: running the uarch until it halts and then resetting it (the "big step", which is
// what the on-chain step verifier executes) is equivalent to running one mcycle of the main processor (cm_run, and
// the other host-interpreter paths cm_log_step and cm_collect_mcycle_root_hashes). That only holds when the uarch
// starts from its pristine state, but nothing checks it: a machine created with non-reset uarch registers or with a
// custom uarch RAM image (with uarch_cycle == 0) is accepted, and the paths silently disagree.
//
// For each variant, the machine must either be rejected (by cm_create_new, or by each host-interpreter path), or each
// host-interpreter path must produce the same root hash as the uarch big step.
//
// Exit codes: 0 = no divergence, 1 = divergence found, 2 = setup failure (or the pristine control disagrees).
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

static const char *work_dir;

// Big-machine program: addi x6,x0,7 ; j .
static const uint32_t prog[] = {0x00700313u, 0x0000006fu};

// RV64I encoders used to build a custom uarch RAM image at run time (no cross compiler needed)
static uint32_t addi(uint32_t rd, uint32_t rs1, int32_t imm) {
    return ((uint32_t) (imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13u;
}
static uint32_t sd(uint32_t rs2, uint32_t rs1, int32_t imm) {
    return ((uint32_t) ((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (3u << 12) |
        ((uint32_t) (imm & 0x1f) << 7) | 0x23u;
}

static void hash_to_base64(const cm_hash *h, char *out) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *p = *h;
    int o = 0;
    for (int i = 0; i < 32; i += 3) {
        uint32_t v = (uint32_t) p[i] << 16;
        if (i + 1 < 32) v |= (uint32_t) p[i + 1] << 8;
        if (i + 2 < 32) v |= p[i + 2];
        out[o++] = tbl[(v >> 18) & 63];
        out[o++] = tbl[(v >> 12) & 63];
        out[o++] = (i + 1 < 32) ? tbl[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < 32) ? tbl[v & 63] : '=';
    }
    out[o] = 0;
}

static void print_hash(const char *tag, const cm_hash *h) {
    printf("    %-28s ", tag);
    for (int i = 0; i < 8; i++) {
        printf("%02x", (*h)[i]);
    }
    printf("...\n");
}

static void print_big_regs(const char *tag, cm_machine *m) {
    uint64_t mcycle = 0, pc = 0, x5 = 0, x6 = 0;
    cm_read_reg(m, CM_REG_MCYCLE, &mcycle);
    cm_read_reg(m, CM_REG_PC, &pc);
    cm_read_reg(m, CM_REG_X5, &x5);
    cm_read_reg(m, CM_REG_X6, &x6);
    printf("    %-28s mcycle=%" PRIu64 " pc=0x%" PRIx64 " x5=0x%" PRIx64 " x6=0x%" PRIx64 "\n", tag, mcycle, pc, x5, x6);
}

// Creates the machine for a variant and loads the big-machine program. Returns NULL if creation is rejected.
static cm_machine *create(const char *cfg) {
    cm_machine *m = NULL;
    if (cm_create_new(cfg, NULL, NULL, &m) != CM_ERROR_OK) {
        return NULL;
    }
    CHK(cm_write_memory(m, CM_AR_RAM_START, (const uint8_t *) prog, sizeof(prog)));
    return m;
}

enum { PATH_RUN, PATH_LOG, PATH_COLLECT, PATH_COUNT };
static const char *path_names[PATH_COUNT] = {"cm_run(1)", "cm_log_step(1)", "cm_collect_mcycle_root_hashes(1)"};

// Executes one mcycle through a host-interpreter path.
// Returns 0 if rejected, 1 if it agrees with the big step, 2 if it disagrees (or the big step failed).
static int host_path(int path, const char *cfg, int big_step_ok, const cm_hash *big_step_hash) {
    cm_machine *m = create(cfg);
    if (!m) {
        printf("    %-28s rejected by cm_create_new: %s\n", path_names[path], cm_get_last_error_message());
        return 0;
    }
    uint64_t mcycle = 0;
    CHK(cm_read_reg(m, CM_REG_MCYCLE, &mcycle));
    cm_error err = CM_ERROR_OK;
    cm_break_reason br;
    cm_hash h;
    int agrees = 0;
    if (path == PATH_RUN) {
        err = cm_run(m, mcycle + 1, &br);
    } else if (path == PATH_LOG) {
        static int log_counter = 0;
        char log_filename[4096];
        snprintf(log_filename, sizeof(log_filename), "%s/step-%d.log", work_dir, log_counter++);
        remove(log_filename);
        err = cm_log_step(m, 1, log_filename, &br);
    } else {
        const char *result = NULL;
        err = cm_collect_mcycle_root_hashes(m, mcycle + 1, 0, 0, 0, NULL, &result);
        if (err == CM_ERROR_OK && big_step_ok) {
            // The collected state root hash must be the one the big step produces
            char b64[64];
            hash_to_base64(big_step_hash, b64);
            agrees = strstr(result, b64) != NULL;
        }
    }
    if (err != CM_ERROR_OK) {
        printf("    %-28s rejected: %s\n", path_names[path], cm_get_last_error_message());
        cm_delete(m);
        return 0;
    }
    CHK(cm_get_root_hash(m, &h));
    if (path != PATH_COLLECT) {
        agrees = big_step_ok && memcmp(h, *big_step_hash, sizeof(h)) == 0;
    }
    print_hash(path_names[path], &h);
    if (path == PATH_RUN) {
        print_big_regs("  after cm_run:", m);
    }
    cm_delete(m);
    return agrees ? 1 : 2;
}

// Runs one variant. Returns 1 if some host-interpreter path silently disagrees with the uarch big step.
static int variant(const char *name, const char *cfg) {
    printf("== %s\n", name);
    // Uarch big step: run the uarch until it halts, then reset it
    int big_step_ok = 0;
    cm_hash big_step_hash;
    cm_machine *b = create(cfg);
    if (!b) {
        printf("    rejected by cm_create_new: %s\n", cm_get_last_error_message());
        return 0;
    }
    cm_uarch_break_reason ubr;
    if (cm_run_uarch(b, CM_UARCH_CYCLE_MAX, &ubr) != CM_ERROR_OK) {
        printf("    %-28s failed: %s\n", "uarch big step", cm_get_last_error_message());
    } else if (ubr != CM_UARCH_BREAK_REASON_UARCH_HALTED) {
        printf("    %-28s failed: uarch did not halt (break reason %d)\n", "uarch big step", (int) ubr);
    } else if (cm_reset_uarch(b) != CM_ERROR_OK) {
        printf("    %-28s failed: cm_reset_uarch: %s\n", "uarch big step", cm_get_last_error_message());
    } else {
        CHK(cm_get_root_hash(b, &big_step_hash));
        big_step_ok = 1;
        print_hash("uarch big step", &big_step_hash);
        print_big_regs("  after uarch big step:", b);
    }
    cm_delete(b);
    int diverged = 0;
    for (int path = 0; path < PATH_COUNT; path++) {
        if (host_path(path, cfg, big_step_ok, &big_step_hash) == 2) {
            printf("    => %s accepted the machine and %s the uarch big step\n", path_names[path],
                big_step_ok ? "DISAGREES with" : "succeeded while it failed in");
            diverged = 1;
        }
    }
    printf("    => %s\n", diverged ? "DIVERGENT" : "consistent");
    return diverged;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    work_dir = argv[1];
    const char *ram = "\"ram\":{\"length\":4096}";
    char cfg[8192];

    // Pristine control: all paths must agree, otherwise the comparison itself is wrong
    snprintf(cfg, sizeof(cfg), "{%s}", ram);
    if (variant("pristine uarch (control)", cfg) != 0) {
        printf("ERROR: the paths disagree even with a pristine uarch\n");
        return 2;
    }

    // Query the layout from the emulator instead of hard-coding it
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    uint64_t uarch_pc = 0, mcycle_addr = 0, x5_addr = 0;
    CHK(cm_read_reg(m, CM_REG_UARCH_PC, &uarch_pc));
    CHK(cm_get_reg_address(m, CM_REG_MCYCLE, &mcycle_addr));
    CHK(cm_get_reg_address(m, CM_REG_X5, &x5_addr));
    cm_delete(m);
    if (mcycle_addr > 2047 || x5_addr > 2047) {
        fprintf(stderr, "setup failed: register addresses do not fit in a 12-bit immediate\n");
        return 2;
    }

    // Custom uarch RAM image: instead of emulating one instruction, it sets mcycle=1 (so it looks like one mcycle
    // was executed), writes a bogus value to big-machine x5, and halts the uarch.
    const uint32_t uarch_image[] = {
        addi(10, 0, 1),                     // li a0, 1
        addi(11, 0, (int32_t) mcycle_addr), // li a1, &mcycle
        sd(10, 11, 0),                      // sd a0, 0(a1)
        addi(12, 0, 0x123),                 // li a2, 0x123
        addi(13, 0, (int32_t) x5_addr),     // li a3, &x5
        sd(12, 13, 0),                      // sd a2, 0(a3)
        addi(17, 0, 1),                     // li a7, UARCH_ECALL_FN_HALT
        0x00000073u,                        // ecall
    };
    char image_filename[4096];
    snprintf(image_filename, sizeof(image_filename), "%s/uarch-ram.bin", work_dir);
    FILE *f = fopen(image_filename, "wb");
    if (!f || fwrite(uarch_image, sizeof(uarch_image), 1, f) != 1 || fclose(f) != 0) {
        fprintf(stderr, "setup failed: cannot write %s\n", image_filename);
        return 2;
    }

    int bugs = 0;
    snprintf(cfg, sizeof(cfg), "{%s,\"uarch\":{\"processor\":{\"registers\":{\"halt\":1}}}}", ram);
    bugs += variant("uarch halt=1", cfg);
    snprintf(cfg, sizeof(cfg), "{%s,\"uarch\":{\"processor\":{\"registers\":{\"x1\":1}}}}", ram);
    bugs += variant("uarch x1=1", cfg);
    snprintf(cfg, sizeof(cfg), "{%s,\"uarch\":{\"processor\":{\"registers\":{\"pc\":%" PRIu64 "}}}}", ram,
        uarch_pc + 8);
    bugs += variant("uarch pc=initial+8", cfg);
    snprintf(cfg, sizeof(cfg), "{%s,\"uarch\":{\"ram\":{\"backing_store\":{\"data_filename\":\"%s\"}}}}", ram,
        image_filename);
    bugs += variant("custom uarch RAM image", cfg);

    printf("%d of 4 non-pristine uarch variants diverge\n", bugs);
    return bugs ? 1 : 0;
}
