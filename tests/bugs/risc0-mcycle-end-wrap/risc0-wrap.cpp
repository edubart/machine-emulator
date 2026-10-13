// Compares the RISC Zero step verifier entry point risc0_replay_steps() (risc0/cpp/risc0-replay-steps.cpp, compiled
// for the host) with the host step verifier cm_verify_step() on step logs where mcycle + mcycle_count > 2^64-1.
//
// risc0_replay_steps computes mcycle_end with a wrapping add, while cm_log_step/cm_verify_step saturate. With a
// wrapped mcycle_end the replay executes zero cycles, so the guest rejects the honest log and accepts a forged log
// whose header claims mcycle_count cycles with root_hash_after == root_hash_before.
//
// Usage: risc0-wrap <work-dir>
// Exit codes: 0 = both verifiers agree, 1 = they disagree, 2 = setup failure (or the control scenario disagrees).
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "cm.h"

// The guest entry point under test
extern "C" void risc0_replay_steps(unsigned char *step_log_image, uint64_t step_log_image_size,
    unsigned char *out_root_hash_before, uint64_t *out_mcycle_count, unsigned char *out_root_hash_after);

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            fprintf(stderr, "setup failed: %s: %s\n", #x, cm_get_last_error_message());                                \
            exit(2);                                                                                                   \
        }                                                                                                              \
    } while (0)

static std::string work_dir;

static std::vector<unsigned char> slurp(const std::string &f) {
    std::ifstream in(f, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), {}};
}

static void spit(const std::string &f, const std::vector<unsigned char> &d) {
    std::ofstream o(f, std::ios::binary);
    o.write(reinterpret_cast<const char *>(d.data()), static_cast<std::streamsize>(d.size()));
}

// What a risc0 receipt would attest (the journal), or why the guest would abort
struct zk_result {
    bool ok;
    std::string err;
    cm_hash before, after;
    uint64_t count;
};

static zk_result zk_verify(std::vector<unsigned char> log) {
    zk_result r{};
    try {
        risc0_replay_steps(log.data(), log.size(), r.before, &r.count, r.after);
        r.ok = true;
    } catch (std::exception &e) {
        r.err = e.what();
    }
    return r;
}

static bool host_verify(const cm_hash &before, const std::string &f, uint64_t count, const cm_hash &claimed_after,
    std::string &why) {
    cm_hash got;
    if (cm_verify_step(&before, f.c_str(), count, &got) != CM_ERROR_OK) {
        why = cm_get_last_error_message();
        return false;
    }
    if (memcmp(got, claimed_after, sizeof(got)) != 0) {
        why = "obtained root hash differs from the claimed one";
        return false;
    }
    return true;
}

static cm_machine *create(const char *regs, const std::vector<uint32_t> &code) {
    // SHA-256 hash tree, as used with the risc0 prover
    const std::string cfg = std::string("{\"ram\":{\"length\":4096},\"hash_tree\":{\"hash_function\":\"sha256\"},"
                                        "\"processor\":{\"registers\":{") +
        regs + "}}}";
    cm_machine *m{};
    CHK(cm_create_new(cfg.c_str(), nullptr, nullptr, &m));
    CHK(cm_write_memory(m, CM_AR_RAM_START, reinterpret_cast<const uint8_t *>(code.data()), code.size() * 4));
    return m;
}

static cm_machine *create_and_advance(const char *regs, const std::vector<uint32_t> &code, uint64_t pre) {
    cm_machine *m = create(regs, code);
    uint64_t mcycle = 0;
    CHK(cm_read_reg(m, CM_REG_MCYCLE, &mcycle));
    if (pre != 0) {
        cm_break_reason br{};
        CHK(cm_run(m, mcycle + pre, &br));
    }
    return m;
}

// Honest log of `count` mcycles from the state reached after `pre` mcycles, plus a forged log: a genuine 0-cycle log
// from the same state whose header is patched to claim `count` mcycles (root_hash_after stays == root_hash_before).
// Returns the number of disagreements between the two verifiers.
static int scenario(const char *name, const char *regs, const std::vector<uint32_t> &code, uint64_t pre,
    uint64_t count) {
    int disagreements = 0;
    printf("--- %s (mcycle_count=%" PRIu64 ")\n", name, count);
    cm_machine *m = create_and_advance(regs, code, pre);
    uint64_t mcycle_before = 0;
    uint64_t mcycle_after = 0;
    CHK(cm_read_reg(m, CM_REG_MCYCLE, &mcycle_before));
    cm_hash before;
    cm_hash after;
    CHK(cm_get_root_hash(m, &before));
    const std::string honest_log = work_dir + "/" + name + "-honest.log";
    const std::string zero_log = work_dir + "/" + name + "-zero.log";
    const std::string forged_log = work_dir + "/" + name + "-forged.log";
    cm_break_reason br{};
    remove(honest_log.c_str());
    CHK(cm_log_step(m, count, honest_log.c_str(), &br));
    CHK(cm_get_root_hash(m, &after));
    CHK(cm_read_reg(m, CM_REG_MCYCLE, &mcycle_after));
    cm_delete(m);
    printf("    mcycle %" PRIu64 " -> %" PRIu64 " (break reason %d)\n", mcycle_before, mcycle_after,
        static_cast<int>(br));

    std::string why;
    bool host_ok = host_verify(before, honest_log, count, after, why);
    zk_result z = zk_verify(slurp(honest_log));
    const bool zk_ok = z.ok && memcmp(z.before, before, sizeof(before)) == 0 &&
        memcmp(z.after, after, sizeof(after)) == 0 && z.count == count;
    printf("    honest log: host verify_step %s | risc0 replay %s\n", host_ok ? "ACCEPT" : why.c_str(),
        z.ok ? (zk_ok ? "ACCEPT" : "ACCEPT (unexpected journal)") : z.err.c_str());
    if (host_ok != zk_ok) {
        printf("    => verifiers disagree on the honest log\n");
        disagreements++;
    }

    cm_machine *m2 = create_and_advance(regs, code, pre);
    remove(zero_log.c_str());
    CHK(cm_log_step(m2, 0, zero_log.c_str(), &br));
    cm_delete(m2);
    auto forged = slurp(zero_log);
    if (forged.size() < 40) {
        fprintf(stderr, "setup failed: step log too short\n");
        exit(2);
    }
    memcpy(forged.data() + 32, &count, sizeof(count)); // header: root_hash_before[32], mcycle_count, ...
    spit(forged_log, forged);
    host_ok = host_verify(before, forged_log, count, before, why);
    z = zk_verify(forged);
    const bool zk_false_claim = z.ok && z.count == count && memcmp(z.before, before, sizeof(before)) == 0 &&
        memcmp(z.after, before, sizeof(before)) == 0;
    printf("    forged log claiming %" PRIu64 " mcycles with no state change: host verify_step %s | risc0 replay %s\n",
        count, host_ok ? "ACCEPT" : why.c_str(),
        z.ok ? (zk_false_claim ? "ACCEPT (journal: before, count, before)" : "ACCEPT") : z.err.c_str());
    if (host_ok != zk_false_claim) {
        printf("    => verifiers disagree on the forged log\n");
        disagreements++;
    }
    return disagreements;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <work-dir>\n", argv[0]);
        return 2;
    }
    work_dir = argv[1];
    // x5 += 1 forever (the state changes every cycle)
    const std::vector<uint32_t> loop = {0x00128293 /* addi t0,t0,1 */, 0xffdff06f /* j -4 */};
    // A few instructions, then halt through HTIF tohost
    const std::vector<uint32_t> halt = {0x00128293 /* addi t0,t0,1 */, 0x00128293, 0x00128293,
        0x40008337 /* lui t1,0x40008 */, 0x00100393 /* li t2,1 */, 0x00733023 /* sd t2,0(t1) */,
        0x0000006f /* j . */};

    // Control: same machine as run-to-halt, with an mcycle_count that does not overflow
    if (scenario("control", "", halt, 1, 1000) != 0) {
        printf("ERROR: verifiers disagree on the control scenario\n");
        return 2;
    }
    int disagreements = 0;
    // Template whose initial mcycle is 3 cycles below 2^64-1, fixed small step size
    disagreements += scenario("near-max", "\"mcycle\":18446744073709551612", loop, 0, 16);
    // Ordinary machine (one cycle executed) verified with mcycle_count = UINT64_MAX ("run to completion")
    disagreements += scenario("run-to-halt", "", halt, 1, UINT64_MAX);
    return disagreements != 0 ? 1 : 0;
}
