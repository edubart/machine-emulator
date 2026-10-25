#include <cm.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>
static int bugs = 0;
static void check_read(cm_machine *m, uint64_t va, uint64_t len) {
    std::vector<uint8_t> buf(len, 0xAA);
    cm_error e = cm_read_virtual_memory(m, va, buf.data(), len);
    bool untouched = true;
    for (auto b : buf) if (b != 0xAA) { untouched = false; break; }
    printf("read  va=0x%016llx len=%llu -> err=%d (%s) buffer %s\n", (unsigned long long)va, (unsigned long long)len, e,
        e ? cm_get_last_error_message() : "", untouched ? "UNTOUCHED (still 0xAA)" : "written");
    if (e == 0 && untouched) {
        printf("BUG: cm_read_virtual_memory(0x%016llx, %llu) returned success but never wrote the output buffer\n",
            (unsigned long long)va, (unsigned long long)len);
        bugs++;
    }
}
static void check_write(cm_machine *m, uint64_t va, uint64_t len, bool ref_failed) {
    std::vector<uint8_t> buf(len, 'A');
    cm_error e = cm_write_virtual_memory(m, va, buf.data(), len);
    printf("write va=0x%016llx len=%llu -> err=%d (%s)\n", (unsigned long long)va, (unsigned long long)len, e,
        e ? cm_get_last_error_message() : "");
    if (e == 0 && ref_failed) {
        printf("BUG: cm_write_virtual_memory(0x%016llx, %llu) reported success (wrote nothing) although the same write to "
               "the neighbouring page 0xffffffffffffe000 is rejected\n", (unsigned long long)va, (unsigned long long)len);
        bugs++;
    }
}
int main() {
    const char *cfg = "{\"ram\":{\"length\":1048576}}";
    cm_machine *m = nullptr;
    if (cm_create_new(cfg, nullptr, nullptr, &m) != 0) { printf("create failed: %s\n", cm_get_last_error_message()); return 2; }
    // Reference: page just below the top page
    check_read(m, 0xffffffffffffe000ULL, 4096);
    std::vector<uint8_t> buf(4096, 'A');
    bool ref_failed = cm_write_virtual_memory(m, 0xffffffffffffe000ULL, buf.data(), 4096) != 0;
    printf("write va=0xffffffffffffe000 len=4096 -> %s (%s)\n", ref_failed ? "rejected" : "ok", ref_failed ? cm_get_last_error_message() : "");
    // Range ending exactly at 2^64
    check_read(m, 0xfffffffffffff000ULL, 4096);
    check_read(m, 0xffffffffffffffffULL, 1);
    // Range crossing 2^64
    check_read(m, 0xfffffffffffff000ULL, 8192);
    check_write(m, 0xfffffffffffff000ULL, 4096, ref_failed);
    check_write(m, 0xffffffffffffffffULL, 1, ref_failed);
    check_write(m, 0xfffffffffffff000ULL, 8192, ref_failed);
    cm_delete(m);
    if (bugs) { printf("%d defect(s) found\n", bugs); return 1; }
    printf("OK\n");
    return 0;
}
