// cm_translate_virtual_address(m, vaddr, NULL) writes the translated address through the NULL output
// pointer (src/cm.cpp: `*paddr = ...` with no NULL check), killing the caller with SIGSEGV.
// Every other C API entry point with an output pointer (e.g. cm_read_reg) rejects NULL with an error.
// Each call runs in a forked child so that a crash can be observed and reported.
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cm.h>

// Returns 0 if the call returned an error code, 1 if it returned success, 3 on setup failure.
static int child(int which) {
    cm_machine *m = NULL;
    if (cm_create_new("{\"ram\":{\"length\":4096}}", NULL, NULL, &m) != CM_ERROR_OK) {
        return 3;
    }
    cm_error e = CM_ERROR_OK;
    if (which == 0) {
        e = cm_read_reg(m, CM_REG_PC, NULL); // control: NULL output rejected
    } else {
        // satp is 0 (bare mode), so every address translates successfully
        e = cm_translate_virtual_address(m, 0x80000000, NULL);
    }
    printf("  returned %d (%s)\n", (int) e, e != CM_ERROR_OK ? cm_get_last_error_message() : "success");
    cm_delete(m);
    return e != CM_ERROR_OK ? 0 : 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *names[] = {"cm_read_reg(m, CM_REG_PC, NULL)", "cm_translate_virtual_address(m, 0x80000000, NULL)"};
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
            fprintf(stderr, "machine creation failed\n");
            return 2;
        } else if (WEXITSTATUS(st) == 1) {
            if (i == 0) {
                return 2; // control must reject NULL
            }
            printf("  NULL output pointer accepted\n");
            bug = 1;
        }
    }
    if (bug) {
        printf("BUG REPRODUCED: cm_translate_virtual_address does not reject a NULL paddr output pointer "
               "(writes through NULL)\n");
        return 1;
    }
    printf("OK: cm_translate_virtual_address rejects a NULL paddr output pointer with an error\n");
    return 0;
}
