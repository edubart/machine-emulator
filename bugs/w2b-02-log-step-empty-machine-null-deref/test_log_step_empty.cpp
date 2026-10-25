// cm_log_step on an empty local machine handle (cm_new() with no create/load)
// must return a cm_error ("no machine"), like every other API, not crash.
// Each case runs in a forked child so a crash can be observed.
// Usage: test_log_step_empty <scratch-dir>
#include <cm.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

static std::string log_path;

static int run_case(const char *name, int which) {
    pid_t pid = fork();
    if (pid == 0) {
        alarm(10);
        cm_machine *m = nullptr;
        if (cm_new(&m) != 0) _exit(90);
        cm_break_reason br = CM_BREAK_REASON_FAILED;
        cm_error e = CM_ERROR_OK;
        if (which == 0) e = cm_run(m, 1, &br);
        else e = cm_log_step(m, 1, log_path.c_str(), &br);
        printf("  %s returned %d: %s\n", name, (int)e, cm_get_last_error_message());
        fflush(stdout);
        cm_delete(m);
        _exit(e != 0 ? 0 : 91);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (WIFSIGNALED(st)) {
        printf("BUG: %s on empty machine killed process with signal %d (%s) instead of returning an error\n", name,
            WTERMSIG(st), strsignal(WTERMSIG(st)));
        return 1;
    }
    if (WEXITSTATUS(st) != 0) {
        printf("BUG?: %s child exit %d\n", name, WEXITSTATUS(st));
        return 1;
    }
    printf("OK: %s on empty machine returned an error\n", name);
    return 0;
}

int main(int argc, char **argv) {
    log_path = std::string(argc > 1 ? argv[1] : "/tmp") + "/empty-machine-step.log";
    int bad = 0;
    bad |= run_case("cm_run (control)", 0);
    bad |= run_case("cm_log_step", 1);
    return bad;
}
