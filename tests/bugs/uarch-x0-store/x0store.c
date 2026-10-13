// A uarch store to the uarch_x0 shadow word is refused by the host but accepted by the step verifier.
//
// Usage: x0store <work-dir>
//
// Host: uarch_step's SD goes through machine::write_word (src/machine.cpp) to write_reg(reg::uarch_x0), which throws
// "register is read-only", so cm_run_uarch and cm_log_step_uarch fail. Verifier: uarch_replay_state_access
// ::do_write_word (src/uarch-replay-state-access.hpp) only checks the access proof, and readX reads x0 from the
// shadow, so cm_verify_step_uarch (the reference the Solidity UArchStep is transpiled from) accepts a log of the
// very same step, and the verified post-state has uarch x0 = 7. An honest host cannot log or run the step that the
// verifier accepts.
//
// No modified library is needed: the log is built here from cm_get_proof of the official pre-state. All writes of
// the step land in the 32-byte leaf at 0x400000 (uarch_halt_flag, uarch_cycle, uarch_pc, uarch_x0), so the sibling
// hashes of that leaf stay valid after each write; the written-leaf hashes are obtained from cm_get_proof of a
// scratch machine whose RAM holds the leaf bytes.
//
// Cases (uarch RAM image: 0x600000 "sd t1, 0(t0)", 0x600004 "nop"):
//   control nop: uarch pc = 0x600004. The constructed log must verify to the root hash the host reaches.
//   control sd:  sd to uarch_pc (writable by the host): t0 = 0x400010, t1 = 0x600008. When the host accepts it,
//                the constructed log must verify to the same root hash (validates the SD access sequence).
//   x0 store:    t0 = 0x400018 (uarch_x0), t1 = 7.
// Property checked (what a fix restores): for the x0 store, host and verifier agree: both refuse it, or both accept
// it with the same root hash.
//
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure / control failed.
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

#define UARCH_LEAF0 UINT64_C(0x400000) // uarch_halt_flag (+0), uarch_cycle (+8), uarch_pc (+16), uarch_x0 (+24)
#define UARCH_HALT UINT64_C(0x400000)
#define UARCH_CYCLE UINT64_C(0x400008)
#define UARCH_PC UINT64_C(0x400010)
#define UARCH_X(i) (UINT64_C(0x400018) + 8 * (uint64_t) (i))
#define UARCH_RAM UINT64_C(0x600000)

static char image_path[4096];
static cm_machine *scratch; // computes leaf hashes

static cm_machine *make_machine(uint64_t pc, uint64_t t0, uint64_t t1) {
    char cfg[8192];
    snprintf(cfg, sizeof(cfg),
        "{\"ram\":{\"length\":65536},\"uarch\":{\"ram\":{\"backing_store\":{\"data_filename\":\"%s\"}}}}", image_path);
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    CHK(cm_write_reg(m, CM_REG_UARCH_PC, pc));
    CHK(cm_write_reg(m, CM_REG_UARCH_X5, t0));
    CHK(cm_write_reg(m, CM_REG_UARCH_X6, t1));
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
        fprintf(stderr, "setup failed: no %s in proof\n", key);
        exit(2);
    }
    s += strlen(pattern);
    const char *e = strchr(s + 1, *s == '[' ? ']' : '"');
    if (e == NULL || (size_t) (e + 1 - s) >= out_size) {
        fprintf(stderr, "setup failed: bad %s in proof\n", key);
        exit(2);
    }
    memcpy(out, s, e + 1 - s);
    out[e + 1 - s] = 0;
}

// Hash of a 32-byte leaf (JSON string), as the machine's hash tree computes it
static void leaf_hash(const uint8_t leaf[32], char *out, size_t out_size) {
    CHK(cm_write_memory(scratch, UINT64_C(0x80000000), leaf, 32));
    const char *proof = NULL;
    CHK(cm_get_proof(scratch, UINT64_C(0x80000000), 5, 64, &proof));
    json_value(proof, "target_hash", out, out_size);
}

// ---- step log builder over the official pre-state
struct leaf {
    uint64_t addr;
    uint8_t data[32];
    char siblings[4096];
};
static struct leaf leaves[8];
static int n_leaves;
static uint64_t written_leaf = UINT64_MAX; // after a write, only that leaf's siblings are still valid
static char log_buf[65536];
static int log_len;
static int n_accesses;

static struct leaf *get_leaf(cm_machine *m, uint64_t addr) {
    const uint64_t la = addr & ~UINT64_C(31);
    if (written_leaf != UINT64_MAX && la != written_leaf) {
        fprintf(stderr, "log builder: access to another leaf after a write\n");
        exit(2);
    }
    for (int i = 0; i < n_leaves; ++i) {
        if (leaves[i].addr == la) return &leaves[i];
    }
    struct leaf *l = &leaves[n_leaves++];
    l->addr = la;
    for (int i = 0; i < 4; ++i) {
        uint64_t w = 0;
        CHK(cm_read_word(m, la + 8 * i, &w));
        memcpy(l->data + 8 * i, &w, 8); // little-endian host
    }
    const char *proof = NULL;
    CHK(cm_get_proof(m, la, 5, 64, &proof));
    json_value(proof, "sibling_hashes", l->siblings, sizeof(l->siblings));
    return l;
}

static void log_access(cm_machine *m, uint64_t addr, int write, uint64_t val) {
    struct leaf *l = get_leaf(m, addr);
    char rd[64], rh[128], wd[64], wh[128];
    base64(l->data, 32, rd);
    leaf_hash(l->data, rh, sizeof(rh));
    log_len += snprintf(log_buf + log_len, sizeof(log_buf) - log_len,
        "%s{\"address\":%" PRIu64 ",\"log2_size\":3,\"read\":\"%s\",\"read_hash\":%s,\"sibling_hashes\":%s",
        n_accesses++ ? "," : "", addr, rd, rh, l->siblings);
    if (write) {
        memcpy(l->data + (addr & 31), &val, 8);
        base64(l->data, 32, wd);
        leaf_hash(l->data, wh, sizeof(wh));
        log_len += snprintf(log_buf + log_len, sizeof(log_buf) - log_len,
            ",\"type\":\"write\",\"written\":\"%s\",\"written_hash\":%s}", wd, wh);
        written_leaf = l->addr;
    } else {
        log_len += snprintf(log_buf + log_len, sizeof(log_buf) - log_len, ",\"type\":\"read\"}");
    }
    if (log_len >= (int) sizeof(log_buf) - 1) {
        fprintf(stderr, "log builder: log too long\n");
        exit(2);
    }
}

// Builds the access log of one uarch step at the machine's current state (uarch_step order: cycle, halt flag,
// pc, instruction fetch, then the instruction's accesses, then the cycle write)
static const char *build_log(cm_machine *m, int is_sd) {
    n_leaves = 0;
    n_accesses = 0;
    written_leaf = UINT64_MAX;
    log_len = snprintf(log_buf, sizeof(log_buf), "{\"accesses\":[");
    uint64_t cycle = 0, pc = 0, t0 = 0, t1 = 0;
    CHK(cm_read_reg(m, CM_REG_UARCH_CYCLE, &cycle));
    CHK(cm_read_reg(m, CM_REG_UARCH_PC, &pc));
    CHK(cm_read_reg(m, CM_REG_UARCH_X5, &t0));
    CHK(cm_read_reg(m, CM_REG_UARCH_X6, &t1));
    log_access(m, UARCH_CYCLE, 0, 0);
    log_access(m, UARCH_HALT, 0, 0);
    log_access(m, UARCH_PC, 0, 0);
    log_access(m, pc & ~UINT64_C(7), 0, 0); // readUint32(pc) -> readUint64(pc & ~7)
    if (is_sd) {                            // sd t1, 0(t0): readX(rs1), readX(rs2), writeUint64(t0, t1)
        log_access(m, UARCH_X(5), 0, 0);
        log_access(m, UARCH_X(6), 0, 0);
        log_access(m, t0, 1, t1);
    } // nop (addi x0, x0, 0) touches no register
    log_access(m, UARCH_PC, 1, pc + 4);
    log_access(m, UARCH_CYCLE, 1, cycle + 1);
    snprintf(log_buf + log_len, sizeof(log_buf) - log_len,
        "],\"log_type\":{\"has_annotations\":false,\"has_large_data\":false}}");
    return log_buf;
}

static void hex8(const cm_hash *h, char *out) {
    for (int i = 0; i < 8; ++i) sprintf(out + 2 * i, "%02x", (*h)[i]);
}

struct outcome {
    int host_ok, ver_ok;
    cm_hash host_root, ver_root;
    char host_err[512], ver_err[512];
};

static struct outcome run_case(const char *title, uint64_t pc, uint64_t t0, uint64_t t1, int is_sd) {
    struct outcome o;
    memset(&o, 0, sizeof(o));
    printf("%s\n", title);
    // host: log the step on the official machine
    cm_machine *m = make_machine(pc, t0, t1);
    const char *host_log = NULL;
    o.host_ok = cm_log_step_uarch(m, 0, &host_log) == CM_ERROR_OK;
    if (o.host_ok) {
        CHK(cm_get_root_hash(m, &o.host_root));
    } else {
        snprintf(o.host_err, sizeof(o.host_err), "%s", cm_get_last_error_message());
    }
    cm_delete(m);
    // verifier: the constructed log of the same step from the same pre-state
    m = make_machine(pc, t0, t1);
    cm_hash before;
    CHK(cm_get_root_hash(m, &before));
    const char *log = build_log(m, is_sd);
    cm_delete(m);
    o.ver_ok = cm_verify_step_uarch(NULL, &before, log, &o.ver_root) == CM_ERROR_OK;
    if (!o.ver_ok) {
        snprintf(o.ver_err, sizeof(o.ver_err), "%s", cm_get_last_error_message());
    }
    char h[17];
    if (o.host_ok) {
        hex8(&o.host_root, h);
        printf("    host cm_log_step_uarch: ok, root after %s\n", h);
    } else {
        printf("    host cm_log_step_uarch: refused: %s\n", o.host_err);
    }
    if (o.ver_ok) {
        hex8(&o.ver_root, h);
        printf("    cm_verify_step_uarch(constructed log): ACCEPTED, root after %s\n", h);
    } else {
        printf("    cm_verify_step_uarch(constructed log): rejected: %s\n", o.ver_err);
    }
    return o;
}

static int same_root(const struct outcome *o) {
    return memcmp(o->host_root, o->ver_root, sizeof(cm_hash)) == 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    snprintf(image_path, sizeof(image_path), "%s/uarch-ram.bin", argc > 1 ? argv[1] : ".");
    const uint32_t image[4] = {
        0x0062b023u, // 0x600000: sd t1, 0(t0)
        0x00000013u, // 0x600004: nop (addi x0, x0, 0)
        0x00000013u, // 0x600008: nop
        0x00000013u, // 0x60000c: nop
    };
    FILE *f = fopen(image_path, "wb");
    if (f == NULL || fwrite(image, sizeof(image), 1, f) != 1 || fclose(f) != 0) {
        perror(image_path);
        return 2;
    }
    CHK(cm_create_new("{\"ram\":{\"length\":4096}}", NULL, NULL, &scratch));

    struct outcome c = run_case("control nop: uarch pc = 0x600004 (nop)", UARCH_RAM + 4, 0, 0, 0);
    if (!c.host_ok || !c.ver_ok || !same_root(&c)) {
        printf("ERROR: control failed: the constructed log does not reproduce the host's step\n");
        return 2;
    }
    c = run_case("control sd: sd t1, 0(t0) with t0 = 0x400010 (uarch_pc), t1 = 0x600008", UARCH_RAM, UARCH_PC,
        UARCH_RAM + 8, 1);
    if (c.host_ok && (!c.ver_ok || !same_root(&c))) {
        printf("ERROR: control failed: the constructed SD log does not reproduce the host's step\n");
        return 2;
    }
    struct outcome x = run_case("x0 store: sd t1, 0(t0) with t0 = 0x400018 (uarch_x0), t1 = 7", UARCH_RAM, UARCH_X(0),
        7, 1);
    cm_machine *m = make_machine(UARCH_RAM, UARCH_X(0), 7);
    cm_uarch_break_reason ubr;
    const cm_error e = cm_run_uarch(m, 1, &ubr);
    printf("    host cm_run_uarch: %s\n", e == CM_ERROR_OK ? "ok" : cm_get_last_error_message());
    cm_delete(m);
    if (!x.host_ok && x.ver_ok) {
        printf("BUG REPRODUCED: the verifier accepts a uarch step (store to the uarch_x0 shadow word) that the host "
               "refuses; the verified post-state has uarch x0 = 7\n");
        return 1;
    }
    if (x.host_ok && x.ver_ok && !same_root(&x)) {
        printf("BUG REPRODUCED: host and verifier reach different root hashes for a store to the uarch_x0 shadow "
               "word\n");
        return 1;
    }
    printf("OK: host and verifier agree on a uarch store to the uarch_x0 shadow word\n");
    return 0;
}
