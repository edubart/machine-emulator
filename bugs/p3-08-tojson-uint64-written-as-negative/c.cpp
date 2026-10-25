// Control: the C API emits the same config with unsigned values.
// Build and run from the repo root:
//   eval $(make -s env)
//   g++ -std=c++20 -Isrc bugs/p3-08-tojson-uint64-written-as-negative/c.cpp -Lsrc -lcartesi -o /tmp/p3-08-c && /tmp/p3-08-c
// Expected output: "ilrsc":18446744073709551615,... and "misa":9223372036856090925,...
#include <cm.h>
#include <cstdio>
#include <cstring>
int main() {
    cm_machine *m = nullptr;
    const char *cfg = nullptr;
    if (cm_create_new("{\"ram\":{\"length\":1048576}}", nullptr, nullptr, &m) != 0) {
        puts(cm_get_last_error_message());
        return 2;
    }
    if (cm_get_initial_config(m, &cfg) != 0) {
        puts(cm_get_last_error_message());
        return 2;
    }
    const char *p = strstr(cfg, "\"ilrsc\"");
    printf("%.40s\n", p);
    p = strstr(cfg, "\"misa\"");
    printf("%.40s\n", p);
    cm_delete(m);
    return 0;
}
