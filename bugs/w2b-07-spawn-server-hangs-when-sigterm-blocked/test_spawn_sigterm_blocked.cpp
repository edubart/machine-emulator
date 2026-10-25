// Repro: cm_jsonrpc_spawn_server hangs on its error path when the caller has SIGTERM blocked.
// Exit 1 + "BUG:" line when the defect is present; exit 0 when fixed.
// Run from the repo root: eval $(make -s env); sh bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh
#include <cm-jsonrpc.h>
#include <cm.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <tuple>
#include <ctime>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>

// Runs spawn in a separate process (own process group) so a hang can be detected and cleaned up.
// Returns: 0 = spawn returned (code printed), 1 = hung (timed out)
static int run_case(bool block_sigterm, int timeout_s, int *ret_code) {
    int pfd[2];
    if (pipe(pfd) != 0) { perror("pipe"); exit(2); }
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        close(pfd[0]);
        if (block_sigterm) {
            sigset_t set;
            sigemptyset(&set);
            sigaddset(&set, SIGTERM);
            pthread_sigmask(SIG_BLOCK, &set, nullptr);
        }
        cm_machine *m = nullptr;
        const char *addr = nullptr;
        uint32_t spid = 0;
        // timeout 0 forces the version-check to time out -> error path -> child_waiter kills+waits
        int r = cm_jsonrpc_spawn_server("127.0.0.1:0", 0, &m, &addr, &spid);
        if (r == 0) { cm_delete(m); }
        std::ignore = write(pfd[1], &r, sizeof(r));
        _exit(0);
    }
    setpgid(pid, pid);
    close(pfd[1]);
    time_t start = time(nullptr);
    for (;;) {
        int status;
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            int r = 0;
            if (read(pfd[0], &r, sizeof(r)) == (ssize_t) sizeof(r)) *ret_code = r;
            close(pfd[0]);
            return 0;
        }
        if (time(nullptr) - start >= timeout_s) {
            // count processes still in the group (the spawned server is among them)
            // show processes left in the group, including the spawned server and its signal mask
            char cmd[512];
            snprintf(cmd, sizeof(cmd),
                "for p in $(pgrep -g %d); do printf 'pid %%s %%s: ' $p \"$(cat /proc/$p/comm)\"; "
                "grep -E '^(State|SigBlk|ShdPnd)' /proc/$p/status | tr '\\n' ' '; echo; done",
                (int) pid);
            std::ignore = system(cmd);
            kill(-pid, SIGKILL);
            waitpid(pid, &status, 0);
            close(pfd[0]);
            return 1;
        }
        usleep(50000);
    }
}

int main() {
    int code = 0;
    if (run_case(false, 10, &code) != 0) {
        printf("unexpected: baseline (unmasked) spawn hung\n");
        return 2;
    }
    printf("baseline (SIGTERM unblocked): spawn returned %d (%s)\n", code, code ? "error, as expected for timeout 0" : "ok");
    code = 0;
    if (run_case(true, 5, &code) != 0) {
        printf("BUG: cm_jsonrpc_spawn_server did not return within 5s when caller has SIGTERM blocked "
               "(spawned server inherited mask, ignores SIGTERM, waitpid blocks forever)\n");
        return 1;
    }
    printf("masked: spawn returned %d\n", code);
    return 0;
}
