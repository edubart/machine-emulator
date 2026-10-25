// Repro: remote (JSON-RPC) send/log/verify_send_cmio_response dereference NULL data.
// Each case runs in a forked child so a crash is observed instead of killing the test.
#include <cm.h>
#include <cm-jsonrpc.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
static uint32_t g_server_pid = 0;
static int g_wfd = -1;

static const char *CFG = "{\"ram\":{\"length\":1048576}}";

static cm_machine *make(bool remote) {
    cm_machine *m = nullptr;
    if (remote) {
        if (cm_jsonrpc_spawn_server("127.0.0.1:0", 10000, &m, nullptr, &g_server_pid) != 0) {
            fprintf(stderr, "spawn failed: %s\n", cm_get_last_error_message()); _exit(90);
        }
        dprintf(g_wfd, "pid=%u;", g_server_pid);
        if (cm_create(m, CFG, nullptr, nullptr) != 0) {
            fprintf(stderr, "create failed: %s\n", cm_get_last_error_message()); _exit(91);
        }
    } else {
        if (cm_new(&m) != 0 || cm_create(m, CFG, nullptr, nullptr) != 0) {
            fprintf(stderr, "local create failed: %s\n", cm_get_last_error_message()); _exit(92);
        }
    }
    uint64_t tohost = ((uint64_t)CM_HTIF_DEV_YIELD << CM_HTIF_DEV_SHIFT) |
        ((uint64_t)CM_HTIF_YIELD_CMD_MANUAL << CM_HTIF_CMD_SHIFT) |
        ((uint64_t)CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED << CM_HTIF_REASON_SHIFT);
    if (cm_write_reg(m, CM_REG_HTIF_TOHOST, tohost) != 0 || cm_write_reg(m, CM_REG_IFLAGS_Y, 1) != 0) {
        fprintf(stderr, "write_reg failed: %s\n", cm_get_last_error_message()); _exit(93);
    }
    return m;
}

// op: 0 send, 1 log_send, 2 verify_send ; len: data length with data==NULL
// child exit: 0 = call returned success, 1 = returned error, signal = crash
static int run_case(bool remote, int op, uint32_t len, std::string &msg) {
    int pfd[2]; if (pipe2(pfd, O_CLOEXEC) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        close(pfd[0]);
        g_wfd = pfd[1];
        alarm(30);
        cm_machine *m = make(remote);
        cm_hash h{};
        cm_get_root_hash(m, &h);
        cm_error e = CM_ERROR_OK;
        if (op == 0) {
            e = cm_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, nullptr, len, &h);
        } else if (op == 1) {
            const char *log = nullptr;
            e = cm_log_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, nullptr, len, &h, 0, &log);
        } else {
            // produce a valid log with a real (oversized/small) buffer, then verify with NULL data
            std::string buf(len, 'x');
            const char *log = nullptr;
            if (cm_log_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, (const uint8_t *)buf.data(), len,
                    &h, 0, &log) != 0) {
                dprintf(pfd[1], "log failed: %s", cm_get_last_error_message()); _exit(94);
            }
            std::string slog(log);
            cm_hash out{};
            e = cm_verify_send_cmio_response(m, CM_HTIF_YIELD_REASON_ADVANCE_STATE, nullptr, len, &h,
                slog.c_str(), &h, &out);
        }
        dprintf(pfd[1], "%s", e == 0 ? "ok" : cm_get_last_error_message());
        if (remote) cm_jsonrpc_shutdown_server(m);
        cm_delete(m);
        _exit(e == 0 ? 0 : 1);
    }
    close(pfd[1]);
    char b[512] = {0}; ssize_t n = read(pfd[0], b, sizeof(b) - 1); (void)n; close(pfd[0]);
    int st = 0; waitpid(pid, &st, 0);
    msg = b;
    unsigned spid = 0;
    if (sscanf(b, "pid=%u;", &spid) == 1) {
        msg = strchr(b, ';') + 1;
        if (WIFSIGNALED(st) && spid) kill((pid_t)spid, SIGKILL); // orphaned server after client crash
    }
    if (WIFSIGNALED(st)) return 1000 + WTERMSIG(st);
    return WEXITSTATUS(st);
}

static std::string desc(int r) {
    char s[64];
    if (r >= 1000) { snprintf(s, sizeof s, "CRASH signal %d (%s)", r - 1000, strsignal(r - 1000)); return s; }
    snprintf(s, sizeof s, r == 0 ? "returned success" : "returned error (exit %d)", r); return s;
}

int main() {
    const char *opn[] = {"cm_send_cmio_response", "cm_log_send_cmio_response", "cm_verify_send_cmio_response"};
    const uint32_t lens[] = {3u << 20, 5};
    int bugs = 0;
    for (int op = 0; op < 3; ++op) {
        for (uint32_t len : lens) {
            std::string ml, mr;
            int rl = run_case(false, op, len, ml);
            int rr = run_case(true, op, len, mr);
            printf("%-30s data=NULL len=%-8u local: %-28s [%s] | remote: %-28s [%s]\n", opn[op], len, desc(rl).c_str(),
                ml.c_str(), desc(rr).c_str(), mr.c_str());
            if (rr >= 1000) {
                printf("BUG: %s(remote, data=NULL, length=%u) crashes the client process (%s); local %s\n", opn[op],
                    len, desc(rr).c_str(), rl >= 1000 ? "also crashes" : "does not crash");
                ++bugs;
            }
        }
    }
    if (bugs) { printf("BUG: %d remote NULL-data cases crashed the client\n", bugs); return 1; }
    printf("OK: no crashes\n");
    return 0;
}
