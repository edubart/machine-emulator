// cm_clone_empty() on a remote (JSON-RPC) machine leaks the server it forks.
//
// jsonrpc_machine::do_clone_empty() (src/jsonrpc-machine.cpp) forks the source server and wraps the new address in
// `new jsonrpc_machine(address)`, which keeps the defaults cleanup call = NOTHING and timeout = -1 (infinite).
// cm_jsonrpc_fork_server(), in contrast, copies both from the source (as documented in cm-jsonrpc.h). So cm_delete()
// of a cm_clone_empty() result never shuts its forked server down: the server process, and the machine it holds,
// outlive every handle, and the client silently loses its configured timeout. A cm_create() that fails on the
// clone leaks an (empty) server the same way, since the caller can only cm_delete() the object.
//
// Property checked (what a fix restores): after cm_delete() of every object, no server created by cm_clone_empty()
// still answers, and the clone has the source's timeout.
//
// Servers bind to 127.0.0.1 with kernel-chosen ports. Every server found alive is shut down before exiting (run.sh
// also kills the whole process group as a safety net).
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure.
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cm-jsonrpc.h>
#include <cm.h>

#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if ((x) != CM_ERROR_OK) {                                                                                      \
            fprintf(stderr, "setup failed: %s: %s\n", #x, cm_get_last_error_message());                                \
            exit(2);                                                                                                   \
        }                                                                                                              \
    } while (0)

static const char *const CONFIG = "{\"ram\":{\"length\":4096}}";
static const char *const BAD_CONFIG = "{\"ram\":{\"length\":4097}}"; // not a multiple of the page size

static char *address_of(cm_machine *m) {
    const char *a = NULL;
    CHK(cm_jsonrpc_get_server_address(m, &a));
    return strdup(a);
}

static int64_t timeout_of(cm_machine *m) {
    int64_t t = 0;
    CHK(cm_jsonrpc_get_timeout(m, &t));
    return t;
}

static void print_policy(const char *name, cm_machine *m) {
    cm_jsonrpc_cleanup_call c = CM_JSONRPC_NOTHING;
    CHK(cm_jsonrpc_get_cleanup_call(m, &c));
    printf("  %-38s timeout=%" PRId64 " cleanup=%s\n", name, timeout_of(m),
        c == CM_JSONRPC_SHUTDOWN ? "SHUTDOWN" : (c == CM_JSONRPC_DESTROY ? "DESTROY" : "NOTHING"));
}

// Returns 1 if a server still answers at addr (and shuts it down), 0 otherwise
static int probe_and_reap(const char *what, const char *addr) {
    cm_machine *p = NULL;
    if (cm_jsonrpc_connect_server(addr, 1000, &p) != CM_ERROR_OK) {
        printf("  %-38s gone\n", what);
        return 0;
    }
    bool empty = true;
    if (cm_is_empty(p, &empty) != CM_ERROR_OK) {
        empty = true;
    }
    printf("  %-38s STILL RUNNING after cm_delete (holds a machine: %s)\n", what, empty ? "no" : "yes");
    cm_jsonrpc_shutdown_server(p);
    cm_delete(p);
    return 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    cm_machine *src = NULL;
    const char *a = NULL;
    uint32_t pid = 0;
    CHK(cm_jsonrpc_spawn_server("127.0.0.1:0", 10000, &src, &a, &pid));
    char *src_addr = strdup(a);
    CHK(cm_jsonrpc_set_cleanup_call(src, CM_JSONRPC_SHUTDOWN));
    CHK(cm_jsonrpc_set_timeout(src, 5000));

    // (1) cm_clone_empty() + cm_create(): what Lua's machine:remote(config) and doc/recipes/run-remote-config.lua do
    cm_machine *clone = NULL;
    CHK(cm_clone_empty(src, &clone));
    CHK(cm_create(clone, CONFIG, NULL, NULL));
    char *clone_addr = address_of(clone);

    // (2) cm_clone_empty() + a cm_create() that fails: the caller can only cm_delete() the object
    cm_machine *clone_bad = NULL;
    CHK(cm_clone_empty(src, &clone_bad));
    if (cm_create(clone_bad, BAD_CONFIG, NULL, NULL) == CM_ERROR_OK) {
        fprintf(stderr, "setup failed: cm_create accepted a bad config\n");
        return 2;
    }
    char *bad_addr = address_of(clone_bad);

    // (3) reference: cm_jsonrpc_fork_server() inherits cleanup and timeout
    cm_machine *forked = NULL;
    CHK(cm_create(src, CONFIG, NULL, NULL));
    CHK(cm_jsonrpc_fork_server(src, &forked, &a, &pid));
    char *fork_addr = strdup(a);

    print_policy("source (spawned, set SHUTDOWN/5000)", src);
    print_policy("cm_clone_empty() result", clone);
    print_policy("cm_jsonrpc_fork_server() result", forked);
    const int timeout_lost = timeout_of(clone) != timeout_of(src);

    cm_delete(clone);
    cm_delete(clone_bad);
    cm_delete(forked);
    cm_delete(src);

    printf("after cm_delete of every object:\n");
    int fork_left = probe_and_reap("source server", src_addr);
    fork_left += probe_and_reap("cm_jsonrpc_fork_server() server", fork_addr);
    int leaked = probe_and_reap("cm_clone_empty()+cm_create() server", clone_addr);
    leaked += probe_and_reap("cm_clone_empty()+failed create server", bad_addr);
    if (fork_left != 0) {
        printf("control failed: a server with cleanup SHUTDOWN survived cm_delete\n");
        return 2;
    }
    if (leaked != 0 || timeout_lost) {
        printf("BUG REPRODUCED: cm_clone_empty() on a remote machine: %d forked server(s) outlived every handle%s\n",
            leaked, timeout_lost ? "; the clone did not inherit the source's timeout" : "");
        return 1;
    }
    printf("OK: cm_clone_empty() servers are shut down by cm_delete() and inherit the source's timeout\n");
    return 0;
}
