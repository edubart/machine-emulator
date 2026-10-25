// cm_translate_virtual_address(m, vaddr, NULL) must return a cm_error (like every
// other C API function with a required output pointer), not crash.
// Also checks cm_jsonrpc_rebind_server(m, NULL, ...) (returns -5 under libstdc++; hardening only).
// Each case runs in a forked child so a crash can be observed. Exit 1 while the bug is present.
// Build: see run.sh (g++ -std=c++20 -I<repo>/src ... -L<repo>/src -lcartesi -lcartesi_jsonrpc)
#include <cm.h>
#include <cm-jsonrpc.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>

static int g_pidfd = -1;
static const char *CFG = "{\"ram\":{\"length\":1048576},\"dtb\":{},\"processor\":{\"registers\":{}}}";

// run fn in child; returns 0 if child exited 0 (fn got an error code as expected), else reports
static int run_case(const char *name, int (*fn)()) {
    int fds[2]; if (pipe(fds) != 0) return 2;
    pid_t p = fork();
    if (p == 0) { close(fds[0]); g_pidfd = fds[1]; alarm(30); _exit(fn()); }
    close(fds[1]);
    int st = 0; waitpid(p, &st, 0);
    uint32_t spid = 0; // kill any server spawned by a crashed child
    while (read(fds[0], &spid, sizeof(spid)) == (ssize_t)sizeof(spid)) { if (spid) kill((pid_t)spid, SIGKILL); }
    close(fds[0]);
    if (WIFSIGNALED(st)) {
        printf("BUG: %s crashed with signal %d (%s) instead of returning an error\n", name, WTERMSIG(st), strsignal(WTERMSIG(st)));
        return 1;
    }
    int code = WEXITSTATUS(st);
    if (code == 0) { printf("OK: %s returned an error code\n", name); return 0; }
    if (code == 2) { printf("SETUP FAILURE: %s\n", name); return 2; }
    printf("BUG: %s returned success for NULL argument\n", name);
    return 1;
}

static int case_translate_local() {
    cm_machine *m = nullptr;
    if (cm_create_new(CFG, nullptr, nullptr, &m) != CM_ERROR_OK) { fprintf(stderr, "create: %s\n", cm_get_last_error_message()); return 2; }
    cm_error e = cm_translate_virtual_address(m, 0, nullptr);
    fprintf(stderr, "  translate(NULL) -> %d: %s\n", (int)e, cm_get_last_error_message());
    cm_delete(m);
    return e == CM_ERROR_OK ? 1 : 0;
}

static cm_machine *spawn(uint32_t *pid) {
    cm_machine *m = nullptr; const char *addr = nullptr;
    if (cm_jsonrpc_spawn_server("127.0.0.1:0", 10000, &m, &addr, pid) != CM_ERROR_OK) {
        fprintf(stderr, "spawn: %s\n", cm_get_last_error_message()); return nullptr;
    }
    cm_jsonrpc_set_cleanup_call(m, CM_JSONRPC_SHUTDOWN);
    if (g_pidfd >= 0) { (void)!write(g_pidfd, pid, sizeof(*pid)); }
    return m;
}

static int case_rebind_null() {
    uint32_t pid = 0; cm_machine *m = spawn(&pid); if (!m) return 2;
    const char *bound = nullptr;
    cm_error e = cm_jsonrpc_rebind_server(m, nullptr, &bound);
    fprintf(stderr, "  rebind(NULL) -> %d: %s\n", (int)e, cm_get_last_error_message());
    cm_delete(m);
    return e == CM_ERROR_OK ? 1 : 0;
}

static int case_translate_remote() {
    uint32_t pid = 0; cm_machine *m = spawn(&pid); if (!m) return 2;
    if (cm_create(m, CFG, nullptr, nullptr) != CM_ERROR_OK) { fprintf(stderr, "rcreate: %s\n", cm_get_last_error_message()); cm_delete(m); return 2; }
    cm_error e = cm_translate_virtual_address(m, 0, nullptr);
    fprintf(stderr, "  remote translate(NULL) -> %d: %s\n", (int)e, cm_get_last_error_message());
    cm_delete(m);
    return e == CM_ERROR_OK ? 1 : 0;
}

int main() {
    int bugs = 0, r;
    r = run_case("cm_translate_virtual_address(local, paddr=NULL)", case_translate_local); bugs += (r == 1);
    r = run_case("cm_translate_virtual_address(jsonrpc, paddr=NULL)", case_translate_remote); bugs += (r == 1);
    r = run_case("cm_jsonrpc_rebind_server(address=NULL)", case_rebind_null); bugs += (r == 1);
    // reap any leftover servers
    while (waitpid(-1, nullptr, WNOHANG) > 0) {}
    return bugs ? 1 : 0;
}
