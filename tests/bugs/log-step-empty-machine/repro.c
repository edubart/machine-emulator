// cm_log_step() on an empty machine object (cm_new() without cm_create/cm_load) dereferences a NULL
// machine pointer: local_machine::do_log_step uses m_machine-> directly instead of get_machine(), which
// every other method uses and which fails with "no machine". The JSON-RPC server already rejects the call.
// Each call runs in a forked child so that a crash can be observed and reported.
// Usage: repro <log-file-path>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

static const char *log_path = NULL;

// Returns 0 if the call returned an error code, 1 if it returned success, 3 on setup failure.
static int child(int which) {
    cm_machine *m = NULL;
    if (cm_new(&m) != CM_ERROR_OK) { // empty local machine object
        return 3;
    }
    cm_error e = CM_ERROR_OK;
    cm_break_reason br = CM_BREAK_REASON_FAILED;
    if (which == 0) {
        e = cm_run(m, 1, &br); // control: other methods fail with "no machine"
    } else {
        e = cm_log_step(m, 1, log_path, &br);
    }
    printf("  returned %d (%s)\n", (int) e, e != CM_ERROR_OK ? cm_get_last_error_message() : "success");
    cm_delete(m);
    return e != CM_ERROR_OK ? 0 : 1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2) {
        fprintf(stderr, "usage: %s <log-file-path>\n", argv[0]);
        return 2;
    }
    log_path = argv[1];
    const char *names[] = {"cm_run on an empty machine object", "cm_log_step on an empty machine object"};
    int bug = 0;
    for (int i = 0; i < 2; i++) {
        printf("%s:\n", names[i]);
        pid_t p = fork();
        if (p < 0) {
            perror("fork");
            return 2;
        }
        if (p == 0) {
            _exit(child(i));
        }
        int st = 0;
        if (waitpid(p, &st, 0) != p) {
            perror("waitpid");
            return 2;
        }
        if (WIFSIGNALED(st)) {
            printf("  child killed by signal %d\n", WTERMSIG(st));
            if (i == 0) {
                return 2; // control must not crash
            }
            bug = 1;
        } else if (WEXITSTATUS(st) == 3) {
            fprintf(stderr, "cm_new failed\n");
            return 2;
        } else if (WEXITSTATUS(st) == 1) {
            if (i == 0) {
                return 2; // control must fail
            }
            printf("  call on an empty machine object reported success\n");
            bug = 1;
        }
    }
    if (bug) {
        printf("BUG REPRODUCED: cm_log_step on an empty machine object crashes instead of failing with \"no machine\"\n");
        return 1;
    }
    printf("OK: cm_log_step on an empty machine object fails cleanly like the other methods\n");
    return 0;
}
