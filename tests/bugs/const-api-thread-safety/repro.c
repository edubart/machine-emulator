// Independent reproducer for CONC-5 (verify-conc).
// Two threads issue only "const" queries on ONE idle local machine: a monitor thread polls cm_get_root_hash
// while a worker thread asks for word-level node hashes (cm_get_node_hash, log2 5). Each query runs a full
// hash-tree update internally (always-dirty shadow pages), mutating shared state without a lock.
// Mode "locked" wraps every call in a mutex (external serialization): must be clean.
// Each trial runs in a forked child so crashes are observed and reported.
// Usage: ./repro [locked]
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cm.h>
#define CHK(x) do { cm_error e_ = (x); if (e_ != CM_ERROR_OK) { fprintf(stderr, "%s -> %s\n", #x, cm_get_last_error_message()); exit(2);} } while (0)
#define NADDR 48
#define ITERS 300
static const cm_machine *g_m;
static cm_hash g_root, g_word[NADDR];
static uint64_t g_addr[NADDR];
static int g_locked;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_stop;
typedef struct { int errors, wrong, ok; char last[200]; } stats;
static void lock(void) { if (g_locked) pthread_mutex_lock(&g_mu); }
static void unlock(void) { if (g_locked) pthread_mutex_unlock(&g_mu); }
static void *monitor(void *arg) {
    stats *s = arg;
    while (!g_stop) {
        cm_hash h;
        lock(); cm_error e = cm_get_root_hash(g_m, &h); if (e) snprintf(s->last, sizeof s->last, "%s", cm_get_last_error_message()); unlock();
        if (e) s->errors++; else if (memcmp(h, g_root, 32)) s->wrong++; else s->ok++;
    }
    return NULL;
}
static int trial(void) {
    cm_machine *m;
    CHK(cm_create_new("{\"ram\":{\"length\":2097152},\"hash_tree\":{\"phtc_size\":32}}", "{\"concurrency\":{\"update_hash_tree\":1}}", NULL, &m));
    uint8_t page[4096];
    for (int k = 0; k < NADDR; k++) {
        for (int i = 0; i < 4096; i++) page[i] = (uint8_t) (k * 5 + i);
        g_addr[k] = 0x80000000ULL + (uint64_t) k * 2 * 4096 + 32 * (k % 128);
        CHK(cm_write_memory(m, g_addr[k] & ~4095ULL, page, sizeof page));
    }
    CHK(cm_get_root_hash(m, &g_root));
    for (int k = 0; k < NADDR; k++) CHK(cm_get_node_hash(m, g_addr[k], 5, &g_word[k]));
    g_m = m;
    stats ms = {0}, ws = {0};
    pthread_t t; pthread_create(&t, NULL, monitor, &ms);
    for (int it = 0; it < ITERS; it++) {
        int k = it % NADDR; cm_hash h;
        lock(); cm_error e = cm_get_node_hash(g_m, g_addr[k], 5, &h); if (e) snprintf(ws.last, sizeof ws.last, "%s", cm_get_last_error_message()); unlock();
        if (e) ws.errors++; else if (memcmp(h, g_word[k], 32)) ws.wrong++; else ws.ok++;
    }
    g_stop = 1; pthread_join(t, NULL);
    fflush(stdout);
    printf("  worker : %d ok, %d wrong, %d errors%s%s\n", ws.ok, ws.wrong, ws.errors, ws.errors ? "  last: " : "", ws.errors ? ws.last : "");
    printf("  monitor: %d ok, %d wrong, %d errors%s%s\n", ms.ok, ms.wrong, ms.errors, ms.errors ? "  last: " : "", ms.errors ? ms.last : "");
    cm_delete(m);
    fflush(stdout);
    return (ws.errors + ws.wrong + ms.errors + ms.wrong) ? 1 : 0;
}
int main(int argc, char **argv) {
    g_locked = argc > 1 && !strcmp(argv[1], "locked");
    printf("mode: %s\n", g_locked ? "calls serialized by an external mutex (control)" : "unsynchronized const queries");
    int bad = 0;
    for (int i = 0; i < 4 && !bad; i++) {
        fflush(stdout);
        pid_t p = fork();
        if (p == 0) _exit(trial());
        int st; waitpid(p, &st, 0);
        if (WIFSIGNALED(st)) { printf("trial %d: process killed by signal %d (%s)\n", i, WTERMSIG(st), strsignal(WTERMSIG(st))); bad = 1; }
        else if (WEXITSTATUS(st) == 1) { printf("trial %d: spurious errors / wrong results\n", i); bad = 1; }
        else if (WEXITSTATUS(st) != 0) { printf("trial %d: setup failed\n", i); return 2; }
        else printf("trial %d: clean\n", i);
    }
    if (bad) { printf("BUG REPRODUCED: concurrent const queries on one machine are not thread-safe\n"); return 1; }
    printf("NOT REPRODUCED\n");
    return 0;
}
