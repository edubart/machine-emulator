// cm_create_new must reject a uint64 config field whose JSON value is out of range.
// nlohmann::json stores an integer literal that does not fit in uint64 (here 2^64) as a double.
// ju_get_opt_field(..., uint64_t &) in src/json-util.cpp accepts doubles and rejects them only when
// f > (double)UINT64_MAX, but (double)UINT64_MAX rounds up to 2^64, so 2^64 passes the check and reaches
// static_cast<uint64_t>(f), which is undefined behaviour (0 on x86-64, 2^64-1 on aarch64/riscv64).
// Exit codes: 0 = all out-of-range values rejected, 1 = some accepted (bug), 2 = test failure.
#include <inttypes.h>
#include <stdio.h>

#include <cm.h>

// Creates a 64 KiB machine whose mcycle register is the given JSON number text.
// Returns 1 if the machine was created (value stored in *mcycle), 0 if cm_create_new rejected the config.
static int try_create(const char *mcycle_json, uint64_t *mcycle) {
    char config[256];
    snprintf(config, sizeof(config), "{\"ram\":{\"length\":65536},\"processor\":{\"registers\":{\"mcycle\":%s}}}",
        mcycle_json);
    cm_machine *m = NULL;
    if (cm_create_new(config, NULL, NULL, &m) != CM_ERROR_OK) {
        printf("mcycle=%-24s -> rejected: %s\n", mcycle_json, cm_get_last_error_message());
        return 0;
    }
    *mcycle = 0;
    if (cm_read_reg(m, CM_REG_MCYCLE, mcycle) != CM_ERROR_OK) {
        printf("cm_read_reg failed: %s\n", cm_get_last_error_message());
        cm_delete(m);
        return -1;
    }
    cm_delete(m);
    printf("mcycle=%-24s -> ACCEPTED, mcycle register = %" PRIu64 "\n", mcycle_json, *mcycle);
    return 1;
}

int main(void) {
    uint64_t v = 0;
    // Control: the largest uint64 written as an exact integer must be accepted unchanged.
    if (try_create("18446744073709551615", &v) != 1 || v != UINT64_MAX) {
        printf("control config with mcycle=2^64-1 was not accepted unchanged\n");
        return 2;
    }
    // 2^64 as exact integer text, and the same double as JavaScript's JSON.stringify writes it.
    const char *out_of_range[] = {"18446744073709551616", "18446744073709552000", "1.8446744073709552e19"};
    int accepted = 0;
    for (size_t i = 0; i < sizeof(out_of_range) / sizeof(out_of_range[0]); ++i) {
        const int r = try_create(out_of_range[i], &v);
        if (r < 0) {
            return 2;
        }
        accepted += r;
    }
    return accepted > 0 ? 1 : 0;
}
